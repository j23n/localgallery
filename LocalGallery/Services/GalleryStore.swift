import Foundation
import UIKit
import Contacts
import FileProvider
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
    private static let fullScanInterval: TimeInterval = 48 * 60 * 60

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
    private(set) var lastFullScanAt: Date?
    private(set) var memories: [Memory] = []
    private(set) var topPeople: [TagSuggestion] = []
    private(set) var eventFolders: [PhotoFolder] = []

    var folderSortOrder: FolderSortOrder = .nameAscending {
        didSet { defaults.set(folderSortOrder.rawValue, forKey: "folderSortOrder") }
    }

    var hiddenPeople: Set<String> = [] {
        didSet {
            defaults.set(Array(hiddenPeople), forKey: "hiddenPeople")
            forceRegenerateMemories()
        }
    }
    /// Person tag paths that are "featured" — sorted to the front of the People rail
    /// and decorated with a star. Stored under the legacy `pinnedPeople` key.
    var featuredPeople: [String] = [] {
        didSet { defaults.set(featuredPeople, forKey: "pinnedPeople") }
    }
    var hiddenMemories: Set<String> = [] {
        didSet { defaults.set(Array(hiddenMemories), forKey: "hiddenMemories") }
    }
    /// Memory IDs the user has tapped into (opened the slideshow). Keyed by
    /// memory ID → last-seen date. Memories seen within ~6 months are
    /// deprioritised so the rail stays fresh. Pruned at load to entries
    /// inside the last 12 months — entries older than that have no scoring
    /// effect (the engine only checks `> sixMonthsAgo`) and would otherwise
    /// accumulate forever as the user uses the app across years.
    @ObservationIgnored var seenMemoryIDs: [String: Date] = [:] {
        didSet { persistSeenMemoryIDs() }
    }
    /// Cluster keys (see `MemoryEngine.clusterKey(for:)`) → last date the
    /// cluster surfaced on the rail. Clusters are penalised for ~3 days
    /// after surfacing so a trip parent + sub-trips rotate across days.
    /// Pruned at load to entries from the last 7 days; that headroom
    /// covers the 3-day cool-down with slack for time-zone changes.
    @ObservationIgnored var surfacedClusters: [String: Date] = [:] {
        didSet { persistSurfacedClusters() }
    }
    /// Per-person featured photo ID. Keyed by person tag fullPath (case-sensitive).
    var featuredPhotoByPerson: [String: UUID] = [:] {
        didSet { persistFeaturedPhotoByPerson() }
    }

    /// Person tag fullPath ("People/<name>") that represents the current user.
    /// Excluded from "with X, Y, Z" trip-title suffixes so memories don't read
    /// "Chile with Anna, Bob & me". Empty string = unset.
    var mePersonPath: String = "" {
        didSet {
            guard oldValue != mePersonPath else { return }
            defaults.set(mePersonPath, forKey: "mePersonPath")
            // Trip titles depend on this — regenerate so the change surfaces
            // immediately instead of waiting for the daily gate.
            forceRegenerateMemories()
        }
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

    /// Master toggle for birthday memories. When `false`, `generateMemories`
    /// skips the birthday category entirely. Default `true` so the feature
    /// surfaces automatically once Contacts access is granted.
    var birthdayMemoriesEnabled: Bool = true {
        didSet {
            guard oldValue != birthdayMemoriesEnabled else { return }
            defaults.set(birthdayMemoriesEnabled, forKey: "birthdayMemoriesEnabled")
            // Force a regenerate so today's rail reflects the toggle change
            // immediately rather than waiting for the daily gate.
            forceRegenerateMemories()
        }
    }

    @ObservationIgnored private var isEnriching = false
    /// Re-entrancy guard for memory generation: `generateMemoriesIfNeeded`
    /// spawns an unawaited Task and the daily gate is only set on completion,
    /// so without this two triggers in quick succession would both generate.
    @ObservationIgnored private var isGeneratingMemories = false
    /// Bumped by `forceRegenerateMemories` so an in-flight generation (whose
    /// inputs predate the change that forced the regen) can't set the daily
    /// gate when it lands.
    @ObservationIgnored private var memoryGenerationEpoch = 0
    /// In-flight scan, keyed by URL + resolved kind. Concurrent callers for
    /// the same URL await the existing task instead of starting a second
    /// traversal (app launch + willEnterForeground + pull-to-refresh can
    /// otherwise overlap). The kind is kept so a `.full` request isn't
    /// silently satisfied by an in-flight light scan.
    @ObservationIgnored private var activeScanTask: (url: URL, kind: ScanKind, task: Task<Void, Never>)?
    /// Most recent scanner-emitted sidecar manifest. `SidecarSyncService`
    /// diffs it after every scan; `SidecarRefreshService` re-reads it on the
    /// BG sidecar-refresh task.
    @ObservationIgnored var lastSidecarManifest: [FolderScanner.SidecarCandidate] = []
    @ObservationIgnored private var memoriesGeneratedDay: Date? {
        didSet { persistMemoriesGeneratedDay() }
    }
    @ObservationIgnored private let bookmarks: BookmarkManager
    @ObservationIgnored private let contactLinker = ContactLinker()
    @ObservationIgnored private let searchService = SearchIndex()
    @ObservationIgnored private let tagService = TagIndex()
    @ObservationIgnored private let thumbnailService: ThumbnailService
    @ObservationIgnored private let widgetExport = WidgetExportScheduler()
    /// Materialises file-provider placeholders on demand. Exposed as a
    /// property so views can observe `inFlight` for spinner state.
    let materializer = PhotoMaterializer()
    /// Parsed `.xmp` cache keyed by photo UUID. Lets cloud libraries surface
    /// tags/country codes/face regions even when the source `.xmp` files
    /// have been evicted by the provider.
    @ObservationIgnored private let sidecarCache: SidecarCacheStore
    /// Diffs the scanner's sidecar manifest against `sidecarCache` and
    /// fetches the deltas through `NSFileCoordinator`. Observed by the
    /// top-of-grid sync banner.
    let sidecarSync: SidecarSyncService

    // MARK: Injected seams (test-overridable; production uses `.production` /
    // `.standard` defaults so existing call sites are unchanged).

    @ObservationIgnored private let paths: GalleryPaths
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
        self.paths = paths
        self.defaults = defaults
        self.clock = clock
        self.contactsService = contactsService
        self.bookmarks = BookmarkManager(defaults: defaults, bookmarkKey: paths.bookmarkKey)
        self.thumbnailService = ThumbnailService(thumbnailDir: paths.thumbnailDir)
        let sidecarCache = SidecarCacheStore(url: paths.sidecarCacheURL)
        self.sidecarCache = sidecarCache
        self.sidecarSync = SidecarSyncService(cache: sidecarCache)
        self.sidecarSync.onFinished = { @MainActor [weak self] in
            self?.reapplySidecarMerges()
        }

        if let raw = defaults.string(forKey: "folderSortOrder"),
           let order = FolderSortOrder(rawValue: raw) {
            folderSortOrder = order
        }
        if let hidden = defaults.array(forKey: "hiddenPeople") as? [String] {
            hiddenPeople = Set(hidden)
        }
        if let pinned = defaults.array(forKey: "pinnedPeople") as? [String] {
            featuredPeople = pinned
        }
        if let hiddenMem = defaults.array(forKey: "hiddenMemories") as? [String] {
            hiddenMemories = Set(hiddenMem)
        }
        if let dict = defaults.dictionary(forKey: "featuredPhotoByPerson") as? [String: String] {
            featuredPhotoByPerson = dict.compactMapValues { UUID(uuidString: $0) }
        }
        if let raw = defaults.object(forKey: "memoriesGeneratedDay") as? Date {
            memoriesGeneratedDay = raw
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
        if let data = defaults.data(forKey: "seenMemoryIDs"),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Drop entries older than the engine's scoring window so the dict
            // can't grow unbounded across years of use.
            let cutoff = Calendar.current.date(byAdding: .month, value: -12, to: clock.now()) ?? .distantPast
            seenMemoryIDs = dict.filter { $0.value > cutoff }
        }
        if let data = defaults.data(forKey: "surfacedClusters"),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Drop entries outside the cool-down window so the map can't
            // grow unbounded across years of use.
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: clock.now()) ?? .distantPast
            surfacedClusters = dict.filter { $0.value > cutoff }
        }
        if defaults.object(forKey: "birthdayMemoriesEnabled") != nil {
            birthdayMemoriesEnabled = defaults.bool(forKey: "birthdayMemoriesEnabled")
        }
        if defaults.object(forKey: "prefetchAdjacentRemotePhotos") != nil {
            prefetchAdjacentRemotePhotos = defaults.bool(forKey: "prefetchAdjacentRemotePhotos")
        }
        if defaults.object(forKey: "useCellularForDownloads") != nil {
            useCellularForDownloads = defaults.bool(forKey: "useCellularForDownloads")
        }
        if let raw = defaults.string(forKey: "mePersonPath") {
            mePersonPath = raw
        }
        loadMemoriesCache()

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
    /// from `memoriesGeneratedDay` (persisted on disk) so the very first
    /// foreground entry of a new day rebuilds the snapshot — without
    /// pessimistically forcing a regeneration on every cold launch.
    @ObservationIgnored private var lastWidgetExportDay: Date?

    private func refreshWidgetIfDayChanged() {
        let today = Calendar.current.startOfDay(for: clock.now())
        let reference = lastWidgetExportDay ?? memoriesGeneratedDay
        if let reference, Calendar.current.isDate(reference, inSameDayAs: today) {
            return
        }
        lastWidgetExportDay = today
        // Memories generation is gated to once per day; force a rebuild so
        // today's onThisDay / yearsAgo / birthday content is current.
        if !allPhotos.isEmpty {
            forceRegenerateMemories()
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

    // MARK: - Disk Cache (forwarded to LibraryCacheStore / MemoriesCacheStore)

    private func saveCache() {
        guard let root = rootFolder else { return }
        LibraryCacheStore.save(rootFolder: root, allPhotos: allPhotos, to: paths.libraryCacheURL)
    }

    private func saveMemoriesCache() {
        MemoriesCacheStore.save(memories, to: paths.memoriesCacheURL)
    }

    private func loadMemoriesCache() {
        if let cached = MemoriesCacheStore.load(from: paths.memoriesCacheURL) {
            self.memories = cached
        }
    }

    private func persistMemoriesGeneratedDay() {
        if let day = memoriesGeneratedDay {
            defaults.set(day, forKey: "memoriesGeneratedDay")
        } else {
            defaults.removeObject(forKey: "memoriesGeneratedDay")
        }
    }

    private func persistFeaturedPhotoByPerson() {
        let stringDict = featuredPhotoByPerson.mapValues { $0.uuidString }
        defaults.set(stringDict, forKey: "featuredPhotoByPerson")
    }

    private func persistPersonContactLinks() {
        // PersonLink is an enum with associated values, so it round-trips
        // through JSON rather than a flat UserDefaults dict.
        guard let data = try? JSONEncoder().encode(personContactLinks) else { return }
        defaults.set(data, forKey: "personContactLinks")
    }

    private func persistSeenMemoryIDs() {
        guard let data = try? JSONEncoder().encode(seenMemoryIDs) else { return }
        defaults.set(data, forKey: "seenMemoryIDs")
    }

    private func persistSurfacedClusters() {
        guard let data = try? JSONEncoder().encode(surfacedClusters) else { return }
        defaults.set(data, forKey: "surfacedClusters")
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
            forceRegenerateMemories()
        }
    }

    /// Manually link a person tag to a contact. Triggers a memory rebuild so
    /// the new link is reflected on the next launch (or right away if today is
    /// the contact's birthday).
    func linkPerson(_ personPath: String, toContactID contactID: String) {
        personContactLinks[personPath] = .manual(contactID: contactID)
        Log.contacts.info("Linked '\(Log.r.person(personPath))' to contact \(Log.r.contact(contactID))")
        forceRegenerateMemories()
    }

    /// Disable any contact link for a person tag. Records `.disabled` so the
    /// auto-match by name does not re-apply.
    func unlinkPerson(_ personPath: String) {
        personContactLinks[personPath] = .disabled
        Log.contacts.info("Unlinked '\(Log.r.person(personPath))' (auto-match disabled)")
        forceRegenerateMemories()
    }

    /// Forget any manual override — auto-match by name resumes for this person.
    func resetPersonLink(_ personPath: String) {
        personContactLinks.removeValue(forKey: personPath)
        Log.contacts.info("Reset link for '\(Log.r.person(personPath))' (auto-match restored)")
        forceRegenerateMemories()
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
        guard let cached = LibraryCacheStore.load(
            from: paths.libraryCacheURL,
            memoriesURL: paths.memoriesCacheURL
        ) else { return false }
        // No persist — we just read this off disk, no need to write it back.
        apply(.scanResult(photos: cached.allPhotos, root: cached.rootFolder, persistCache: false))
        return true
    }

    // MARK: - Restore on Launch

    func restoreFolder() async {
        let hadCache = rootFolder != nil

        // Refresh contacts if access is already granted. No-op (and no prompt)
        // when access hasn't been granted — birthday memories simply won't
        // appear until the user grants access from Settings.
        await loadContacts()

        // Security scope may already be active from init()
        let url: URL
        if let active = bookmarks.activeURL {
            url = active
        } else {
            guard let resolved = bookmarks.resolve() else { return }
            bookmarks.startAccessing(resolved)
            url = resolved
        }

        // Only show spinner if no cache to display
        if !hadCache {
            isScanning = true
        }

        // Rescan in background — cached URLs are from a previous session.
        // `.auto` picks light when we have fresh cache + recent full scan,
        // and full otherwise (cold install, post-upgrade, >fullScanInterval
        // since last full pass).
        await scanFolder(at: url, kind: .auto, silent: hadCache)
    }

    /// Scan trigger entry point. All call sites pass `kind` explicitly so the
    /// behaviour is deterministic and grep-able:
    ///
    ///   - **`.light`** — pull-to-refresh in any view. Never promotes; the
    ///     user pulled down to see new files, not to pay a 3-min full-rescan
    ///     bill.
    ///   - **`.auto`** — foreground observer + cold-launch `restoreFolder`.
    ///     Light by default, but promotes to full if it's been more than
    ///     `fullScanInterval` (48h) since the last full scan. This is the
    ///     deterministic backstop: every two days a full pass happens
    ///     transparently on the next foreground.
    ///   - **`.full`** — Settings "Reload Library", "Re-download all
    ///     sidecars", and the folder-picker's first scan. Explicit user
    ///     intent, always runs the slow path.
    ///
    /// The default is `.auto` so a future caller that omits `kind` still
    /// gets the safe-by-default behaviour.
    func rescan(kind: ScanKind = .auto, silent: Bool = true) async {
        guard let url = bookmarks.activeURL else { return }
        await scanFolder(at: url, kind: kind, silent: silent)
    }

    // MARK: - Folder Scanning (Iterative)

    func scanFolder(at url: URL, kind: ScanKind = .full, silent: Bool = false) async {
        let resolved = resolvedScanKind(for: kind, now: clock.now())
        if let active = activeScanTask {
            if active.url == url {
                await active.task.value
                // The spawner's cleanup races this resumption; clear the
                // finished entry ourselves so the re-run below can't loop on
                // a stale `activeScanTask`.
                if activeScanTask?.task == active.task { activeScanTask = nil }
                // A `.full` request must not be silently downgraded by an
                // in-flight light scan — "Reload Library" during a foreground
                // auto-scan would otherwise no-op. Re-run with the stronger
                // kind once the in-flight pass settles.
                if resolved == .full && active.kind != .full {
                    await scanFolder(at: url, kind: .full, silent: silent)
                }
                return
            }
            // Different root in flight (user picked a new folder mid-scan).
            // Let it settle first so two performScans never interleave their
            // apply()/saveCache() calls.
            await active.task.value
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performScan(at: url, kind: resolved, silent: silent)
        }
        activeScanTask = (url, resolved, task)
        await task.value
        if activeScanTask?.task == task { activeScanTask = nil }
    }

    /// Resolve `.auto` → `.light` or `.full` based on how long it's been
    /// since the last full scan. Exposed so tests can verify the gate.
    func resolvedScanKind(for kind: ScanKind, now: Date) -> ScanKind {
        switch kind {
        case .light, .full: return kind
        case .auto:
            guard let last = lastFullScanAt else { return .full }
            return now.timeIntervalSince(last) >= Self.fullScanInterval ? .full : .light
        }
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
    private enum PhotoLibraryMutation {
        case scanResult(photos: [PhotoFile], root: PhotoFolder?, persistCache: Bool)
        case sidecarsMerged(photos: [PhotoFile])
        case photoLocalityChanged(id: UUID, locality: PhotoLocality)
        case allDownloadsCleared
        case sidecarCacheCleared
    }

    private func apply(_ mutation: PhotoLibraryMutation) {
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

    private func performScan(at url: URL, kind: ScanKind, silent: Bool) async {
        let resolved = resolvedScanKind(for: kind, now: clock.now())

        // Spinner state is reserved for non-silent scans (Settings "Reload
        // Library", cold launch without cache). It spans both passes of a
        // two-phase scan and is cleared once, below.
        if !silent { isScanning = true }

        // Two-phase scan: when a full scan is on tap AND we already hold a
        // cache to reuse, run a quick light pass first. The light pass walks
        // the tree but reuses cached PhotoFiles for unchanged files (no
        // FileProvider probe, no EXIF re-read), so newly added / changed
        // files surface in seconds instead of waiting out the full pass's
        // ~3-min probe + enrichment over the whole library. The full pass
        // then follows for the deterministic backstop: probe/locality
        // refresh, in-place EXIF edits, and missed sidecars.
        //
        // Skipped when `allPhotos` is empty (cold launch with no cache):
        // with nothing to reuse, the light pass pays the same per-file cost
        // as the full pass, so a pre-pass would just scan everything twice
        // for no speed-up.
        if resolved == .full && !allPhotos.isEmpty {
            await runScanPass(at: url, light: true, silent: silent)
        }

        // Final pass: full when requested, light for the `.light` kind.
        let result = await runScanPass(at: url, light: resolved == .light, silent: silent)

        isScanning = false
        lastSyncedAt = clock.now()
        if resolved == .full {
            lastFullScanAt = lastSyncedAt
            defaults.set(lastFullScanAt, forKey: "lastFullScanAt")
        }

        // Post-scan work runs once, against the just-published `allPhotos`,
        // after the final pass — the light pre-pass deliberately skips all of
        // it so it stays quick.
        //
        // Hand the manifest to the sidecar sync service; it diffs against
        // the cache and either fetches silently or surfaces a prompt.
        let allIDs = Set(allPhotos.map(\.id))
        sidecarSync.plan(
            manifest: result.sidecarManifest,
            allPhotoIDs: allIDs,
            autoApprove: false
        )

        // Memory generation runs against the just-published `allPhotos`.
        generateMemoriesIfNeeded()

        // Scan + enrichment have settled — clear progress so the banner
        // dismisses.
        self.scanProgress = nil

        // Refresh the widget snapshot after the scan/enrichment pass settles.
        exportWidgetSnapshot()
    }

    /// One scan pass: walk `url`, enrich new/changed files, and publish the
    /// result to `allPhotos` / `rootFolder`. Returns the scanner result so the
    /// caller can drive the once-per-scan post-processing (sidecar plan,
    /// memory generation, widget export) after the final pass of a two-phase
    /// scan. Owns `scanProgress` for its scanning/enriching phases but leaves
    /// `isScanning` / `lastFullScanAt` / final progress teardown to
    /// `performScan`, which spans both passes.
    @discardableResult
    private func runScanPass(at url: URL, light: Bool, silent: Bool) async -> FolderScanner.Result {
        let startedAt = clock.now()
        self.scanProgress = ScanProgress(phase: .scanning, processed: 0, total: nil, startedAt: startedAt)

        let cachedPhotos = Dictionary(
            allPhotos.map { ($0.url, $0) },
            uniquingKeysWith: { _, b in b }
        )
        // Pass last scan's sidecar manifest in too so the light-scan fast
        // path can skip the `.xmp` `FileProviderDetector.probe()` for
        // unchanged photos — that probe dominates light-scan wall time on
        // digiKam libraries (one 7-key resourceValues syscall per sidecar).
        let cachedSidecarManifest = Dictionary(
            self.lastSidecarManifest.map { ($0.photoID, $0) },
            uniquingKeysWith: { _, b in b }
        )

        // Heavy file I/O runs off the main actor so cached UI stays responsive.
        // Scanner progress hops back to the main actor to publish into
        // `scanProgress`; throttled to once per ~100 files inside the scanner.
        let progressCallback: @Sendable (Int) -> Void = { [weak self] processed in
            Task { @MainActor [weak self] in
                guard let self, let current = self.scanProgress, current.phase == .scanning else { return }
                self.scanProgress = ScanProgress(
                    phase: .scanning,
                    processed: processed,
                    total: nil,
                    startedAt: current.startedAt
                )
            }
        }
        let result = await FolderScanner.scan(
            at: url,
            cachedPhotos: cachedPhotos,
            cachedSidecarManifest: cachedSidecarManifest,
            reuseCached: light,
            onProgress: progressCallback
        )

        self.lastSidecarManifest = result.sidecarManifest
        let remoteCount = result.flatPhotos.filter {
            if case .remote = $0.locality { return true } else { return false }
        }.count
        if remoteCount > 0 {
            Log.scan.info("Detected \(remoteCount) file-provider photos, \(result.sidecarManifest.count) sidecar candidates")
        }

        // Carry forward cached photos under directories whose listing failed
        // (transient provider error, brief unmount) — the scanner couldn't
        // see them this pass, and dropping them would wipe their tags and
        // enrichment over a one-off I/O error. They stay in the flat grid
        // (not the folder tree) until a scan can list their parent again.
        var scannedPhotos = result.flatPhotos
        if !result.failedDirectoryPaths.isEmpty {
            let scannedURLs = Set(scannedPhotos.map(\.url))
            let preserved = allPhotos.filter { photo in
                guard !scannedURLs.contains(photo.url) else { return false }
                let path = photo.url.standardizedFileURL.path
                return result.failedDirectoryPaths.contains { path.hasPrefix($0 + "/") }
            }
            if !preserved.isEmpty {
                Log.scan.warning("Preserving \(preserved.count) cached photos under \(result.failedDirectoryPaths.count) unreadable directories")
                scannedPhotos += preserved
            }
        }

        // Merge cached sidecar entries onto the freshly-scanned photos.
        let mergedPhotos = mergeCachedSidecars(into: scannedPhotos)

        // Run enrichment on the scan output BEFORE publishing anything to
        // the observed grid state. The displayed grid keeps showing the
        // cached photos throughout the scan + enrichment window, so
        // ThumbnailViews (keyed on the unchanged URLs) stay on their
        // cached thumbnails instead of being torn down and re-loaded
        // mid-sync. One `allPhotos` assignment below covers both phases.
        let finalPhotos: [PhotoFile]
        if result.needsEnrichment && !mergedPhotos.isEmpty {
            finalPhotos = await enrichPhotos(mergedPhotos)
        } else {
            finalPhotos = mergedPhotos
        }

        // Patch the folder tree to carry the enriched photo values, so the
        // Folders tab sees the same dates/tags as the flat grid.
        let finalRoot: PhotoFolder?
        if let root = result.rootFolder {
            let photosByURL = Dictionary(finalPhotos.map { ($0.url, $0) }, uniquingKeysWith: { _, b in b })
            finalRoot = Self.updateFolderPhotos(root, photosByURL: photosByURL)
        } else {
            finalRoot = nil
        }

        // Atomic swap — single assignment for both rootFolder and allPhotos,
        // single rebuildSortAndIndex, single saveCache. Views observing
        // sortedPhotos / allPhotos see one update at the end of the pass
        // instead of one after the scan + one after enrichment.
        let existingURLs = Set(allPhotos.map(\.url))
        let newURLs = Set(finalPhotos.map(\.url))
        let contentChanged = existingURLs != newURLs || result.needsEnrichment

        let scanKindLabel = light ? "light" : "full"
        if contentChanged && (!finalPhotos.isEmpty || !silent) {
            Log.scan.info("\(scanKindLabel) scan complete: \(finalPhotos.count) photos (+\(result.addedURLs.count) -\(result.removedURLs.count) ~\(result.modifiedURLs.count), needsEnrichment=\(result.needsEnrichment))")
            apply(.scanResult(photos: finalPhotos, root: finalRoot, persistCache: true))
        } else if finalPhotos.isEmpty && !silent {
            // Explicit user-driven scan that found nothing — surface the empty
            // state but don't overwrite the on-disk cache; a transient folder
            // access failure shouldn't blow away a good cache.
            Log.scan.info("\(scanKindLabel) scan complete: 0 photos")
            apply(.scanResult(photos: [], root: finalRoot, persistCache: false))
        } else {
            Log.scan.info("\(scanKindLabel) scan complete, no changes (\(finalPhotos.count) photos)")
        }

        return result
    }

    /// Read EXIF dates and hierarchical tags for the stale entries in
    /// `photos`. Pure transform: returns the enriched array without
    /// mutating `allPhotos`. The caller (`performScan`) publishes the
    /// result as part of its atomic swap.
    private func enrichPhotos(_ photos: [PhotoFile]) async -> [PhotoFile] {
        guard !isEnriching else { return photos }
        isEnriching = true
        defer { isEnriching = false }

        let staleCount = photos.filter { $0.enrichedFileDate == nil }.count
        Log.enrich.info("Starting metadata enrichment: \(staleCount) new/changed of \(photos.count) total")

        if staleCount == 0 {
            Log.enrich.info("All photos up-to-date, skipping")
            return photos
        }

        // Flip the progress banner to the enriching phase. Total is known
        // up-front (the stale-file count), so the UI can render a percent
        // and ETA.
        let enrichStart = clock.now()
        self.scanProgress = ScanProgress(
            phase: .enriching,
            processed: 0,
            total: staleCount,
            startedAt: enrichStart
        )

        let enrichedPhotos = await EnrichmentService.enrich(photos: photos) { [weak self] processed, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let current = self.scanProgress, current.phase == .enriching else { return }
                self.scanProgress = ScanProgress(
                    phase: .enriching,
                    processed: processed,
                    total: total,
                    startedAt: current.startedAt
                )
            }
        }

        let enrichedCount = zip(photos, enrichedPhotos).filter { old, new in
            old.dateTaken != new.dateTaken ||
            old.hierarchicalTags != new.hierarchicalTags ||
            old.countryCode != new.countryCode ||
            old.gpsLatitude != new.gpsLatitude
        }.count
        Log.enrich.info("Enrichment changed \(enrichedCount) photos")
        return enrichedPhotos
    }

    /// Re-apply `mergeCachedSidecars` to the live `allPhotos`. Called after
    /// the sidecar sync service finishes a fetch run so newly-cached entries
    /// surface tags/country codes without a manual rescan.
    func reapplySidecarMerges() {
        let merged = mergeCachedSidecars(into: allPhotos)
        guard merged != allPhotos else { return }
        apply(.sidecarsMerged(photos: merged))
        Log.cache.info("Re-applied sidecar merges to live photos")
    }

    /// Merge any `SidecarCacheStore` entry into a photo's runtime fields, so
    /// search/tags/country/face-regions surface for cloud photos before the
    /// next sync completes. Cached fields lose to existing in-memory values
    /// only when the photo already has them — fresh-from-disk metadata
    /// (EXIF + sidecar in `MetadataReader.readImageMetadata`) wins on the
    /// enrichment pass that runs after this.
    private func mergeCachedSidecars(into photos: [PhotoFile]) -> [PhotoFile] {
        var photos = photos
        for i in photos.indices {
            guard let cached = sidecarCache.get(photos[i].id) else { continue }
            if photos[i].hierarchicalTags.isEmpty {
                photos[i].hierarchicalTags = cached.hierarchicalTags
            }
            if photos[i].countryCode == nil {
                photos[i].countryCode = cached.countryCode
            }
            if photos[i].faceRegions.isEmpty {
                photos[i].faceRegions = cached.faceRegions
            }
            if photos[i].gpsLatitude == nil, let lat = cached.gpsLatitude {
                photos[i].gpsLatitude = lat
            }
            if photos[i].gpsLongitude == nil, let lon = cached.gpsLongitude {
                photos[i].gpsLongitude = lon
            }
            if photos[i].dateTaken == nil, let date = cached.dateTaken {
                photos[i].dateTaken = date
            }
            photos[i].sidecarStatus = .cached(cached.version)
        }
        return photos
    }

    /// Recursively update photos inside folder tree with enriched metadata
    nonisolated static func updateFolderPhotos(_ folder: PhotoFolder, photosByURL: [URL: PhotoFile]) -> PhotoFolder {
        var f = folder
        f.photos = f.photos.map { photosByURL[$0.url] ?? $0 }
        f.subfolders = f.subfolders.map { updateFolderPhotos($0, photosByURL: photosByURL) }
        return f
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
        let nowSnapshot = clock.now()
        Task.detached(priority: .utility) {
            let (tags, people) = TagIndex.aggregateTagsAndPeople(
                photosForTag: tagPhotosSnapshot,
                canonicalPath: canonicalPathSnapshot,
                now: nowSnapshot
            )

            await MainActor.run { [weak self] in
                guard let self, self.tagBuildGeneration == generation else { return }
                self.allTags = tags
                self.topPeople = people
                Log.index.info("Tags: \(tags.count) unique, \(people.count) people")
                // Tag aggregation populates the widget Tags picker — re-export
                // so the catalog reflects the latest set.
                self.exportWidgetSnapshot()
            }
        }
    }

    /// Background-task entry point. Refreshes contacts (in case the user added
    /// or edited birthdays since the app last ran) and runs the once-a-day
    /// memory regeneration if the foreground app hasn't already done so today.
    /// We can't reuse `generateMemoriesIfNeeded` directly because it spawns an
    /// unawaited Task — and we need to await completion so iOS knows when to
    /// mark the BG task as finished.
    func runScheduledMemoryRefresh() async {
        await loadContacts()
        // We don't rescan the photo library in background — folder bookmarks
        // require an active security scope which the system may not honor for
        // a BGAppRefreshTask. Birthday detection only needs `allPhotos` (already
        // in memory from the last foreground scan) plus `contacts`.
        guard !allPhotos.isEmpty else {
            Log.bg.info("No photos in memory; skipping background memory generation")
            return
        }
        // Honor the same once-per-day gate the foreground path uses, AND set
        // the gate after running so the next foreground entry doesn't re-do
        // the same work. Without this we'd regenerate twice per day on any
        // session where BG ran first.
        let today = Calendar.current.startOfDay(for: clock.now())
        let alreadyToday = memoriesGeneratedDay.map { Calendar.current.isDate($0, inSameDayAs: today) } ?? false
        if alreadyToday {
            Log.bg.info("Memories already generated today; skipping BG regeneration")
            return
        }
        guard !isGeneratingMemories else { return }
        isGeneratingMemories = true
        defer { isGeneratingMemories = false }
        let epoch = memoryGenerationEpoch
        let snapshot = allPhotos
        let leaves = _cachedLeafFolders
        let daySeed = WidgetDayKey.string(for: today)
        await generateMemories(from: snapshot, leafFolders: leaves, seed: daySeed)
        // Gate only on completion: if the BG task expired and cancelled us
        // mid-generation, the day must stay unconsumed so the next foreground
        // entry retries instead of keeping yesterday's memories all day.
        if !Task.isCancelled && epoch == memoryGenerationEpoch {
            memoriesGeneratedDay = today
        }
    }

    /// Clear the once-per-day gate + cached memories and immediately re-run detection.
    /// Wired to a long-press on the "Memories" section header in CollectionsView.
    /// Uses a time-based seed so each tap gives a fresh selection.
    ///
    /// No-op when no photos are loaded yet. This is the load-time invariant
    /// that lets the persisted-setting didSet observers (`hiddenPeople`,
    /// `mePersonPath`, `birthdayMemoriesEnabled`) call this unconditionally
    /// instead of guarding on an `_isInitializing` flag — there's nothing to
    /// regenerate before the library cache loads, and the first scan's
    /// own `generateMemoriesIfNeeded` will populate memories from scratch.
    func forceRegenerateMemories() {
        guard !allPhotos.isEmpty else { return }
        memoryGenerationEpoch += 1
        memoriesGeneratedDay = nil
        memories = []
        MemoriesCacheStore.clear(at: paths.memoriesCacheURL)
        Log.memory.info("Force-regenerating memories")
        generateMemoriesIfNeeded(seed: "\(clock.now().timeIntervalSinceReferenceDate)")
    }

    /// Trigger memory generation once per day. Called after scan (if no enrichment needed)
    /// or after enrichment completes, so memories always reflect the freshest EXIF/tag/GPS data.
    internal func generateMemoriesIfNeeded(seed: String? = nil) {
        let cal = Calendar.current
        let now = clock.now()
        let today = cal.startOfDay(for: now)
        let memoriesStale = memoriesGeneratedDay.map { !cal.isDate($0, inSameDayAs: today) } ?? true
        let memoriesEmpty = memories.isEmpty
        guard (memoriesStale || memoriesEmpty), !allPhotos.isEmpty else { return }
        guard !isGeneratingMemories else { return }
        isGeneratingMemories = true
        let epoch = memoryGenerationEpoch
        let snapshot = allPhotos
        let leaves = _cachedLeafFolders
        let daySeed = seed ?? WidgetDayKey.string(for: today)
        Task {
            defer { isGeneratingMemories = false }
            await generateMemories(from: snapshot, leafFolders: leaves, seed: daySeed)
            // Gate only on completion — a process death or cancellation
            // mid-generation must not consume the daily gate; an epoch bump
            // means a force-regen superseded this run's inputs.
            if !Task.isCancelled && epoch == memoryGenerationEpoch {
                memoriesGeneratedDay = today
            }
        }
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

    // MARK: - Collections Helpers

    var peopleTags: [TagSuggestion] {
        allTags.filter { $0.namespace?.lowercased() == "people" }
    }

    /// All people with hidden filtered out and featured floated to the front
    /// (preserves feature order). Used by PeopleListView — no cap, no recency
    /// gate so the full roster is always reachable.
    var visiblePeople: [TagSuggestion] {
        let visible = topPeople.filter { !hiddenPeople.contains($0.fullPath) }
        let featuredSet = Set(featuredPeople)
        let featuredFirst = featuredPeople.compactMap { path in visible.first { $0.fullPath == path } }
        let rest = visible.filter { !featuredSet.contains($0.fullPath) }
        return featuredFirst + rest
    }

    /// Top 20 people for the Collections rail. Non-featured must have at least
    /// one photo dated within the past 2 years; featured bypass the recency
    /// gate (the user explicitly promoted them). Sorted by total photo count.
    var visiblePeopleForRail: [TagSuggestion] {
        let now = clock.now()
        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: now) ?? now
        let featuredSet = Set(featuredPeople)
        let visible = topPeople.filter { !hiddenPeople.contains($0.fullPath) }
        let featuredInOrder = featuredPeople.compactMap { path in visible.first { $0.fullPath == path } }
        let nonFeatured = visible
            .filter { !featuredSet.contains($0.fullPath) }
            .filter { ($0.latestPhotoDate ?? .distantPast) > twoYearsAgo }
        return Array((featuredInOrder + nonFeatured).prefix(20))
    }

    var visibleMemories: [Memory] {
        memories.filter { memory in
            guard !hiddenMemories.contains(memory.id) else { return false }
            // Suppress birthday memories for people who have since been hidden
            // (catches stale cached memories generated before the person was hidden).
            if memory.id.hasPrefix("birthday-") {
                let personPath = String(memory.id.dropFirst("birthday-".count))
                if hiddenPeople.contains(personPath) { return false }
            }
            // Hide memories whose photo IDs are entirely stale (e.g. folder
            // moved since the memory was generated, changing SHA-256 UUIDs).
            // Mirror the same resolution order as MemoryCardView's coverURL.
            if searchService.photo(byID: memory.coverPhotoID) != nil { return true }
            return memory.photoIDs.contains { searchService.photo(byID: $0) != nil }
        }
    }

    var hiddenPeopleTags: [TagSuggestion] {
        hiddenPeople.compactMap { path in allTags.first { $0.fullPath == path } }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func hidePerson(_ path: String) {
        hiddenPeople.insert(path)
        featuredPeople.removeAll { $0 == path }
        exportWidgetSnapshot()
    }

    func unhidePerson(_ path: String) {
        hiddenPeople.remove(path)
        exportWidgetSnapshot()
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

    /// The photo chosen as the card image for a person. When the user hasn't
    /// pinned a specific photo, prefer photos where this person is the only
    /// one tagged (cleaner cover, no other faces to crop around), then sort
    /// by recency. Face-area-based ranking turned out to be unreliable when
    /// multiple regions exist and the matching region for *this person*
    /// can't be uniquely identified by name — solo-photo preference is a
    /// simpler proxy for "good portrait of this person".
    func featuredPhoto(for tag: TagSuggestion) -> PhotoFile? {
        if let id = featuredPhotoByPerson[tag.fullPath], let photo = searchService.photo(byID: id) {
            return photo
        }
        let candidates = photos(forTag: tag)
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

    func setFeaturedPhoto(personPath: String, photoID: UUID) {
        featuredPhotoByPerson[personPath] = photoID
    }

    func hideMemory(_ id: String) {
        hiddenMemories.insert(id)
        exportWidgetSnapshot()
    }
    func markMemorySeen(_ id: String) { seenMemoryIDs[id] = clock.now() }
    func unhideMemory(_ id: String) {
        hiddenMemories.remove(id)
        exportWidgetSnapshot()
    }

    // MARK: - Widget Snapshot

    /// Build a widget snapshot from current state and hand it to the exporter.
    /// Cheap to call: the exporter de-duplicates work and only re-encodes
    /// thumbnails whose source files changed.
    ///
    /// We pass `visibleMemories` verbatim so the widget rail mirrors the
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
            memories: visibleMemories,
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
    /// launch. Excludes day 0 — that's already in `visibleMemories`.
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
            if birthdayMemoriesEnabled {
                // Birthdays walk all photos by People/* tag rather than by
                // date bucket, so we pass `photos` directly.
                MemoryEngine.generateBirthdayMemories(
                    from: photos,
                    contacts: contacts,
                    links: personContactLinks,
                    lowerNameIndex: contactLinker.contactsByLowerName,
                    calendar: cal,
                    todayComponents: dayComps,
                    hiddenPeople: hiddenPeople,
                    into: &dayMemories
                )
            }

            // Same finalize step as `generate` (photo cap + subtitle) so a
            // pre-published scheduled item looks identical to the memory the
            // foreground catch-up regenerates on its day.
            for memory in MemoryEngine.finalize(dayMemories) where !hiddenMemories.contains(memory.id) {
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

    /// True once today's memory generation has completed. `AppRouter` uses
    /// this to decide whether a widget deep link targeting a not-yet-existing
    /// scheduled memory should stay queued (today's generation still pending)
    /// or be dropped (the memory is genuinely gone).
    var hasGeneratedMemoriesToday: Bool {
        guard let day = memoriesGeneratedDay else { return false }
        return Calendar.current.isDate(day, inSameDayAs: clock.now())
    }

    /// Resolve photo IDs from a memory back to PhotoFile instances.
    func photos(for memory: Memory) -> [PhotoFile] {
        memory.photoIDs.compactMap { searchService.photo(byID: $0) }
    }

    private func generateMemories(from allPhotos: [PhotoFile], leafFolders: [PhotoFolder], seed: String = "") async {
        let t = CFAbsoluteTimeGetCurrent()

        // Drop file-provider placeholders that don't have a cached sidecar
        // yet — their tags/GPS/date are unknown, so they'd inflate the pool
        // with garbage candidates. Local photos and remote-with-cached-
        // sidecar photos pass through.
        let filtered = allPhotos.filter { photo in
            switch photo.locality {
            case .local: return true
            case .remote(let downloaded):
                if downloaded { return true }
                if case .cached = photo.sidecarStatus { return true }
                return false
            }
        }
        if filtered.count != allPhotos.count {
            Log.memory.info("Memory pool: \(filtered.count) of \(allPhotos.count) photos (excluded \(allPhotos.count - filtered.count) cloud placeholders without sidecars)")
        }

        MemoryEngine.logMemoryInputSummary(allPhotos: filtered)

        // Snapshot main-actor state before the engine's detached task runs.
        let results = await MemoryEngine.generate(
            from: filtered,
            leafFolders: leafFolders,
            contacts: self.contacts,
            personContactLinks: self.personContactLinks,
            contactsByLowerName: self.contactLinker.contactsByLowerName,
            birthdaysEnabled: self.birthdayMemoriesEnabled,
            mePersonPath: self.mePersonPath,
            hiddenPeople: self.hiddenPeople,
            now: self.clock.now(),
            seed: seed,
            seenMemoryIDs: self.seenMemoryIDs,
            surfacedClusters: self.surfacedClusters
        )

        // An expired BG task cancels mid-generation — don't publish a
        // potentially partial result set over a good cached one.
        guard !Task.isCancelled else {
            Log.memory.info("Memory generation cancelled; discarding results")
            return
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - t) * 1000
        self.memories = results
        // Record the clusters we just surfaced so the next generation
        // applies the cool-down penalty to their members.
        let now = self.clock.now()
        var updated = self.surfacedClusters
        for memory in results {
            updated[MemoryEngine.clusterKey(for: memory.id)] = now
        }
        self.surfacedClusters = updated
        saveMemoriesCache()
        Log.memory.info("Generated \(results.count) memories in \(String(format: "%.0f", elapsed))ms")

        // Memories changed → refresh the widget snapshot so the Memories widget
        // picks up new "On this day" / "Years ago" content the same day they
        // become valid.
        exportWidgetSnapshot()
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

    struct CloudStorageStats: Sendable, Equatable {
        let materializedCount: Int
        let materializedBytes: Int64
        let placeholderCount: Int
        let totalRemote: Int
    }

    /// True when at least one folder backs onto a file provider. Drives the
    /// "Cloud Storage" section in Settings — purely-local libraries don't
    /// see any of this UI.
    var hasFileProviderPhotos: Bool {
        allPhotos.contains { photo in
            if case .remote = photo.locality { return true } else { return false }
        }
    }

    /// Walk the remote photos and bucket them by download status. One
    /// `resourceValues` probe per remote photo, so the walk runs off the
    /// main actor (`nonisolated async`) — a multi-thousand-photo cloud
    /// library would otherwise hitch the Settings sheet open animation.
    /// No downloads are triggered; the Settings sheet caches the result so
    /// repeat opens don't re-walk.
    func computeCloudStorageStats() async -> CloudStorageStats {
        let remote = allPhotos.filter {
            if case .remote = $0.locality { return true } else { return false }
        }
        return await Self.probeStorageStats(remote)
    }

    private nonisolated static func probeStorageStats(_ remotePhotos: [PhotoFile]) async -> CloudStorageStats {
        var materializedCount = 0
        var materializedBytes: Int64 = 0
        var placeholderCount = 0
        for photo in remotePhotos {
            let probe = FileProviderDetector.probe(photo.url)
            if probe.status == .local {
                materializedCount += 1
                materializedBytes += probe.version.size ?? photo.fileSize
            } else {
                placeholderCount += 1
            }
        }
        return CloudStorageStats(
            materializedCount: materializedCount,
            materializedBytes: materializedBytes,
            placeholderCount: placeholderCount,
            totalRemote: remotePhotos.count
        )
    }

    /// Ask the file-provider stack to evict every materialised provider-backed
    /// photo. Eviction is per-domain via `NSFileProviderManager.evictItem`;
    /// providers that don't support eviction silently no-op. Grid stays
    /// usable because thumbnails + sidecar cache are untouched; only
    /// full-resolution viewing requires a re-download.
    func clearAllDownloads() async -> Int {
        var evicted = 0
        let downloaded = allPhotos.filter {
            if case .remote(let d) = $0.locality { return d } else { return false }
        }
        for photo in downloaded {
            do {
                let pair: (NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier)? =
                    try await withCheckedThrowingContinuation { cont in
                        NSFileProviderManager.getIdentifierForUserVisibleFile(at: photo.url) { id, domainID, err in
                            if let err { cont.resume(throwing: err) }
                            else if let id, let domainID { cont.resume(returning: (id, domainID)) }
                            else { cont.resume(returning: nil) }
                        }
                    }
                guard let (itemID, domainID) = pair else { continue }
                // Resolve the domain inside the completion block so the
                // non-Sendable `NSFileProviderDomain` value never crosses
                // an actor hop. We either return a `Bool` (evict success)
                // or rethrow the underlying error.
                let didEvict: Bool = try await withCheckedThrowingContinuation { cont in
                    NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                        guard let domain = domains.first(where: { $0.identifier == domainID }),
                              let manager = NSFileProviderManager(for: domain) else {
                            cont.resume(returning: false)
                            return
                        }
                        manager.evictItem(identifier: itemID) { error in
                            if let error { cont.resume(throwing: error) }
                            else { cont.resume(returning: true) }
                        }
                    }
                }
                if didEvict { evicted += 1 }
            } catch {
                Log.scan.warning("evictItem failed for \(Log.r.filename(photo.url.lastPathComponent)): \(Log.r.error(error))")
            }
        }
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

