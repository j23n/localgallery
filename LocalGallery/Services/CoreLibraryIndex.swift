import Foundation
import Observation
import os

/// The app's side of the Rust core's `LibraryIndex` (Phase 4).
///
/// Replaces `SearchIndex` and `TagIndex`. Every ordering and matching decision
/// — the date-descending sort with its `url.path` tiebreak, the search corpus
/// and its canonical-equivalence substring match, the tag buckets with the
/// `Places/*` prefix expansion, and the `TagSuggestion` aggregation — now lives
/// in `gallery-index`. What stays here is the two things the core cannot do:
///
/// 1. **Hold the `PhotoFile`s.** The core answers in ids, because the app is
///    already holding the structs those ids name; shipping them back across the
///    boundary per query would double the traffic to say nothing new. So this
///    type keeps `photoByID`, which is an object table, not an index — it has
///    no ordering and no matching rule of its own.
/// 2. **Keep the FFI off the main actor.** `build` runs the core call on a
///    detached task behind a generation counter (`_plans/06` Finding 3); the
///    two query calls are synchronous but memoised, so a scrolling list row
///    that asks the same question on every body evaluation crosses the boundary
///    once, not once per frame.
///
/// `@Observable` so view reads chained through the Store (`store.sortedPhotos`,
/// `store.allTags`) re-render when a rebuild lands.
@Observable
@MainActor
final class CoreLibraryIndex {

    // MARK: Published state

    /// Date-descending photo list, in the core's order. Backs
    /// `store.sortedPhotos` — this order *is* the grid.
    private(set) var sortedPhotos: [PhotoFile] = []
    /// All unique tags across the library, `(count desc, id asc)`.
    private(set) var allTags: [TagSuggestion] = []
    /// The `People/*` subset, each carrying its most recent photo date.
    private(set) var peopleTags: [TagSuggestion] = []

    /// `PhotoFile.id` → `PhotoFile`. The object table the core's id answers are
    /// resolved through. Built synchronously in `seed(allPhotos:)` because
    /// `photo(byID:)` is on the viewer's and the memory rail's critical path and
    /// must never be a frame behind `allPhotos`.
    @ObservationIgnored private var photoByID: [UUID: PhotoFile] = [:]

    // MARK: Wiring

    @ObservationIgnored private let core = LibraryIndex()
    /// Cancels a stale rebuild's publish. Same shape as the old
    /// `tagBuildGeneration`, now covering the whole rebuild rather than just
    /// the tag half.
    @ObservationIgnored private var generation = 0
    /// The in-flight rebuild, so tests (and `runScheduledMemoryRefresh`) can
    /// wait for the index to settle rather than poll.
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Memoised `photos(forTag:)` answers, cleared on every rebuild.
    ///
    /// Not a second tag index: the keys, the membership and the order all come
    /// from the core. This is a cache of its replies, and it exists because
    /// `PeopleListRow` and `PersonCard` ask the same question inside a
    /// `ScrollView` body.
    @ObservationIgnored private var tagPhotoCache: [String: [PhotoFile]] = [:]
    /// Single-entry memo for `search`, for the same reason: `TagGridView.photos`
    /// is a computed property evaluated on every body pass.
    @ObservationIgnored private var searchCache: (key: String, result: [PhotoFile])?

    // MARK: Build

    /// Publish `allPhotos` as the object table and kick off the core rebuild.
    ///
    /// Split in two on purpose. The dictionary is built here, synchronously, so
    /// `photo(byID:)` is correct the instant `apply(_:)` returns. The sort, the
    /// corpus and the tag aggregation — the parts that were 0.25–0.3 s of main
    /// thread on a 20k library — go to the core on a detached task.
    func build(allPhotos: [PhotoFile]) {
        generation += 1
        let generation = self.generation
        var table: [UUID: PhotoFile] = [:]
        table.reserveCapacity(allPhotos.count)
        for photo in allPhotos where table[photo.id] == nil {
            // First id wins, mirroring the old `uniquingKeysWith: { a, _ in a }`.
            table[photo.id] = photo
        }
        photoByID = table
        tagPhotoCache = [:]
        searchCache = nil

        pending?.cancel()
        let core = self.core
        pending = Task { [weak self] in
            let t = CFAbsoluteTimeGetCurrent()
            let records = allPhotos.map(CoreScanner.record(of:))
            let marshalled = CFAbsoluteTimeGetCurrent()
            let summary = await Task.detached(priority: .userInitiated) {
                core.build(photos: records)
            }.value
            guard !Task.isCancelled, let self, self.generation == generation else { return }

            self.sortedPhotos = summary.sortedPhotoIds.compactMap {
                UUID(uuidString: $0).flatMap { table[$0] }
            }
            self.allTags = summary.tags.map(Self.suggestion(from:))
            self.peopleTags = summary.people.map(Self.suggestion(from:))
            self.onRebuild?(self.allTags, self.peopleTags)

            let ms = { (a: CFAbsoluteTime, b: CFAbsoluteTime) in String(format: "%.0f", (b - a) * 1000) }
            let now = CFAbsoluteTimeGetCurrent()
            Log.index.info("""
                Built: \(allPhotos.count) photos, \(summary.tags.count) unique tags, \
                \(summary.people.count) people in \(ms(t, now))ms \
                (in=\(ms(t, marshalled))ms core=\(summary.buildMillis)ms)
                """)
        }
    }

    /// Fired on the main actor after every rebuild publishes, with the freshly
    /// aggregated lists. The Store uses it to push `topPeople` into
    /// `PeopleStore` and re-export the widget snapshot — the two things the old
    /// `Task.detached` tail in `rebuildSortAndIndex` did.
    @ObservationIgnored var onRebuild: (([TagSuggestion], [TagSuggestion]) -> Void)?

    /// Wait for the in-flight rebuild, if any. For tests and for callers that
    /// genuinely need the sorted order rather than whatever is published.
    func settle() async {
        await pending?.value
    }

    // MARK: Queries

    /// O(1) photo lookup by id.
    func photo(byID id: UUID) -> PhotoFile? { photoByID[id] }

    /// Photos credited to `tag`, including the `Places/*` prefix expansion, in
    /// `allPhotos` order — `TagIndex.photos(forTag:)`'s contract.
    func photos(forTag tag: TagSuggestion) -> [PhotoFile] {
        let key = tag.fullPath
        if let cached = tagPhotoCache[key] { return cached }
        let resolved = resolve(core.photoIdsForTag(fullPath: key))
        tagPhotoCache[key] = resolved
        return resolved
    }

    /// Filter the sorted photo list by AND-combining required tags and an
    /// optional substring query.
    ///
    /// Unlike the Swift original this takes no `allTags` argument: the core
    /// holds the aggregated list from its own build and uses it for the
    /// exact-tag-path branch. The old signature let a caller pass an empty list
    /// and silently degrade every tag query — including the *virtual* prefix
    /// tags no photo carries — to a substring match.
    func search(query: String, requiredTags: [TagSuggestion] = []) -> [PhotoFile] {
        let paths = requiredTags.map(\.fullPath)
        let key = "\(query)\u{0}\(paths.joined(separator: "\u{0}"))"
        if let cached = searchCache, cached.key == key { return cached.result }
        let t = CFAbsoluteTimeGetCurrent()
        let resolved = resolve(core.search(query: query, requiredTagPaths: paths))
        searchCache = (key, resolved)
        Log.search.debug("""
            "\(Log.r.other(query))" tags:\(requiredTags.map { Log.r.tag($0.displayName) }) \
            → \(resolved.count) matches in \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t) * 1000))ms
            """)
        return resolved
    }

    // MARK: Bridging

    /// Core ids → the app's photo structs, dropping ids the table no longer
    /// knows (a rebuild that has not landed yet, or a photo removed since).
    private func resolve(_ ids: [String]) -> [PhotoFile] {
        ids.compactMap { UUID(uuidString: $0).flatMap { photoByID[$0] } }
    }

    private static func suggestion(from record: TagSuggestionRecord) -> TagSuggestion {
        TagSuggestion(
            id: record.id,
            displayName: record.displayName,
            fullPath: record.fullPath,
            namespace: record.namespace,
            count: Int(record.count),
            latestPhotoDate: record.latestPhotoDate.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }
}
