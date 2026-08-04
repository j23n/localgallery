import Foundation
import UIKit
import Contacts
import Observation
import os

/// Which kind of scan a caller wants. Most internal entry points default to
/// `.auto`, which runs a light scan but promotes to full when it's been more
/// than `fullScanInterval` since the last full pass. Pull-to-refresh and the
/// Settings "Reload Library" button pass `.full` for explicit user intent.
enum ScanKind: Sendable {
    case auto
    case light
    case full
}

/// Live progress of an in-flight scan. `nil` on `GalleryStore.scanProgress`
/// means no scan is running. Views observe the value to render a progress
/// banner; the store updates it from the scanner / enrichment callbacks.
struct ScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Walking folders and stat-ing files. `total` is `nil` because we
        /// don't know how many photos exist until the walk completes; views
        /// should render "X photos found" without an ETA.
        case scanning
        /// Reading EXIF / XMP / video creation dates. `total` is the
        /// up-front stale-file count, so views can show a percentage + ETA.
        case enriching
    }
    var phase: Phase
    var processed: Int
    /// Known up-front for `.enriching`; `nil` for `.scanning`.
    var total: Int?
    var startedAt: Date
    /// Display label for the phase (eg. "Scanning…", "Reading metadata…").
    var label: String {
        switch phase {
        case .scanning: return "Scanning…"
        case .enriching: return "Reading metadata…"
        }
    }
}

@Observable
@MainActor
final class GalleryStore {
    /// Interval since the last full scan after which an `.auto` scan
    /// promotes itself to a full one. The light-scan path skips file-provider
    /// probes and EXIF re-reads for unchanged files, so we still want a full
    /// pass occasionally to catch in-place EXIF edits and missed sidecars.
    /// 48h is the deterministic guarantee — every two days a full scan
    /// happens on the next foreground / pull-to-refresh, transparently.
    static let fullScanInterval: TimeInterval = 48 * 60 * 60

    var rootFolder: PhotoFolder?
    var allPhotos: [PhotoFile] = []
    var isScanning: Bool = false
    /// Live progress of an in-flight scan. `nil` when idle. Set from the
    /// `FolderScanner` and `EnrichmentService` callbacks; observed by the
    /// `ScanProgressBanner` on the three main tabs.
    var scanProgress: ScanProgress?
    var lastSyncedAt: Date?
    /// Timestamp of the most recent FULL scan completion. Persisted so the
    /// `fullScanInterval` `.auto`-mode promotion survives relaunch.
    /// Written only by the scan pipeline (GalleryStore+Scanning).
    var lastFullScanAt: Date?
    private(set) var eventFolders: [PhotoFolder] = []

    var folderSortOrder: FolderSortOrder = .nameAscending {
        didSet { defaults.set(folderSortOrder.rawValue, forKey: "folderSortOrder") }
    }

    /// Contacts loaded from the system address book. Empty until the user grants
    /// Contacts access. Populated by `loadContacts()` and refreshed when the app
    /// re-enters the foreground.
    private(set) var contacts: [ContactInfo] = [] {
        didSet { contactLinker.index(contacts) }
    }

    /// Explicit person-tag → contact decisions. Keyed by tag fullPath
    /// (case-sensitive). Absence from the dictionary means "auto-match by
    /// name"; entries record either a manual contact pick or an explicit
    /// "no birthdays for this person" choice. See `PersonLink`.
    var personContactLinks: [String: PersonLink] = [:] {
        didSet { persistPersonContactLinks() }
    }

    /// Pre-fetch neighbour photos in the viewer when the user lands on a
    /// file-provider placeholder. Default `true`; disable to save bandwidth.
    var prefetchAdjacentRemotePhotos: Bool = true {
        didSet { defaults.set(prefetchAdjacentRemotePhotos, forKey: "prefetchAdjacentRemotePhotos") }
    }
    /// When `false`, prefetch (only — explicit taps always go through) is
    /// gated on Wi-Fi/wired connectivity. Default `false` (Wi-Fi-only).
    var useCellularForDownloads: Bool = false {
        didSet { defaults.set(useCellularForDownloads, forKey: "useCellularForDownloads") }
    }

    /// Scan-pipeline state (GalleryStore+Scanning) — internal because the
    /// pipeline lives in a separate file; not meant for use elsewhere.
    @ObservationIgnored var isEnriching = false
    /// In-flight scan, keyed by URL + resolved kind. Concurrent callers for
    /// the same URL await the existing task instead of starting a second
    /// traversal (app launch + willEnterForeground + pull-to-refresh can
    /// otherwise overlap). The kind is kept so a `.full` request isn't
    /// silently satisfied by an in-flight light scan, and `startedAt` so no
    /// request is satisfied by a pass that began before the request existed —
    /// see `scanFolder`.
    @ObservationIgnored var activeScanTask: (url: URL, kind: ScanKind, startedAt: Date, task: Task<Void, Never>)?
    /// Most recent scanner-emitted sidecar manifest. `SidecarSyncService`
    /// diffs it after every scan; `SidecarRefreshService` re-reads it on the
    /// BG sidecar-refresh task.
    @ObservationIgnored var lastSidecarManifest: [FolderScanner.SidecarCandidate] = []
    @ObservationIgnored let bookmarks: BookmarkManager
    @ObservationIgnored private let contactLinker = ContactLinker()
    @ObservationIgnored private let searchService = SearchIndex()
    @ObservationIgnored private let tagService = TagIndex()
    @ObservationIgnored private let thumbnailService: ThumbnailService
    @ObservationIgnored private let widgetExport = WidgetExportScheduler()
    /// Materialises file-provider placeholders on demand. Exposed as a
    /// property so views can observe `inFlight` for spinner state.
    let materializer = PhotoMaterializer()
    /// People-rail domain (hidden/featured/me, visible lists, cover photos).
    /// Views reach it as `store.people`.
    let people: PeopleStore
    /// Parsed `.xmp` cache keyed by photo UUID. Lets cloud libraries surface
    /// tags/country codes/face regions even when the source `.xmp` files
    /// have been evicted by the provider.
    @ObservationIgnored let sidecarCache: SidecarCacheStore
    /// Persisted scan result (folder tree + flat photos), reloaded on launch
    /// so the grid renders before the first rescan finishes.
    @ObservationIgnored private let libraryCache: JSONDiskCache<LibrarySnapshot>
    /// Memories domain (generation gate, seen/cool-down state, hidden set,
    /// disk cache). Views reach it as `store.memories`.
    let memories: MemoryCoordinator
    /// Diffs the scanner's sidecar manifest against `sidecarCache` and
    /// fetches the deltas through `NSFileCoordinator`. Observed by the
    /// top-of-grid sync banner.
    let sidecarSync: SidecarSyncService
    /// On-device tagging (Rust core). Writes `.xmp` sidecars; its results come
    /// back through the ordinary sidecar pipeline, see `TaggingService`.
    let tagging: TaggingService
    /// On-device face detection, clustering and naming (Rust core). Shares the
    /// core's cache file and the model pack with `tagging` and nothing else —
    /// the two runs are independently resumable. Named results reach the app
    /// through the same sidecar pipeline, so `people` needs no new read path.
    let faces: FaceService

    // MARK: Injected seams (test-overridable; production uses `.production` /
    // `.standard` defaults so existing call sites are unchanged).

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let clock: any Clock
    @ObservationIgnored private let contactsService: any ContactsServicing
    /// NotificationCenter observer tokens. Set once in `init()` (on main),
    /// read once in `deinit` (on whatever thread released the last reference).
    /// `@ObservationIgnored` so the `@Observable` macro doesn't synthesize
    /// `_foregroundObserver` etc. for these (they aren't view state).
    /// `nonisolated(unsafe)` lets the implicit-nonisolated deinit access them;
    /// `Any?` isn't `Sendable`, hence the `(unsafe)`.
    @ObservationIgnored private nonisolated(unsafe) var foregroundObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var significantTimeChangeObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var contactStoreObserver: Any?

    init(
        paths: GalleryPaths = .production,
        defaults: UserDefaults = .standard,
        clock: any Clock = SystemClock(),
        contactsService: any ContactsServicing = LiveContactsService()
    ) {
        self.defaults = defaults
        self.clock = clock
        self.contactsService = contactsService
        self.bookmarks = BookmarkManager(defaults: defaults, bookmarkKey: paths.bookmarkKey)
        self.thumbnailService = ThumbnailService(thumbnailDir: paths.thumbnailDir)
        self.libraryCache = JSONDiskCache(
            url: paths.libraryCacheURL,
            version: LibrarySnapshot.version,
            label: "library cache"
        )
        let sidecarCache = SidecarCacheStore(url: paths.sidecarCacheURL)
        self.sidecarCache = sidecarCache
        self.sidecarSync = SidecarSyncService(cache: sidecarCache)
        let people = PeopleStore(
            defaults: defaults,
            clock: clock,
            searchIndex: searchService,
            tagIndex: tagService
        )
        self.people = people
        self.memories = MemoryCoordinator(
            defaults: defaults,
            clock: clock,
            cache: JSONDiskCache(
                url: paths.memoriesCacheURL,
                version: MemoriesCacheSchema.version,
                label: "memories cache"
            ),
            searchIndex: searchService,
            people: people
        )
        // One coalescer for both core engines. The interval is a budget for
        // interrupting the user with a library rescan; two engines each holding
        // their own instance spent it twice, which is exactly what the window
        // exists to prevent.
        let sidecarRefresh = SidecarRefreshCoalescer(interval: TaggingService.refreshInterval)
        self.tagging = TaggingService(
            cacheDatabaseURL: paths.mlCacheDatabaseURL,
            modelPacksDirectory: paths.modelPacksDirectoryURL,
            refresh: sidecarRefresh
        )
        self.faces = FaceService(
            cacheDatabaseURL: paths.mlCacheDatabaseURL,
            refresh: sidecarRefresh
        )
        self.sidecarSync.onFinished = { @MainActor [weak self] in
            self?.reapplySidecarMerges()
        }
        self.tagging.eligiblePhotos = { [weak self] in self?.allPhotos ?? [] }
        // The core's cache DB outlives any one library root, so a run is
        // confined to the root currently in scope — otherwise rows enqueued
        // under a folder the user has switched away from would be tagged, and
        // sidecars written outside the library on screen.
        self.tagging.libraryRoot = { [weak self] in self?.bookmarks.activeURL }
        // Both core engines create sidecars the last scan never saw, so the
        // only entry point that picks them up is a fresh scan: the light pass
        // rebuilds the sidecar manifest (reusing cached PhotoFiles, so it is a
        // stat per file and no EXIF), which feeds SidecarSyncService →
        // reapplySidecarMerges → indexes/widget. See TaggingService's docs.
        //
        // Set on the shared coalescer rather than through each service's
        // `onSidecarsWritten` passthrough: those write to the same stored
        // property, so assigning both would silently be one assignment.
        sidecarRefresh.onRefresh = { [weak self] in
            await self?.rescan(kind: .light, silent: true)
        }
        // Faces read the pack `TaggingService` already found and verified,
        // rather than discovering (and re-hashing) the same directory twice.
        self.faces.installedPack = { [weak self] in self?.tagging.pack }
        // `tagging.pack` is nil until somebody looks for one, and until now the
        // only caller was Settings. A cold launch that never opened Settings
        // therefore had no faces UI at all.
        self.faces.ensurePackChecked = { [weak self] in
            await self?.tagging.refreshAvailability()
        }
        // The two engines share a cache file and a sidecar per photo, and each
        // core session only guards its own run. This is the other half.
        self.faces.otherEngineIsRunning = { [weak self] in self?.tagging.isRunning ?? false }
        self.faces.eligiblePhotos = { [weak self] in self?.allPhotos ?? [] }
        self.faces.libraryRoot = { [weak self] in self?.bookmarks.activeURL }
        // An imported pack replaces the face models the open FaceSession holds.
        self.tagging.onPackWillChange = { [weak self] in
            await self?.faces.invalidateSession()
        }
        self.people.onMemoryAffectingChange = { [weak self] in
            self?.memories.forceRegenerate()
        }
        self.memories.makeInputs = { [weak self] in
            guard let self else { return nil }
            return MemoryCoordinator.GenerationInputs(
                photos: self.allPhotos,
                leafFolders: self._cachedLeafFolders,
                contacts: self.contacts,
                personContactLinks: self.personContactLinks,
                contactsByLowerName: self.contactLinker.contactsByLowerName,
                mePersonPath: self.people.mePersonPath,
                hiddenPeople: self.people.hiddenPeople
            )
        }
        self.memories.onMemoriesPublished = { [weak self] in
            self?.exportWidgetSnapshot()
        }
        self.people.onWidgetAffectingChange = { [weak self] in
            self?.exportWidgetSnapshot()
        }

        if let raw = defaults.string(forKey: "folderSortOrder"),
           let order = FolderSortOrder(rawValue: raw) {
            folderSortOrder = order
        }
        if let raw = defaults.object(forKey: "lastFullScanAt") as? Date {
            lastFullScanAt = raw
        }
        if let data = defaults.data(forKey: "personContactLinks"),
           let dict = try? JSONDecoder().decode([String: FailableDecodable<PersonLink>].self, from: data) {
            // Per-entry tolerant decode — one bad entry must not wipe the
            // user's entire set of manual contact links.
            personContactLinks = dict.compactMapValues(\.value)
        }
        if defaults.object(forKey: "prefetchAdjacentRemotePhotos") != nil {
            prefetchAdjacentRemotePhotos = defaults.bool(forKey: "prefetchAdjacentRemotePhotos")
        }
        if defaults.object(forKey: "useCellularForDownloads") != nil {
            useCellularForDownloads = defaults.bool(forKey: "useCellularForDownloads")
        }

        // Load cache + start security scope synchronously so cached
        // URLs are accessible before the first SwiftUI render
        if loadCache(), let url = resolveBookmark() {
            startAccessingFolder(url)
        }
        // Note: no eager exportWidgetSnapshot() here. Tag aggregation runs in
        // a Task.detached off rebuildSortAndIndex() and triggers its own
        // export once the tag catalog is populated, which gives the widget a
        // complete first snapshot rather than an empty-tags one we'd
        // immediately replace.

        // Rescan when app returns to foreground (e.g. user added files in Files app)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadContacts()
                if let url = self.bookmarks.activeURL {
                    await self.scanFolder(at: url, kind: .auto, silent: true)
                }
                // Day rolled over while the app was backgrounded? Re-export so
                // the Memories widget gets fresh "On this day" content even if
                // no scan happened.
                self.refreshWidgetIfDayChanged()
            }
        }

        // Catches the day-rollover case where the app stays foregrounded past
        // midnight. iOS posts `significantTimeChangeNotification` for both
        // midnight and timezone shifts; either case wants a memory rebuild.
        significantTimeChangeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWidgetIfDayChanged()
            }
        }

        // Address-book mutations while the app is foregrounded — new contact,
        // edited birthday, etc. Without this, birthday memories only pick up
        // changes on the next foreground transition. iOS coalesces multiple
        // edits into one notification, so a reload-on-fire is cheap.
        contactStoreObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadContacts()
            }
        }
    }

    /// Tracks the calendar day that produced the last widget export. Seeded
    /// from `memories.generatedDay` (persisted on disk) so the very first
    /// foreground entry of a new day rebuilds the snapshot — without
    /// pessimistically forcing a regeneration on every cold launch.
    @ObservationIgnored private var lastWidgetExportDay: Date?

    private func refreshWidgetIfDayChanged() {
        let today = Calendar.current.startOfDay(for: clock.now())
        let reference = lastWidgetExportDay ?? memories.generatedDay
        if let reference, Calendar.current.isDate(reference, inSameDayAs: today) {
            return
        }
        lastWidgetExportDay = today
        // Memories generation is gated to once per day; force a rebuild so
        // today's onThisDay / yearsAgo / birthday content is current.
        if !allPhotos.isEmpty {
            memories.forceRegenerate()
        }
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = significantTimeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = contactStoreObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // BookmarkManager's deinit releases the security scope.
    }

    // MARK: - Bookmark / Security-Scoped Access (forwarded to BookmarkManager)

    func startAccessingFolder(_ url: URL) {
        bookmarks.startAccessing(url)
    }

    func saveBookmark(for url: URL) {
        bookmarks.save(for: url)
    }

    func resolveBookmark() -> URL? {
        bookmarks.resolve()
    }

    // MARK: - Disk Cache

    private func saveCache() {
        guard let root = rootFolder else { return }
        libraryCache.save(LibrarySnapshot(rootFolder: root, allPhotos: allPhotos))
    }

    // MARK: - Contacts

    /// Prompt for Contacts access and load on grant. Safe to call repeatedly.
    @discardableResult
    func requestContactsAccess() async -> Bool {
        let granted = await contactsService.requestAccess()
        if granted { await loadContacts() }
        return granted
    }

    /// Load contacts if access is already granted. No-op when denied.
    /// When the address-book contents that affect birthday memories actually
    /// change (new contact, edited birthday, renamed person), force a memory
    /// rebuild so the change surfaces without waiting for the daily gate.
    func loadContacts() async {
        let previous = contacts
        let loaded = await contactsService.loadContacts()
        contacts = loaded
        if ContactLinker.birthdayRelevantSignature(loaded) != ContactLinker.birthdayRelevantSignature(previous) {
            memories.forceRegenerate()
        }
    }

    /// Manually link a person tag to a contact. Triggers a memory rebuild so
    /// the new link is reflected on the next launch (or right away if today is
    /// the contact's birthday).
    func linkPerson(_ personPath: String, toContactID contactID: String) {
        personContactLinks[personPath] = .manual(contactID: contactID)
        Log.contacts.info("Linked '\(Log.r.person(personPath))' to contact \(Log.r.contact(contactID))")
        memories.forceRegenerate()
    }

    /// Disable any contact link for a person tag. Records `.disabled` so the
    /// auto-match by name does not re-apply.
    func unlinkPerson(_ personPath: String) {
        personContactLinks[personPath] = .disabled
        Log.contacts.info("Unlinked '\(Log.r.person(personPath))' (auto-match disabled)")
        memories.forceRegenerate()
    }

    /// Forget any manual override — auto-match by name resumes for this person.
    func resetPersonLink(_ personPath: String) {
        personContactLinks.removeValue(forKey: personPath)
        Log.contacts.info("Reset link for '\(Log.r.person(personPath))' (auto-match restored)")
        memories.forceRegenerate()
    }

    /// Backing store for the `personContactLinks` didSet. PersonLink is an
    /// enum with associated values, so it round-trips through JSON rather
    /// than a flat UserDefaults dict; the loader in `init` decodes each
    /// entry tolerantly via `FailableDecodable`.
    private func persistPersonContactLinks() {
        guard let data = try? JSONEncoder().encode(personContactLinks) else { return }
        defaults.set(data, forKey: "personContactLinks")
    }

    /// Resolved link state for a person tag — what the UI should display.
    /// Forwards to `ContactLinker` which owns the indexes; the Store
    /// passes in the observed `personContactLinks` dictionary.
    func linkState(forPersonPath path: String, displayName: String) -> ContactLinker.LinkState {
        contactLinker.linkState(forPersonPath: path, displayName: displayName, links: personContactLinks)
    }

    /// Effective contact for a person tag: manual link if present, otherwise
    /// the auto-match by case-insensitive equality of `displayName` to
    /// `<given> <family>`. Returns `nil` when the user explicitly disabled
    /// the link or no contact matches.
    func effectiveContact(forPersonPath path: String, displayName: String) -> ContactInfo? {
        contactLinker.effectiveContact(forPersonPath: path, displayName: displayName, links: personContactLinks)
    }

    @discardableResult
    internal func loadCache() -> Bool {
        guard let cached = libraryCache.load() else {
            // Library cache evicted (version bump, corrupt file) or absent:
            // the memories cache references photo IDs from that schema, so
            // it goes too. The in-memory list keeps rendering —
            // `memories.visible` filters unresolvable IDs — until the rescan
            // regenerates them.
            memories.clearDiskCache()
            return false
        }
        Log.cache.info("Loaded \(cached.allPhotos.count) photos from cache v\(LibrarySnapshot.version)")
        // No persist — we just read this off disk, no need to write it back.
        apply(.scanResult(photos: cached.allPhotos, root: cached.rootFolder, persistCache: false))
        return true
    }

    // MARK: - Photo-library mutations

    /// All in-memory mutations to `allPhotos` / `rootFolder` go through
    /// `apply(_:)`. The invariant — "indexes and the on-disk library cache
    /// match `allPhotos`" — lives next to the mutation cases instead of
    /// being re-derived at every call site.
    ///
    /// Per-case behaviour:
    ///   - `.scanResult` rebuilds indexes; persists the library cache when
    ///     `persistCache` is true. (The empty/non-silent branch sets false
    ///     so a transient access failure doesn't wipe a good cache.)
    ///   - `.sidecarsMerged` rebuilds indexes and persists.
    ///   - `.photoLocalityChanged`, `.allDownloadsCleared`, and
    ///     `.sidecarCacheCleared` only update in-memory locality / sidecar
    ///     status — no rebuild, no save. The next scan repopulates from
    ///     disk; this matches the pre-refactor behaviour for those paths
    ///     and avoids churning the cache on every download completion.
    ///
    /// The widget snapshot, memory regeneration, and sidecar-sync planning
    /// are intentionally NOT triggered from here — they depend on
    /// scan-specific arguments (manifest, allIDs) and stay in `performScan`.
    enum PhotoLibraryMutation {
        case scanResult(photos: [PhotoFile], root: PhotoFolder?, persistCache: Bool)
        case sidecarsMerged(photos: [PhotoFile])
        case photoLocalityChanged(id: UUID, locality: PhotoLocality)
        case allDownloadsCleared
        case sidecarCacheCleared
    }

    func apply(_ mutation: PhotoLibraryMutation) {
        switch mutation {
        case let .scanResult(photos, root, persistCache):
            self.rootFolder = root
            self.allPhotos = photos
            rebuildSortAndIndex()
            if persistCache { saveCache() }
        case let .sidecarsMerged(photos):
            self.allPhotos = photos
            rebuildSortAndIndex()
            saveCache()
        case let .photoLocalityChanged(id, locality):
            guard let idx = allPhotos.firstIndex(where: { $0.id == id }) else { return }
            // Placeholder → downloaded: the first enrichment ran against a
            // byteless file, so clear the marker and the next enrichment
            // pass reads the real EXIF/GPS.
            if case .remote(downloaded: false) = allPhotos[idx].locality,
               case .remote(downloaded: true) = locality {
                allPhotos[idx].enrichedFileDate = nil
            }
            allPhotos[idx].locality = locality
        case .allDownloadsCleared:
            for i in allPhotos.indices {
                if case .remote = allPhotos[i].locality {
                    allPhotos[i].locality = .remote(downloaded: false)
                }
            }
        case .sidecarCacheCleared:
            for i in allPhotos.indices {
                allPhotos[i].sidecarStatus = .absent
            }
        }
    }

    // MARK: - Sorted / Search / Tags

    /// All unique tags across the library, sorted by frequency.
    private(set) var allTags: [TagSuggestion] = []
    /// Generation counter to cancel stale tag aggregation tasks.
    @ObservationIgnored private var tagBuildGeneration = 0
    /// Cached leaf folders (no subfolders, has photos).
    @ObservationIgnored private var _cachedLeafFolders: [PhotoFolder] = []

    /// Date-descending photo list. Forwards to `SearchIndex`; observation
    /// chains through because `SearchIndex` is `@Observable`.
    var sortedPhotos: [PhotoFile] { searchService.sortedPhotos }

    /// O(1) photo lookup by ID. Forwards to `SearchIndex`.
    func photo(byID id: UUID) -> PhotoFile? { searchService.photo(byID: id) }

    /// O(1) photos for a given tag. Forwards to `TagIndex`.
    func photos(forTag tag: TagSuggestion) -> [PhotoFile] {
        tagService.photos(forTag: tag)
    }

    internal func rebuildSortAndIndex() {
        let t = CFAbsoluteTimeGetCurrent()
        searchService.build(allPhotos: allPhotos)
        tagService.build(allPhotos: allPhotos)
        let withTags = allPhotos.filter { !$0.hierarchicalTags.isEmpty }.count
        let withDates = allPhotos.filter { $0.dateTaken != nil }.count

        // Cache leaf folders and pre-compute event folders
        _cachedLeafFolders = rootFolder.map { Self.collectLeafFolders($0) } ?? []
        eventFolders = _cachedLeafFolders.sorted { a, b in
            let aDate = a.photos.compactMap(\.dateTaken).max() ?? .distantPast
            let bDate = b.photos.compactMap(\.dateTaken).max() ?? .distantPast
            return aDate > bDate
        }

        Log.index.info("Built: \(self.allPhotos.count) photos (\(withDates) dates, \(withTags) tagged) in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t) * 1000))ms")

        // Aggregate global tag list + topPeople in background to avoid blocking scroll
        tagBuildGeneration += 1
        let generation = tagBuildGeneration
        let tagPhotosSnapshot = tagService.photosForTag
        let canonicalPathSnapshot = tagService.canonicalPath
        Task.detached(priority: .utility) {
            let (tags, people) = TagIndex.aggregateTagsAndPeople(
                photosForTag: tagPhotosSnapshot,
                canonicalPath: canonicalPathSnapshot
            )

            await MainActor.run { [weak self] in
                guard let self, self.tagBuildGeneration == generation else { return }
                self.allTags = tags
                self.people.updateTopPeople(people)
                Log.index.info("Tags: \(tags.count) unique, \(people.count) people")
                // Tag aggregation populates the widget Tags picker — re-export
                // so the catalog reflects the latest set.
                self.exportWidgetSnapshot()
            }
        }
    }

    /// Background-task entry point. Refreshes contacts (in case the user
    /// added or edited birthdays since the app last ran), then hands off to
    /// the coordinator's awaited once-a-day refresh so iOS knows when to
    /// mark the BG task finished. We don't rescan the photo library in
    /// background — folder bookmarks require an active security scope which
    /// the system may not honor for a BGAppRefreshTask; birthday detection
    /// only needs `allPhotos` (already in memory from the last foreground
    /// scan) plus `contacts`.
    func runScheduledMemoryRefresh() async {
        await loadContacts()
        await memories.runScheduledRefresh()
    }

    func sortFolders(_ folders: [PhotoFolder]) -> [PhotoFolder] {
        switch folderSortOrder {
        case .nameAscending:
            return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateModifiedNewest:
            return folders.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        case .dateModifiedOldest:
            return folders.sorted { ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast) }
        case .dateCreatedNewest:
            return folders.sorted { ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast) }
        case .dateCreatedOldest:
            return folders.sorted { ($0.dateCreated ?? .distantPast) < ($1.dateCreated ?? .distantPast) }
        }
    }

    func search(query: String, requiredTags: [TagSuggestion] = []) -> [PhotoFile] {
        searchService.search(query: query, requiredTags: requiredTags, allTags: allTags)
    }

    // MARK: - Widget Snapshot

    /// Build a widget snapshot from current state and hand it to the exporter.
    /// Cheap to call: the exporter de-duplicates work and only re-encodes
    /// thumbnails whose source files changed.
    ///
    /// We pass `memories.visible` verbatim so the widget rail mirrors the
    /// in-app rail — every widget item id resolves to a memory the app can
    /// open. Calendar-tied memories (`onThisDay`, `yearsAgo`, birthdays)
    /// for the next `scheduledMemoryHorizonDays` days are computed up-front
    /// so the widget can rotate to them on their day even if the app isn't
    /// relaunched in between. Each scheduled item carries its own validity
    /// window; when the user finally opens the app on the matching day,
    /// foreground catch-up regenerates a memory with the same id so the
    /// widget deep link resolves.
    func exportWidgetSnapshot() {
        // Widgets read from the App Group container in a separate process —
        // file-provider placeholders are not guaranteed readable there. Drop
        // them so the widget never tries to render bytes that aren't local.
        let widgetPhotos = allPhotos.filter { photo in
            switch photo.locality {
            case .local: return true
            case .remote(let downloaded): return downloaded
            }
        }
        let scheduled = computeScheduledMemories(photos: widgetPhotos)
        widgetExport.schedule(WidgetSnapshotExporter.Inputs(
            allPhotos: widgetPhotos,
            memories: memories.visible,
            allTags: allTags,
            rootFolder: rootFolder,
            leafFolders: _cachedLeafFolders,
            scheduled: scheduled
        ))
    }

    /// How far ahead to pre-publish calendar-tied memories into the widget
    /// snapshot. 7 days covers a typical "user opens the app weekly" cadence
    /// without bloating thumbnail storage.
    private static let scheduledMemoryHorizonDays = 7

    /// Pre-compute the next `scheduledMemoryHorizonDays` days of calendar-
    /// tied memories (onThisDay, yearsAgo, birthdays) so the widget can
    /// surface them on the matching day without waiting for the next app
    /// launch. Excludes day 0 — that's already in `memories.visible`.
    ///
    /// Photos get bucketed by (month, day) once up-front so each day's
    /// onThisDay/yearsAgo filter walks a small candidate set instead of the
    /// full library — keeps the main-actor cost flat for large libraries.
    private func computeScheduledMemories(photos: [PhotoFile]) -> [WidgetSnapshotExporter.ScheduledMemory] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: clock.now())

        let photosWithDates = photos.compactMap { photo -> (PhotoFile, Date)? in
            guard let date = photo.dateTaken else { return nil }
            return (photo, date)
        }
        var byMonthDay: [DateComponents: [(PhotoFile, Date)]] = [:]
        for entry in photosWithDates {
            let key = cal.dateComponents([.month, .day], from: entry.1)
            byMonthDay[key, default: []].append(entry)
        }

        var out: [WidgetSnapshotExporter.ScheduledMemory] = []
        for offset in 1...Self.scheduledMemoryHorizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let nextDay = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
            let dayComps = cal.dateComponents([.month, .day], from: day)
            let bucket = byMonthDay[dayComps] ?? []

            var dayMemories: [Memory] = []
            if let m = MemoryEngine.generateOnThisDay(for: day, in: bucket, calendar: cal) {
                dayMemories.append(m)
            }
            dayMemories.append(contentsOf: MemoryEngine.generateYearsAgo(for: day, in: bucket, calendar: cal))
            if memories.birthdaysEnabled {
                // Birthdays walk all photos by People/* tag rather than by
                // date bucket, so we pass `photos` directly.
                dayMemories += MemoryEngine.generateBirthdayMemories(
                    from: photos,
                    contacts: contacts,
                    links: personContactLinks,
                    lowerNameIndex: contactLinker.contactsByLowerName,
                    calendar: cal,
                    todayComponents: dayComps,
                    hiddenPeople: people.hiddenPeople
                )
            }

            // Same finalize step as `generate` (photo cap + subtitle) so a
            // pre-published scheduled item looks identical to the memory the
            // foreground catch-up regenerates on its day.
            for memory in MemoryEngine.finalize(dayMemories) where !memories.hiddenMemories.contains(memory.id) {
                out.append(WidgetSnapshotExporter.ScheduledMemory(
                    memory: memory,
                    validFrom: day,
                    validTo: nextDay
                ))
            }
        }
        return out
    }

    var leafFolders: [PhotoFolder] { _cachedLeafFolders }

    private static func collectLeafFolders(_ folder: PhotoFolder) -> [PhotoFolder] {
        if folder.subfolders.isEmpty && !folder.photos.isEmpty {
            return [folder]
        }
        return folder.subfolders.flatMap { collectLeafFolders($0) }
    }

    // MARK: - Memories

    /// Resolve photo IDs from a memory back to PhotoFile instances.
    func photos(for memory: Memory) -> [PhotoFile] {
        memory.photoIDs.compactMap { searchService.photo(byID: $0) }
    }

    // MARK: - Thumbnails (forwarded to ThumbnailService)

    func cachedThumbnail(for url: URL) -> UIImage? {
        thumbnailService.cachedThumbnail(for: url)
    }

    func thumbnail(for url: URL, size: CGSize, isVideo: Bool = false, useQuickLook: Bool = false) async -> UIImage? {
        await thumbnailService.thumbnail(for: url, size: size, isVideo: isVideo, useQuickLook: useQuickLook)
    }

    func clearThumbnailCache() {
        thumbnailService.clearThumbnailCache()
    }

    // MARK: - EXIF (forwarded to EXIFService)

    func loadEXIF(for photo: PhotoFile) async -> EXIFData? {
        await EXIFService.loadEXIF(for: photo)
    }

    /// Reads the `photo-tools` custom XMP namespace (§1.2 of xmp-schema.md)
    /// from embedded XMP and the optional `.xmp` sidecar.
    func loadPhotoToolsMetadata(for photo: PhotoFile) async -> PhotoToolsMetadata {
        await EXIFService.loadPhotoToolsMetadata(for: photo)
    }

    // MARK: - Full Resolution

    func loadFullImage(for url: URL) async -> UIImage? {
        await thumbnailService.loadFullImage(for: url)
    }

    // MARK: - Materialization (forwarded to PhotoMaterializer)

    /// Ensure the photo's bytes are present on disk. Local photos return
    /// immediately; placeholders coordinate-read through the file provider.
    /// Throws on failure so the caller can offer a retry button.
    @discardableResult
    func ensureMaterialized(_ photo: PhotoFile) async throws -> URL {
        let url = try await materializer.ensureMaterialized(photo)
        // Mark this photo as downloaded in the in-memory model so the grid
        // badge clears without waiting for a rescan. Cache write is deferred
        // to the next save.
        if let existing = searchService.photo(byID: photo.id),
           case .remote = existing.locality {
            apply(.photoLocalityChanged(id: photo.id, locality: .remote(downloaded: true)))
        }
        return url
    }

    func cancelMaterialize(_ photoID: PhotoFile.ID) {
        materializer.cancel(photoID)
    }

    func prefetchMaterialize(_ photos: [PhotoFile]) {
        materializer.prefetch(photos, allowCellular: useCellularForDownloads)
    }

    // MARK: - Cloud storage

    /// True when at least one folder backs onto a file provider. Drives the
    /// "Cloud Storage" section in Settings — purely-local libraries don't
    /// see any of this UI.
    var hasFileProviderPhotos: Bool {
        allPhotos.contains { photo in
            if case .remote = photo.locality { return true } else { return false }
        }
    }

    /// Snapshot the remote photos and hand them to `CloudStorageService`
    /// for the per-file download-status probe (off the main actor).
    func computeCloudStorageStats() async -> CloudStorageService.Stats {
        let remote = allPhotos.filter {
            if case .remote = $0.locality { return true } else { return false }
        }
        return await CloudStorageService.probeStats(of: remote)
    }

    /// Evict every materialised provider-backed photo. Grid stays usable
    /// because thumbnails + sidecar cache are untouched; only
    /// full-resolution viewing requires a re-download.
    func clearAllDownloads() async -> Int {
        let downloaded = allPhotos.filter {
            if case .remote(let d) = $0.locality { return d } else { return false }
        }
        let evicted = await CloudStorageService.evictAll(downloaded)
        // Refresh in-memory state regardless of evict success — next scan
        // will re-detect actual download status.
        apply(.allDownloadsCleared)
        Log.scan.info("Cleared \(evicted) downloads")
        return evicted
    }

    /// Wipe the sidecar cache and re-run sync the next time the scanner
    /// hands us a manifest. Used by the Settings "Re-download all sidecars"
    /// nuclear button.
    func clearSidecarCache() {
        sidecarCache.clear()
        apply(.sidecarCacheCleared)
    }
}

