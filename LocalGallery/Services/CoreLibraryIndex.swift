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
    /// resolved through. Built synchronously in `build(allPhotos:)` because
    /// `photo(byID:)` is on the viewer's and the memory rail's critical path and
    /// must never be a frame behind `allPhotos`.
    @ObservationIgnored private var photoByID: [UUID: PhotoFile] = [:]

    /// False until the first rebuild publishes.
    ///
    /// `sortedPhotos` is empty for the ~400 ms between `apply(_:)` and the
    /// first publish, and an empty *sorted* list is indistinguishable from an
    /// empty *library* to a view that only sees the former — which is how a
    /// cold launch with a warm cache flashed "No photos match." over a library
    /// the user definitely has. Views that render `sortedPhotos` check this
    /// before deciding they have nothing to show.
    private(set) var hasEverPublished = false

    // MARK: Wiring

    @ObservationIgnored private let core = LibraryIndex()
    /// Cancels a stale rebuild's publish. Same shape as the old
    /// `tagBuildGeneration`, now covering the whole rebuild rather than just
    /// the tag half.
    @ObservationIgnored private var generation = 0
    /// The in-flight rebuild, so tests can wait for the index to settle rather
    /// than poll — and so the *next* rebuild can wait for it before touching
    /// the core (see `build(allPhotos:)`).
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Memoised `photos(forTag:)` answers, cleared when a rebuild **publishes**.
    ///
    /// Not a second tag index: the keys, the membership and the order all come
    /// from the core. This is a cache of its replies, and it exists because
    /// `PeopleListRow` and `PersonCard` ask the same question inside a
    /// `ScrollView` body.
    ///
    /// Cleared at publish rather than at the start of a rebuild, and that is
    /// the whole point: between the two the core still holds the *previous*
    /// index while `photoByID` already holds the new library, so a query in
    /// that window answers with ids the table cannot resolve — usually an empty
    /// list. Clearing first meant that answer was cached *after* the clear and
    /// outlived the rebuild entirely: blank `PersonCard`s and an empty
    /// `TagGridView` until something else happened to rescan.
    @ObservationIgnored private var tagPhotoCache: [String: [PhotoFile]] = [:]
    /// Single-entry memo for `search`, for the same reason: `TagGridView.photos`
    /// is a computed property evaluated on every body pass. Same publish-time
    /// invalidation as `tagPhotoCache`.
    @ObservationIgnored private var searchCache: (key: String, result: [PhotoFile])?

    // MARK: Build

    /// Publish `allPhotos` as the object table and kick off the core rebuild.
    ///
    /// Split in two on purpose. The dictionary is built here, synchronously, so
    /// `photo(byID:)` is correct the instant `apply(_:)` returns. The sort, the
    /// corpus and the tag aggregation — the parts that were 0.25–0.3 s of main
    /// thread on a 20k library — go to the core on a detached task, and so does
    /// everything around them: marshalling 20k `PhotoFile`s into `ScanPhoto`
    /// records (14–22 ms) and resolving 20k ids back through `table`
    /// (`UUID(uuidString:)` per id plus a dictionary hit) are both work the main
    /// actor has no reason to do. Only the assignment of the finished arrays
    /// happens back here.
    ///
    /// **Core builds are serialised.** Cancelling `pending` stops a stale
    /// rebuild from *publishing*, but not from running: the inner detached task
    /// is not a child, and the core takes its write lock only after its build
    /// finishes, so two overlapping rebuilds swap in whichever order they
    /// happen to end. The published Swift state would be the fresh one and the
    /// core's index the stale one — and since queries go to the core, every
    /// `search` / `photos(forTag:)` would answer from a library the app no
    /// longer shows. Awaiting the previous rebuild first makes last-started =
    /// last-swapped, and costs nothing a second concurrent CPU-bound build was
    /// not costing already.
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
        // An immutable copy for the detached task: a `var` local is main-actor
        // isolated to region analysis even when its type is `Sendable`, and the
        // build task resolves the core's ids through it.
        let lookup = table

        let previous = pending
        previous?.cancel()
        let core = self.core
        pending = Task { [weak self] in
            // Cancelled or not, the previous rebuild's core call runs to
            // completion; waiting for it is what orders the two swaps.
            await previous?.value
            let t = CFAbsoluteTimeGetCurrent()
            let built = await Task.detached(priority: .userInitiated) { () -> Built in
                let start = CFAbsoluteTimeGetCurrent()
                let records = allPhotos.map(CoreScanner.record(of:))
                let marshalled = CFAbsoluteTimeGetCurrent()
                let summary = core.build(photos: records)
                // The core's records never reach the main actor: they are not
                // `Sendable` (UniFFI does not mark them) and resolving them is
                // 20k `UUID(uuidString:)` parses plus 20k dictionary hits, which
                // is exactly the kind of work this hop exists to move.
                return Built(
                    sorted: summary.sortedPhotoIds.compactMap {
                        UUID(uuidString: $0).flatMap { lookup[$0] }
                    },
                    tags: summary.tags.map(Self.suggestion(from:)),
                    people: summary.people.map(Self.suggestion(from:)),
                    marshalMillis: (marshalled - start) * 1000,
                    coreMillis: Double(summary.buildMillis)
                )
            }.value
            guard !Task.isCancelled, let self, self.generation == generation else { return }

            // Everything below this line is one main-actor turn: the memos are
            // dropped and the new answers published without a suspension in
            // between, so no query can observe half of a rebuild.
            self.tagPhotoCache = [:]
            self.searchCache = nil
            self.sortedPhotos = built.sorted
            self.allTags = built.tags
            self.peopleTags = built.people
            self.hasEverPublished = true
            self.onRebuild?(self.allTags, self.peopleTags)

            let total = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t) * 1000)
            Log.index.info("""
                Built: \(allPhotos.count) photos, \(built.tags.count) unique tags, \
                \(built.people.count) people in \(total)ms \
                (in=\(String(format: "%.0f", built.marshalMillis))ms \
                core=\(String(format: "%.0f", built.coreMillis))ms)
                """)
        }
    }

    /// Fired on the main actor after every rebuild publishes, with the freshly
    /// aggregated lists. The Store uses it to push `topPeople` into
    /// `PeopleStore` and re-export the widget snapshot — the two things the old
    /// `Task.detached` tail in `rebuildSortAndIndex` did.
    @ObservationIgnored var onRebuild: (([TagSuggestion], [TagSuggestion]) -> Void)?

    /// Wait for the in-flight rebuild, if any.
    ///
    /// **Tests only.** No production path awaits it, and none should: the app's
    /// contract is that `photo(byID:)` is correct immediately and the sorted /
    /// aggregated views arrive when they arrive, observed rather than awaited.
    /// A caller that blocked on this would be reintroducing the main-thread
    /// stall the rebuild was moved off the main actor to remove.
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

    /// One rebuild's results, already in the app's own types.
    ///
    /// Exists so the detached task can return something `Sendable`: the core's
    /// `LibraryIndexSummary` is not, and making it the hop's payload would have
    /// forced the id resolution and the suggestion mapping back onto the main
    /// actor — the two costs `_plans/05` measured at 14–22 ms and a 20k-entry
    /// dictionary walk.
    private struct Built: Sendable {
        let sorted: [PhotoFile]
        let tags: [TagSuggestion]
        let people: [TagSuggestion]
        let marshalMillis: Double
        let coreMillis: Double
    }

    /// Core ids → the app's photo structs, dropping ids the table no longer
    /// knows (a rebuild that has not landed yet, or a photo removed since).
    private func resolve(_ ids: [String]) -> [PhotoFile] {
        ids.compactMap { UUID(uuidString: $0).flatMap { photoByID[$0] } }
    }

    /// `nonisolated` because it runs inside the detached build task — it is a
    /// pure field-for-field copy and has no business hopping back.
    nonisolated private static func suggestion(from record: TagSuggestionRecord) -> TagSuggestion {
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
