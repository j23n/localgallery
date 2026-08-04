import Foundation
import Observation

/// People-rail domain state: hidden/featured people, the "me" person, the
/// per-person featured photo, and the derived visible-people lists. Extracted
/// from `GalleryStore` so the whole People feature lives (and can be tested)
/// in one place; views reach it via `store.people`.
///
/// Owns its UserDefaults persistence. Cross-domain side effects (memory
/// regeneration when hidden/me changes, widget re-export when visibility
/// changes) are injected as closures by the Store — this type knows nothing
/// about memories or widgets.
@Observable
@MainActor
final class PeopleStore {
    /// Person tag paths hidden from the rail, people list, and memories.
    private(set) var hiddenPeople: Set<String> = [] {
        didSet {
            defaults.set(Array(hiddenPeople), forKey: "hiddenPeople")
            onMemoryAffectingChange?()
        }
    }

    /// Person tag paths that are "featured" — sorted to the front of the
    /// People rail and decorated with a star. Stored under the legacy
    /// `pinnedPeople` key.
    private(set) var featuredPeople: [String] = [] {
        didSet { defaults.set(featuredPeople, forKey: "pinnedPeople") }
    }

    /// Per-person featured photo ID. Keyed by person tag fullPath (case-sensitive).
    private(set) var featuredPhotoByPerson: [String: UUID] = [:] {
        didSet {
            defaults.set(featuredPhotoByPerson.mapValues { $0.uuidString }, forKey: "featuredPhotoByPerson")
        }
    }

    /// Person tag fullPath ("People/<name>") that represents the current user.
    /// Excluded from "with X, Y, Z" trip-title suffixes so memories don't read
    /// "Chile with Anna, Bob & me". Empty string = unset.
    private(set) var mePersonPath: String = "" {
        didSet {
            guard oldValue != mePersonPath else { return }
            defaults.set(mePersonPath, forKey: "mePersonPath")
            // Trip titles depend on this — regenerate so the change surfaces
            // immediately instead of waiting for the daily gate.
            onMemoryAffectingChange?()
        }
    }

    /// All People/* tags with photo counts + latest-photo dates, sorted by
    /// count. Published here by the Store after each async tag aggregation.
    private(set) var topPeople: [TagSuggestion] = []

    // MARK: Wiring

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any Clock
    /// The core library index: O(1) photo lookup for featured-photo IDs, and
    /// the tag → photos buckets for the candidate pool. Strong reference is
    /// cycle-free: the index doesn't know about this type.
    @ObservationIgnored private let index: CoreLibraryIndex
    /// Set by the Store: hidden/me changes affect memory generation.
    @ObservationIgnored var onMemoryAffectingChange: (() -> Void)?
    /// Set by the Store: visibility changes affect the widget snapshot.
    @ObservationIgnored var onWidgetAffectingChange: (() -> Void)?

    init(
        defaults: UserDefaults,
        clock: any Clock,
        index: CoreLibraryIndex
    ) {
        self.defaults = defaults
        self.clock = clock
        self.index = index

        if let hidden = defaults.array(forKey: "hiddenPeople") as? [String] {
            hiddenPeople = Set(hidden)
        }
        if let pinned = defaults.array(forKey: "pinnedPeople") as? [String] {
            featuredPeople = pinned
        }
        if let dict = defaults.dictionary(forKey: "featuredPhotoByPerson") as? [String: String] {
            featuredPhotoByPerson = dict.compactMapValues { UUID(uuidString: $0) }
        }
        if let raw = defaults.string(forKey: "mePersonPath") {
            mePersonPath = raw
        }
    }

    /// Called by the Store after each tag aggregation pass.
    func updateTopPeople(_ people: [TagSuggestion]) {
        topPeople = people
    }

    // MARK: Derived lists

    /// People/* tags for pickers (me-person, contact linking). Same content
    /// as `topPeople` — the aggregation builds the people list from the tag
    /// list, so a separate filter over the global tag list would be redundant.
    var peopleTags: [TagSuggestion] { topPeople }

    /// All people with hidden filtered out and featured floated to the front
    /// (preserves feature order). Used by PeopleListView — no cap, no recency
    /// gate so the full roster is always reachable.
    var visiblePeople: [TagSuggestion] {
        orderedVisiblePeople(recencyGated: false, cap: nil)
    }

    /// Top 20 people for the Collections rail. Non-featured must have at least
    /// one photo dated within the past 2 years; featured bypass the recency
    /// gate (the user explicitly promoted them). Sorted by total photo count.
    var visiblePeopleForRail: [TagSuggestion] {
        orderedVisiblePeople(recencyGated: true, cap: 20)
    }

    /// Shared hidden-filter + featured-first ordering behind the two lists
    /// above.
    private func orderedVisiblePeople(recencyGated: Bool, cap: Int?) -> [TagSuggestion] {
        let visible = topPeople.filter { !hiddenPeople.contains($0.fullPath) }
        let featuredSet = Set(featuredPeople)
        let featuredFirst = featuredPeople.compactMap { path in visible.first { $0.fullPath == path } }
        var rest = visible.filter { !featuredSet.contains($0.fullPath) }
        if recencyGated {
            let now = clock.now()
            let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: now) ?? now
            rest = rest.filter { ($0.latestPhotoDate ?? .distantPast) > twoYearsAgo }
        }
        let ordered = featuredFirst + rest
        guard let cap else { return ordered }
        return Array(ordered.prefix(cap))
    }

    /// Hidden people resolved back to tags, for the Settings "Hidden People"
    /// list. Sorted by display name.
    var hiddenPeopleTags: [TagSuggestion] {
        hiddenPeople.compactMap { path in topPeople.first { $0.fullPath == path } }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Mutations

    func hidePerson(_ path: String) {
        hiddenPeople.insert(path)
        featuredPeople.removeAll { $0 == path }
        onWidgetAffectingChange?()
    }

    func unhidePerson(_ path: String) {
        hiddenPeople.remove(path)
        onWidgetAffectingChange?()
    }

    func isFeatured(_ path: String) -> Bool {
        featuredPeople.contains(path)
    }

    func toggleFeaturePerson(_ path: String) {
        if let idx = featuredPeople.firstIndex(of: path) {
            featuredPeople.remove(at: idx)
        } else {
            featuredPeople.append(path)
        }
        // Featured ordering floats people to the front of the rail, which
        // the widget mirrors.
        onWidgetAffectingChange?()
    }

    func isMe(_ path: String) -> Bool {
        !mePersonPath.isEmpty && mePersonPath == path
    }

    func markAsMe(_ path: String) {
        mePersonPath = path
    }

    func unmarkAsMe() {
        mePersonPath = ""
    }

    func setFeaturedPhoto(personPath: String, photoID: UUID) {
        featuredPhotoByPerson[personPath] = photoID
        onWidgetAffectingChange?()
    }

    // MARK: Cover photo / face region

    /// The photo chosen as the card image for a person. When the user hasn't
    /// pinned a specific photo, prefer photos where this person is the only
    /// one tagged (cleaner cover, no other faces to crop around), then sort
    /// by recency. Face-area-based ranking turned out to be unreliable when
    /// multiple regions exist and the matching region for *this person*
    /// can't be uniquely identified by name — solo-photo preference is a
    /// simpler proxy for "good portrait of this person".
    func featuredPhoto(for tag: TagSuggestion) -> PhotoFile? {
        if let id = featuredPhotoByPerson[tag.fullPath], let photo = index.photo(byID: id) {
            return photo
        }
        let candidates = index.photos(forTag: tag)
        guard !candidates.isEmpty else { return nil }
        let solo = candidates.filter { peopleTagCount(in: $0) == 1 }
        let pool = solo.isEmpty ? candidates : solo
        return pool.max { a, b in
            (a.dateTaken ?? .distantPast) < (b.dateTaken ?? .distantPast)
        }
    }

    private func peopleTagCount(in photo: PhotoFile) -> Int {
        photo.hierarchicalTags.filter { $0.namespace?.lowercased() == "people" }.count
    }

    /// Face region matching `tag.displayName` on a candidate cover photo.
    /// Tries exact lowercased match first; falls back to first-name or
    /// substring match in case the MWG `mwg-rs:Name` value differs slightly
    /// from the `People/<name>` tag leaf (e.g. tag "Anna" but region
    /// "Anna Smith", or vice versa). Returns nil when no region's name
    /// resembles the person.
    func faceRegion(for photo: PhotoFile, person displayName: String) -> FaceRegion? {
        let target = displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let targetFirst = target.split(separator: " ").first.map(String.init) ?? target

        // 1. Exact lowercased match.
        if let exact = photo.faceRegions.first(where: { ($0.name?.lowercased() ?? "") == target }) {
            return exact
        }
        // 2. First-name match (handles "Anna" tag → "Anna Smith" region or vice versa).
        if let firstMatch = photo.faceRegions.first(where: { region in
            guard let name = region.name?.lowercased(), !name.isEmpty else { return false }
            let regionFirst = name.split(separator: " ").first.map(String.init) ?? name
            return regionFirst == targetFirst
        }) {
            return firstMatch
        }
        // 3. Substring match either direction.
        if let sub = photo.faceRegions.first(where: { region in
            guard let name = region.name?.lowercased(), !name.isEmpty else { return false }
            return name.contains(target) || target.contains(name)
        }) {
            return sub
        }
        return nil
    }
}
