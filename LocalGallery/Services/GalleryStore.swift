import Foundation
import UIKit
import Contacts
import Observation
import os

@Observable
@MainActor
final class GalleryStore {
    var rootFolder: PhotoFolder?
    var allPhotos: [PhotoFile] = []
    var isScanning: Bool = false
    var lastSyncedAt: Date?
    private(set) var memories: [Memory] = []
    private(set) var topPeople: [TagSuggestion] = []
    private(set) var eventFolders: [PhotoFolder] = []

    var folderSortOrder: FolderSortOrder = .nameAscending {
        didSet { defaults.set(folderSortOrder.rawValue, forKey: "folderSortOrder") }
    }

    var hiddenPeople: Set<String> = [] {
        didSet { defaults.set(Array(hiddenPeople), forKey: "hiddenPeople") }
    }
    /// Person tag paths that are "featured" — sorted to the front of the People rail
    /// and decorated with a star. Stored under the legacy `pinnedPeople` key.
    var featuredPeople: [String] = [] {
        didSet { defaults.set(featuredPeople, forKey: "pinnedPeople") }
    }
    var hiddenMemories: Set<String> = [] {
        didSet { defaults.set(Array(hiddenMemories), forKey: "hiddenMemories") }
    }
    /// Per-person featured photo ID. Keyed by person tag fullPath (case-sensitive).
    var featuredPhotoByPerson: [String: UUID] = [:] {
        didSet { persistFeaturedPhotoByPerson() }
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

    /// Master toggle for birthday memories. When `false`, `generateMemories`
    /// skips the birthday category entirely. Default `true` so the feature
    /// surfaces automatically once Contacts access is granted.
    var birthdayMemoriesEnabled: Bool = true {
        didSet {
            guard oldValue != birthdayMemoriesEnabled, !_isInitializing else { return }
            defaults.set(birthdayMemoriesEnabled, forKey: "birthdayMemoriesEnabled")
            // Force a regenerate so today's rail reflects the toggle change
            // immediately rather than waiting for the daily gate.
            forceRegenerateMemories()
        }
    }
    /// Set to `false` at the end of `init()` so didSet observers can skip
    /// expensive side-effects (like cache clears) while restoring persisted
    /// state.
    @ObservationIgnored private var _isInitializing = true

    @ObservationIgnored private var isEnriching = false
    /// In-flight scan, keyed by URL. Concurrent callers for the same URL await
    /// the existing task instead of starting a second traversal (app launch +
    /// willEnterForeground + pull-to-refresh can otherwise overlap).
    @ObservationIgnored private var activeScanTask: (url: URL, task: Task<Void, Never>)?
    @ObservationIgnored private var memoriesGeneratedDay: Date? {
        didSet { persistMemoriesGeneratedDay() }
    }
    @ObservationIgnored private let bookmarks: BookmarkManager
    @ObservationIgnored private let contactLinker = ContactLinker()
    @ObservationIgnored private let searchService = SearchIndex()
    @ObservationIgnored private let tagService = TagIndex()
    @ObservationIgnored private let thumbnailService: ThumbnailService
    @ObservationIgnored private let widgetExport = WidgetExportScheduler()

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
        if let data = defaults.data(forKey: "personContactLinks"),
           let dict = try? JSONDecoder().decode([String: PersonLink].self, from: data) {
            personContactLinks = dict
        }
        if defaults.object(forKey: "birthdayMemoriesEnabled") != nil {
            birthdayMemoriesEnabled = defaults.bool(forKey: "birthdayMemoriesEnabled")
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
                    await self.scanFolder(at: url, silent: true)
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

        _isInitializing = false
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
        Log.contacts.info("Linked '\(personPath, privacy: .public)' to contact \(contactID, privacy: .public)")
        forceRegenerateMemories()
    }

    /// Disable any contact link for a person tag. Records `.disabled` so the
    /// auto-match by name does not re-apply.
    func unlinkPerson(_ personPath: String) {
        personContactLinks[personPath] = .disabled
        Log.contacts.info("Unlinked '\(personPath, privacy: .public)' (auto-match disabled)")
        forceRegenerateMemories()
    }

    /// Forget any manual override — auto-match by name resumes for this person.
    func resetPersonLink(_ personPath: String) {
        personContactLinks.removeValue(forKey: personPath)
        Log.contacts.info("Reset link for '\(personPath, privacy: .public)' (auto-match restored)")
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
        self.rootFolder = cached.rootFolder
        self.allPhotos = cached.allPhotos
        rebuildSortAndIndex()
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

        // Rescan in background — cached URLs are from a previous session
        await scanFolder(at: url, silent: hadCache)
    }

    func rescan(silent: Bool = true) async {
        guard let url = bookmarks.activeURL else { return }
        await scanFolder(at: url, silent: silent)
    }

    // MARK: - Folder Scanning (Iterative)

    func scanFolder(at url: URL, silent: Bool = false) async {
        if let active = activeScanTask, active.url == url {
            await active.task.value
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performScan(at: url, silent: silent)
        }
        activeScanTask = (url, task)
        await task.value
        if activeScanTask?.task == task { activeScanTask = nil }
    }

    private func performScan(at url: URL, silent: Bool) async {
        if !silent { isScanning = true }

        // Snapshot cached metadata so the scanner can merge it into the
        // fresh scan without re-reading EXIF for unchanged files.
        let cachedMetadata = Dictionary(
            allPhotos.map { photo in
                (photo.url, FolderScanner.CachedPhotoMetadata(
                    date: photo.dateTaken,
                    tags: photo.hierarchicalTags,
                    countryCode: photo.countryCode,
                    enrichedFileDate: photo.enrichedFileDate,
                    gpsLatitude: photo.gpsLatitude,
                    gpsLongitude: photo.gpsLongitude
                ))
            },
            uniquingKeysWith: { _, b in b }
        )

        // Heavy file I/O runs off the main actor so cached UI stays responsive.
        let result = await FolderScanner.scan(at: url, cachedMetadata: cachedMetadata)

        // Back on main actor — update observed state only if content changed.
        let existingURLs = Set(allPhotos.map(\.url))
        let newURLs = Set(result.flatPhotos.map(\.url))
        let contentChanged = existingURLs != newURLs || result.needsEnrichment

        if contentChanged && (!result.flatPhotos.isEmpty || !silent) {
            Log.scan.info("Complete: \(result.flatPhotos.count) photos (needsEnrichment=\(result.needsEnrichment), changed=true)")
            self.rootFolder = result.rootFolder
            self.allPhotos = result.flatPhotos
            rebuildSortAndIndex()
            saveCache()
        } else if result.flatPhotos.isEmpty && !silent {
            Log.scan.info("Complete: 0 photos")
            self.rootFolder = result.rootFolder
            self.allPhotos = []
            rebuildSortAndIndex()
        } else {
            Log.scan.info("Scan complete, no changes detected (\(result.flatPhotos.count) photos)")
        }
        isScanning = false
        lastSyncedAt = Date()

        // Enrich with EXIF dates and tags in background (only if needed).
        // Memory generation is deferred until after enrichment so memories reflect the
        // freshest EXIF dates / tags / GPS data.
        if result.needsEnrichment && !allPhotos.isEmpty {
            await enrichMetadata()
            generateMemoriesIfNeeded()
        } else {
            generateMemoriesIfNeeded()
        }

        // Refresh the widget snapshot after the scan/enrichment pass settles.
        exportWidgetSnapshot()
    }

    /// Read EXIF dates and hierarchical tags for all photos in the background.
    /// Updates allPhotos in a single assignment so dates/tags are live immediately.
    private func enrichMetadata() async {
        guard !isEnriching else { return }
        isEnriching = true
        defer { isEnriching = false }

        let photos = allPhotos
        let staleCount = photos.filter { $0.enrichedFileDate == nil }.count
        Log.enrich.info("Starting metadata enrichment: \(staleCount) new/changed of \(photos.count) total")

        if staleCount == 0 {
            Log.enrich.info("All photos up-to-date, skipping")
            return
        }

        let enrichedPhotos = await EnrichmentService.enrich(photos: photos)

        // Only apply if allPhotos hasn't been replaced during enrichment
        guard allPhotos.count == photos.count,
              allPhotos.first?.url == photos.first?.url else {
            Log.enrich.warning("Skipped — allPhotos changed during enrichment")
            return
        }

        // Check if enrichment actually changed any values
        let enrichedCount = zip(photos, enrichedPhotos).filter { old, new in
            old.dateTaken != new.dateTaken ||
            old.hierarchicalTags != new.hierarchicalTags ||
            old.countryCode != new.countryCode ||
            old.gpsLatitude != new.gpsLatitude
        }.count

        guard enrichedCount > 0 else {
            Log.enrich.info("No metadata changes after enrichment, skipping update")
            return
        }

        Log.enrich.info("Enrichment changed \(enrichedCount) photos, publishing update")
        // Single assignment fires one Observation update per dependent view.
        self.allPhotos = enrichedPhotos
        rebuildSortAndIndex()

        // Also update folder tree and save cache
        if let root = rootFolder {
            let photosByURL = Dictionary(enrichedPhotos.map { ($0.url, $0) }, uniquingKeysWith: { _, b in b })
            self.rootFolder = Self.updateFolderPhotos(root, photosByURL: photosByURL)
        }
        saveCache()
        Log.enrich.info("Applied enriched metadata to live data")
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
        memoriesGeneratedDay = today
        let snapshot = allPhotos
        let leaves = _cachedLeafFolders
        await generateMemories(from: snapshot, leafFolders: leaves)
    }

    /// Clear the once-per-day gate + cached memories and immediately re-run detection.
    /// Wired to a long-press on the "Memories" section header in CollectionsView.
    func forceRegenerateMemories() {
        memoriesGeneratedDay = nil
        memories = []
        MemoriesCacheStore.clear()
        Log.memory.info("Force-regenerating memories")
        generateMemoriesIfNeeded()
    }

    /// Trigger memory generation once per day. Called after scan (if no enrichment needed)
    /// or after enrichment completes, so memories always reflect the freshest EXIF/tag/GPS data.
    internal func generateMemoriesIfNeeded() {
        let today = Calendar.current.startOfDay(for: clock.now())
        let memoriesStale = memoriesGeneratedDay.map { !Calendar.current.isDate($0, inSameDayAs: today) } ?? true
        let memoriesEmpty = memories.isEmpty
        guard (memoriesStale || memoriesEmpty), !allPhotos.isEmpty else { return }
        memoriesGeneratedDay = today
        let snapshot = allPhotos
        let leaves = _cachedLeafFolders
        Task { await generateMemories(from: snapshot, leafFolders: leaves) }
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
    /// (preserves feature order).
    var visiblePeople: [TagSuggestion] {
        let visible = topPeople.filter { !hiddenPeople.contains($0.fullPath) }
        let featuredSet = Set(featuredPeople)
        let featuredFirst = featuredPeople.compactMap { path in visible.first { $0.fullPath == path } }
        let rest = visible.filter { !featuredSet.contains($0.fullPath) }
        return featuredFirst + rest
    }

    var visibleMemories: [Memory] {
        memories.filter { memory in
            guard !hiddenMemories.contains(memory.id) else { return false }
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
    }

    func unhidePerson(_ path: String) {
        hiddenPeople.remove(path)
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

    /// The photo chosen as the card image for a person, or the most recent tagged
    /// photo if none was explicitly set.
    func featuredPhoto(for tag: TagSuggestion) -> PhotoFile? {
        if let id = featuredPhotoByPerson[tag.fullPath], let photo = searchService.photo(byID: id) {
            return photo
        }
        return photos(forTag: tag).first
    }

    func setFeaturedPhoto(personPath: String, photoID: UUID) {
        featuredPhotoByPerson[personPath] = photoID
    }

    func hideMemory(_ id: String) { hiddenMemories.insert(id) }
    func unhideMemory(_ id: String) { hiddenMemories.remove(id) }

    // MARK: - Widget Snapshot

    /// Build a widget snapshot from current state and hand it to the exporter.
    /// Cheap to call: the exporter de-duplicates work and only re-encodes
    /// thumbnails whose source files changed.
    ///
    /// Birthday resolution happens here on the main actor — we walk every
    /// People/* tag through `effectiveContact(forPersonPath:displayName:)` so
    /// both manual links and the auto-match-by-name fallback are honored,
    /// keeping `Contacts.framework` out of the exporter.
    func exportWidgetSnapshot() {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day], from: clock.now())
        var birthdays: [WidgetSnapshotExporter.BirthdayResolution] = []
        if birthdayMemoriesEnabled {
            for tag in allTags where tag.namespace?.lowercased() == "people" {
                guard let contact = effectiveContact(forPersonPath: tag.fullPath, displayName: tag.displayName),
                      let birthday = contact.birthday,
                      birthday.month == today.month, birthday.day == today.day else { continue }
                let displayName = contact.fullName == "(No name)" ? tag.displayName : contact.fullName
                birthdays.append(WidgetSnapshotExporter.BirthdayResolution(
                    tagFullPath: tag.fullPath,
                    displayName: displayName
                ))
            }
        }
        widgetExport.schedule(WidgetSnapshotExporter.Inputs(
            allPhotos: allPhotos,
            memories: memories,
            allTags: allTags,
            rootFolder: rootFolder,
            leafFolders: _cachedLeafFolders,
            todayBirthdays: birthdays
        ))
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

    private func generateMemories(from allPhotos: [PhotoFile], leafFolders: [PhotoFolder]) async {
        let t = CFAbsoluteTimeGetCurrent()

        MemoryEngine.logMemoryInputSummary(allPhotos: allPhotos)

        // Snapshot main-actor state before the engine's detached task runs.
        let results = await MemoryEngine.generate(
            from: allPhotos,
            leafFolders: leafFolders,
            contacts: self.contacts,
            personContactLinks: self.personContactLinks,
            contactsByLowerName: self.contactLinker.contactsByLowerName,
            birthdaysEnabled: self.birthdayMemoriesEnabled,
            now: self.clock.now()
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - t) * 1000
        self.memories = results
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

    func thumbnail(for url: URL, size: CGSize, isVideo: Bool = false) async -> UIImage? {
        await thumbnailService.thumbnail(for: url, size: size, isVideo: isVideo)
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
}
