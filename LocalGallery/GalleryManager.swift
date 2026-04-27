import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import Contacts
import Observation
import os

@Observable
@MainActor
final class GalleryManager {
    var rootFolder: PhotoFolder?
    var allPhotos: [PhotoFile] = []
    var isScanning: Bool = false
    var lastSyncedAt: Date?
    private(set) var memories: [Memory] = []
    private(set) var topPeople: [TagSuggestion] = []
    private(set) var eventFolders: [PhotoFolder] = []

    var folderSortOrder: FolderSortOrder = .nameAscending {
        didSet { UserDefaults.standard.set(folderSortOrder.rawValue, forKey: "folderSortOrder") }
    }

    var hiddenPeople: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(hiddenPeople), forKey: "hiddenPeople") }
    }
    /// Person tag paths that are "featured" — sorted to the front of the People rail
    /// and decorated with a star. Stored under the legacy `pinnedPeople` key.
    var featuredPeople: [String] = [] {
        didSet { UserDefaults.standard.set(featuredPeople, forKey: "pinnedPeople") }
    }
    var hiddenMemories: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(hiddenMemories), forKey: "hiddenMemories") }
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
            UserDefaults.standard.set(birthdayMemoriesEnabled, forKey: "birthdayMemoriesEnabled")
            // Force a regenerate so today's rail reflects the toggle change
            // immediately rather than waiting for the daily gate.
            forceRegenerateMemories()
        }
    }
    /// Set to `false` at the end of `init()` so didSet observers can skip
    /// expensive side-effects (like cache clears) while restoring persisted
    /// state.
    private var _isInitializing = true

    private var isEnriching = false
    /// In-flight scan, keyed by URL. Concurrent callers for the same URL await
    /// the existing task instead of starting a second traversal (app launch +
    /// willEnterForeground + pull-to-refresh can otherwise overlap).
    private var activeScanTask: (url: URL, task: Task<Void, Never>)?
    private var memoriesGeneratedDay: Date? {
        didSet { persistMemoriesGeneratedDay() }
    }
    private let thumbnailCache = NSCache<NSURL, UIImage>()
    private let fullImageCache = NSCache<NSURL, UIImage>()
    private let bookmarks = BookmarkManager()
    private let contactLinker = ContactLinker()
    /// NotificationCenter observer tokens. Set once in `init()` (on main),
    /// read once in `deinit` (on whatever thread released the last reference).
    /// `@ObservationIgnored` so the `@Observable` macro doesn't synthesize
    /// `_foregroundObserver` etc. for these (they aren't view state).
    /// `nonisolated(unsafe)` lets the implicit-nonisolated deinit access them;
    /// `Any?` isn't `Sendable`, hence the `(unsafe)`.
    @ObservationIgnored private nonisolated(unsafe) var foregroundObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var significantTimeChangeObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var contactStoreObserver: Any?

    private let thumbnailDiskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache.json")
    }

    private var memoriesCacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memories_cache.json")
    }

    init() {
        thumbnailCache.totalCostLimit = 100 * 1024 * 1024
        fullImageCache.totalCostLimit = 200 * 1024 * 1024

        if let raw = UserDefaults.standard.string(forKey: "folderSortOrder"),
           let order = FolderSortOrder(rawValue: raw) {
            folderSortOrder = order
        }
        if let hidden = UserDefaults.standard.array(forKey: "hiddenPeople") as? [String] {
            hiddenPeople = Set(hidden)
        }
        if let pinned = UserDefaults.standard.array(forKey: "pinnedPeople") as? [String] {
            featuredPeople = pinned
        }
        if let hiddenMem = UserDefaults.standard.array(forKey: "hiddenMemories") as? [String] {
            hiddenMemories = Set(hiddenMem)
        }
        if let dict = UserDefaults.standard.dictionary(forKey: "featuredPhotoByPerson") as? [String: String] {
            featuredPhotoByPerson = dict.compactMapValues { UUID(uuidString: $0) }
        }
        if let raw = UserDefaults.standard.object(forKey: "memoriesGeneratedDay") as? Date {
            memoriesGeneratedDay = raw
        }
        if let data = UserDefaults.standard.data(forKey: "personContactLinks"),
           let dict = try? JSONDecoder().decode([String: PersonLink].self, from: data) {
            personContactLinks = dict
        }
        if UserDefaults.standard.object(forKey: "birthdayMemoriesEnabled") != nil {
            birthdayMemoriesEnabled = UserDefaults.standard.bool(forKey: "birthdayMemoriesEnabled")
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
    private var lastWidgetExportDay: Date?

    private func refreshWidgetIfDayChanged() {
        let today = Calendar.current.startOfDay(for: Date())
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

    // MARK: - Disk Cache

    // v13: force rescan so video dates read AVAsset.creationDate (videos used to
    // skip enrichment and fall back to the filesystem date, which often equals
    // the download time on this device).
    private static let cacheVersion = 15

    private struct LibraryCache: Codable, Sendable {
        let version: Int
        let rootFolder: PhotoFolder
        let allPhotos: [PhotoFile]
    }

    private struct ScanFolderNode {
        let url: URL
        let name: String
        var photos: [PhotoFile]
        var childIndices: [Int]
        let parentIndex: Int?
        let dateModified: Date?
        let dateCreated: Date?
    }

    private struct ScanFile {
        let url: URL; let fileSize: Int64; let modDate: Date?; let creationDate: Date?; let isImage: Bool; let isVideo: Bool
    }

    private struct EnrichedResult: Sendable {
        let index: Int
        let dateTaken: Date?
        let dateFromMetadata: Bool
        let hierarchicalTags: [HierarchicalTag]
        let countryCode: String?
        let gpsLatitude: Double?
        let gpsLongitude: Double?
        let enrichedFileDate: Date?
    }

    private func saveCache() {
        guard let root = rootFolder else { return }
        let cache = LibraryCache(version: Self.cacheVersion, rootFolder: root, allPhotos: allPhotos)
        let url = cacheURL
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.cache.error("Failed to save cache: \(error.localizedDescription)")
            }
        }
    }

    private func saveMemoriesCache() {
        let url = memoriesCacheURL
        let snapshot = memories
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.cache.error("Failed to save memories cache: \(error.localizedDescription)")
            }
        }
    }

    private func loadMemoriesCache() {
        guard FileManager.default.fileExists(atPath: memoriesCacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: memoriesCacheURL)
            let cached = try JSONDecoder().decode([Memory].self, from: data)
            self.memories = cached
            Log.cache.info("Loaded \(cached.count) memories from cache")
        } catch {
            Log.cache.warning("Failed to load memories cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: memoriesCacheURL)
        }
    }

    private func persistMemoriesGeneratedDay() {
        if let day = memoriesGeneratedDay {
            UserDefaults.standard.set(day, forKey: "memoriesGeneratedDay")
        } else {
            UserDefaults.standard.removeObject(forKey: "memoriesGeneratedDay")
        }
    }

    private func persistFeaturedPhotoByPerson() {
        let stringDict = featuredPhotoByPerson.mapValues { $0.uuidString }
        UserDefaults.standard.set(stringDict, forKey: "featuredPhotoByPerson")
    }

    private func persistPersonContactLinks() {
        // PersonLink is an enum with associated values, so it round-trips
        // through JSON rather than a flat UserDefaults dict.
        guard let data = try? JSONEncoder().encode(personContactLinks) else { return }
        UserDefaults.standard.set(data, forKey: "personContactLinks")
    }

    // MARK: - Contacts

    /// Prompt for Contacts access and load on grant. Safe to call repeatedly.
    @discardableResult
    func requestContactsAccess() async -> Bool {
        let granted = await ContactsService.requestAccess()
        if granted { await loadContacts() }
        return granted
    }

    /// Load contacts if access is already granted. No-op when denied.
    /// When the address-book contents that affect birthday memories actually
    /// change (new contact, edited birthday, renamed person), force a memory
    /// rebuild so the change surfaces without waiting for the daily gate.
    func loadContacts() async {
        let previous = contacts
        let loaded = await ContactsService.loadContacts()
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
    /// Forwards to `ContactLinker` which owns the indexes; the manager
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
    private func loadCache() -> Bool {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return false }
        do {
            let data = try Data(contentsOf: cacheURL)
            let cache = try JSONDecoder().decode(LibraryCache.self, from: data)
            guard cache.version == Self.cacheVersion else {
                Log.cache.warning("Version mismatch (\(cache.version) vs \(Self.cacheVersion)), discarding")
                try? FileManager.default.removeItem(at: cacheURL)
                return false
            }
            self.rootFolder = cache.rootFolder
            self.allPhotos = cache.allPhotos
            Log.cache.info("Loaded \(cache.allPhotos.count) photos from cache v\(cache.version)")
            rebuildSortAndIndex()
            return true
        } catch {
            Log.cache.error("Failed to load cache: \(error.localizedDescription)")
            return false
        }
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

    func rescan() async {
        guard let url = bookmarks.activeURL else { return }
        await scanFolder(at: url, silent: true)
    }

    // MARK: - Metadata Reading

    private typealias MetadataResult = (date: Date?, hierarchicalTags: [HierarchicalTag], countryCode: String?, gpsLatitude: Double?, gpsLongitude: Double?)

    /// Read capture date, hierarchical tags, and country code from image metadata
    /// (EXIF/XMP) + XMP sidecar. Tag source is `digiKam:TagsList`; country code is
    /// `photo-tools:CountryCode` (see photo-tools xmp-schema.md §1).
    private nonisolated static func readImageMetadata(url: URL) -> MetadataResult {
        var captureDate: Date? = nil
        var rawTags: [String] = []
        var countryCode: String? = nil
        var gpsLat: Double? = nil
        var gpsLon: Double? = nil

        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {

            // EXIF date: DateTimeOriginal → DateTimeDigitized → TIFF DateTime
            let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

            let dateStrings = [
                exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String,
                exifDict?[kCGImagePropertyExifDateTimeDigitized] as? String,
                tiffDict?[kCGImagePropertyTIFFDateTime] as? String,
            ]
            for dateString in dateStrings {
                if let s = dateString, let d = dateFormatter.date(from: s) {
                    captureDate = d
                    break
                }
            }

            // XMP: digiKam:TagsList (hierarchical paths) + photo-tools:CountryCode
            if let xmpMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                let tags = CGImageMetadataCopyTags(xmpMetadata) as? [CGImageMetadataTag] ?? []
                for tag in tags {
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                    let value = CGImageMetadataTagCopyValue(tag)
                    if name == "TagsList", let value {
                        rawTags.append(contentsOf: xmpStringArray(value))
                    } else if name == "CountryCode", countryCode == nil,
                              let str = value as? String, !str.isEmpty {
                        countryCode = str.uppercased()
                    }
                }
            }

            // GPS coordinates
            if let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gpsDict[kCGImagePropertyGPSLatitude] as? Double,
               let lon = gpsDict[kCGImagePropertyGPSLongitude] as? Double {
                let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef] as? String
                let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String
                gpsLat = latRef == "S" ? -lat : lat
                gpsLon = lonRef == "W" ? -lon : lon
            }
        }

        // XMP sidecar file (.xmp) — same fields as embedded
        let sidecar = readXMPSidecar(for: url)
        rawTags.append(contentsOf: sidecar.rawTags)
        if countryCode == nil { countryCode = sidecar.countryCode }

        // Deduplicate hierarchical tags by path (case-insensitive).
        var seenPaths = Set<String>()
        let hierarchicalTags = rawTags.compactMap { raw -> HierarchicalTag? in
            let key = raw.lowercased()
            guard !seenPaths.contains(key) else { return nil }
            seenPaths.insert(key)
            return HierarchicalTag(raw: raw)
        }

        return (captureDate, hierarchicalTags, countryCode, gpsLat, gpsLon)
    }

    /// Pick the earlier of creation/modification dates. Handles AirDrop and
    /// chat-saved files where the original modDate is preserved but creationDate
    /// reflects the download time on this volume.
    nonisolated static func earliestFilesystemDate(creation: Date?, modification: Date?) -> Date? {
        switch (creation, modification) {
        case let (c?, m?): return min(c, m)
        case let (c?, nil): return c
        case let (nil, m?): return m
        case (nil, nil): return nil
        }
    }

    /// Coerce a `CGImageMetadataTag` value into `[String]`.
    ///
    /// rdf:Bag / rdf:Seq values come back as `CFArray` of `CGImageMetadataTag`
    /// (one per `<rdf:li>`), not `CFArray` of `CFString` — so `as? [String]`
    /// silently yields `nil` and we'd lose every embedded hierarchical tag.
    /// Recurse on each child via `CGImageMetadataTagCopyValue`.
    private nonisolated static func xmpStringArray(_ value: CFTypeRef) -> [String] {
        let tagTypeID = CGImageMetadataTagGetTypeID()
        if CFGetTypeID(value) == tagTypeID {
            let tag = value as! CGImageMetadataTag
            if let nested = CGImageMetadataTagCopyValue(tag) {
                return xmpStringArray(nested)
            }
            return []
        }
        if CFGetTypeID(value) == CFArrayGetTypeID() {
            let array = value as! CFArray
            let count = CFArrayGetCount(array)
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
                let item = unsafeBitCast(raw, to: CFTypeRef.self)
                out.append(contentsOf: xmpStringArray(item))
            }
            return out
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return []
    }

    /// Parse XMP sidecar file (.xmp) for digiKam:TagsList + photo-tools:CountryCode.
    private nonisolated static func readXMPSidecar(for imageURL: URL) -> (rawTags: [String], countryCode: String?) {
        let xmpURL = imageURL.appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: xmpURL.path),
              let data = try? Data(contentsOf: xmpURL),
              let xml = String(data: data, encoding: .utf8) else { return ([], nil) }

        var rawTags: [String] = []

        // Hierarchical tags from digiKam:TagsList.
        if let startRange = xml.range(of: "<digiKam:TagsList>") ?? xml.range(of: "<digiKam:TagsList "),
           let endRange = xml.range(of: "</digiKam:TagsList>", range: startRange.upperBound..<xml.endIndex) {
            let block = String(xml[startRange.upperBound..<endRange.lowerBound])
            var searchRange = block.startIndex..<block.endIndex
            while let liStart = block.range(of: "<rdf:li>", range: searchRange) {
                guard let liEnd = block.range(of: "</rdf:li>", range: liStart.upperBound..<block.endIndex) else { break }
                let value = String(block[liStart.upperBound..<liEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { rawTags.append(value) }
                searchRange = liEnd.upperBound..<block.endIndex
            }
        }

        // photo-tools:CountryCode — a simple scalar, optional prefix may vary.
        var countryCode: String? = nil
        for prefix in ["photo-tools:CountryCode", "phototools:CountryCode"] {
            if let startRange = xml.range(of: "<\(prefix)>"),
               let endRange = xml.range(of: "</\(prefix)>", range: startRange.upperBound..<xml.endIndex) {
                let value = String(xml[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { countryCode = value.uppercased(); break }
            }
        }

        return (rawTags, countryCode)
    }

    /// Read capture date from video metadata
    private nonisolated static func readVideoDate(url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let creationDate = try? await asset.load(.creationDate),
              let dateValue = try? await creationDate.load(.dateValue) else {
            return nil
        }
        return dateValue
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

        // Snapshot cached metadata so we can merge it into the fresh scan
        let cachedMetadata = Dictionary(allPhotos.map { ($0.url, (date: $0.dateTaken, tags: $0.hierarchicalTags, countryCode: $0.countryCode, enrichedFileDate: $0.enrichedFileDate, gpsLat: $0.gpsLatitude, gpsLon: $0.gpsLongitude)) },
                                         uniquingKeysWith: { _, b in b })

        // Heavy file I/O runs off the main actor so cached UI stays responsive
        let result: (root: PhotoFolder?, flatPhotos: [PhotoFile], needsEnrichment: Bool) = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var flatPhotos: [PhotoFile] = []
            var needsEnrichment = false

            var nodes: [ScanFolderNode] = []
            var stack: [(URL, Int?)] = [(url, nil)]

            while !stack.isEmpty {
                let (dirURL, parentIdx) = stack.removeLast()
                let dirName = dirURL.lastPathComponent

                var photos: [PhotoFile] = []
                var subdirs: [URL] = []

                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey]

                if let contents = try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    // First pass: classify files and collect metadata
                    var scannedFiles: [ScanFile] = []

                    for itemURL in contents {
                        let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys))
                        let isDir = resourceValues?.isDirectory ?? false

                        if isDir {
                            subdirs.append(itemURL)
                        } else {
                            let ext = itemURL.pathExtension.lowercased()
                            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                                let isImage = utType.conforms(to: .image)
                                let isVideo = utType.conforms(to: .movie)
                                if isImage || isVideo {
                                    scannedFiles.append(ScanFile(
                                        url: itemURL,
                                        fileSize: Int64(resourceValues?.fileSize ?? 0),
                                        modDate: resourceValues?.contentModificationDate,
                                        creationDate: resourceValues?.creationDate,
                                        isImage: isImage, isVideo: isVideo
                                    ))
                                }
                            }
                        }
                    }

                    // Second pass: pair live photos (image + video with same stem)
                    // Handle double-extension patterns like IMG_1234.heic.mov or IMG_1234.jpg.mov
                    let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "dng", "webp"]
                    let videoStem: (URL) -> String = { url in
                        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
                        let ext = (stem as NSString).pathExtension.lowercased()
                        if imageExtensions.contains(ext) {
                            stem = (stem as NSString).deletingPathExtension
                        }
                        return stem
                    }

                    let videoByName = Dictionary(
                        scannedFiles.filter(\.isVideo).map {
                            (videoStem($0.url), $0.url)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let imageStemSet = Set(
                        scannedFiles.filter(\.isImage).map {
                            $0.url.deletingPathExtension().lastPathComponent.lowercased()
                        }
                    )

                    var pairedCount = 0
                    for file in scannedFiles where file.isImage {
                        let stem = file.url.deletingPathExtension().lastPathComponent
                        let liveURL = videoByName[stem.lowercased()]
                        if liveURL != nil { pairedCount += 1 }

                        // Merge cached EXIF metadata if available
                        let cached = cachedMetadata[file.url]
                        // Prefer cached EXIF date; fall back to earliest filesystem date.
                        // creationDate = when the file appeared on THIS volume (e.g. download time);
                        // modDate = sometimes preserved from the original file (AirDrop, chat saves).
                        // min() picks the one closer to the actual photo date.
                        let dateTaken = cached?.date ?? GalleryManager.earliestFilesystemDate(creation: file.creationDate, modification: file.modDate)
                        let tags = cached?.tags ?? []
                        let cachedEnrichedDate = cached?.enrichedFileDate
                        // Re-enrich if never enriched or file was modified since last enrichment
                        let stale = cachedEnrichedDate == nil || file.modDate != cachedEnrichedDate
                        if stale {
                            needsEnrichment = true
                        }

                        photos.append(PhotoFile(
                            id: PhotoFile.stableID(for: file.url), url: file.url, filename: stem,
                            fileSize: file.fileSize,
                            dateTaken: dateTaken,
                            livePhotoVideoURL: liveURL,
                            hierarchicalTags: tags,
                            countryCode: cached?.countryCode,
                            enrichedFileDate: stale ? nil : cachedEnrichedDate,
                            gpsLatitude: cached?.gpsLat,
                            gpsLongitude: cached?.gpsLon
                        ))
                    }
                    // Standalone videos only (no matching image)
                    var standaloneVideoCount = 0
                    for file in scannedFiles where file.isVideo {
                        let stem = videoStem(file.url)
                        if !imageStemSet.contains(stem) {
                            standaloneVideoCount += 1
                            let cached = cachedMetadata[file.url]
                            photos.append(PhotoFile(
                                id: PhotoFile.stableID(for: file.url), url: file.url, filename: stem,
                                fileSize: file.fileSize,
                                dateTaken: cached?.date ?? GalleryManager.earliestFilesystemDate(creation: file.creationDate, modification: file.modDate),
                                isVideo: true
                            ))
                        }
                    }

                    let imageCount = scannedFiles.filter(\.isImage).count
                    let videoCount = scannedFiles.filter(\.isVideo).count
                    if videoCount > 0 {
                        Log.scan.debug("\(dirName): \(imageCount) images, \(videoCount) videos → \(pairedCount) live pairs, \(standaloneVideoCount) standalone videos")
                        if pairedCount == 0 && videoCount > 0 {
                            let sampleImageStems = Array(imageStemSet.prefix(3))
                            let sampleVideoStems = Array(videoByName.keys.prefix(3))
                            Log.scan.debug("  Image stems: \(sampleImageStems)")
                            Log.scan.debug("  Video stems: \(sampleVideoStems)")
                        }
                    }
                }

                let dirKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
                let dirValues = try? dirURL.resourceValues(forKeys: dirKeys)

                let nodeIndex = nodes.count
                nodes.append(ScanFolderNode(
                    url: dirURL,
                    name: dirName,
                    photos: photos,
                    childIndices: [],
                    parentIndex: parentIdx,
                    dateModified: dirValues?.contentModificationDate,
                    dateCreated: dirValues?.creationDate
                ))

                if let parentIdx = parentIdx {
                    nodes[parentIdx].childIndices.append(nodeIndex)
                }

                flatPhotos.append(contentsOf: photos)

                let sortedSubdirs = subdirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                for subdir in sortedSubdirs {
                    stack.append((subdir, nodeIndex))
                }
            }

            func buildFolder(from nodeIndex: Int) -> PhotoFolder {
                let node = nodes[nodeIndex]
                let subfolders = node.childIndices.map { buildFolder(from: $0) }

                let recursiveCount = node.photos.count + subfolders.reduce(0) { $0 + $1.totalPhotoCount }

                var coverURL: URL? = node.photos.first?.url
                if coverURL == nil {
                    for sf in subfolders {
                        if let c = sf.coverPhotoURL {
                            coverURL = c
                            break
                        }
                    }
                }

                return PhotoFolder(
                    id: PhotoFolder.stableID(for: node.url),
                    url: node.url,
                    name: node.name,
                    subfolders: subfolders,
                    photos: node.photos,
                    coverPhotoURL: coverURL,
                    totalPhotoCount: recursiveCount,
                    dateModified: node.dateModified,
                    dateCreated: node.dateCreated
                )
            }

            let root = nodes.isEmpty ? nil : buildFolder(from: 0)
            return (root, flatPhotos, needsEnrichment)
        }.value

        // Back on main actor — update published properties only if content changed
        let existingURLs = Set(allPhotos.map(\.url))
        let newURLs = Set(result.flatPhotos.map(\.url))
        let contentChanged = existingURLs != newURLs || result.needsEnrichment

        if contentChanged && (!result.flatPhotos.isEmpty || !silent) {
            Log.scan.info("Complete: \(result.flatPhotos.count) photos (needsEnrichment=\(result.needsEnrichment), changed=true)")
            self.rootFolder = result.root
            self.allPhotos = result.flatPhotos
            rebuildSortAndIndex()
            saveCache()
        } else if result.flatPhotos.isEmpty && !silent {
            Log.scan.info("Complete: 0 photos")
            self.rootFolder = result.root
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
        let startTime = CFAbsoluteTimeGetCurrent()
        Log.enrich.info("Starting metadata enrichment: \(staleCount) new/changed of \(photos.count) total")

        if staleCount == 0 {
            Log.enrich.info("All photos up-to-date, skipping")
            return
        }

        let enrichedPhotos: [PhotoFile] = await Task.detached(priority: .background) {
            var result = photos
            let staleIndices = result.indices.filter { result[$0].enrichedFileDate == nil }

            // Enrich stale photos in parallel using TaskGroup. Read each
            // `photo` from `result` *outside* the addTask closure so the
            // closure captures only `let` values — Swift 6's sending check
            // won't let us cross the task boundary while a mutable var is
            // still in scope above. `FileManager.default` is referenced
            // inline inside the closure for the same reason.
            let batchResults: [EnrichedResult] = await withTaskGroup(of: EnrichedResult?.self) { group in
                for idx in staleIndices {
                    let photo = result[idx]
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let modDate = (try? FileManager.default.attributesOfItem(atPath: photo.url.path)[.modificationDate]) as? Date

                        if photo.isVideo {
                            // Videos: use AVAsset.creationDate (embedded capture date)
                            // in preference to filesystem dates, which often reflect
                            // the download/AirDrop time rather than when the video
                            // was actually recorded.
                            var dateTaken = photo.dateTaken
                            var dateFromMetadata = false
                            if let avDate = await GalleryManager.readVideoDate(url: photo.url) {
                                dateTaken = avDate
                                dateFromMetadata = true
                            } else if dateTaken == nil {
                                let attrs = try? photo.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                                dateTaken = GalleryManager.earliestFilesystemDate(
                                    creation: attrs?.creationDate,
                                    modification: attrs?.contentModificationDate
                                )
                            }
                            return EnrichedResult(
                                index: idx,
                                dateTaken: dateTaken,
                                dateFromMetadata: dateFromMetadata,
                                hierarchicalTags: photo.hierarchicalTags,
                                countryCode: photo.countryCode,
                                gpsLatitude: photo.gpsLatitude,
                                gpsLongitude: photo.gpsLongitude,
                                enrichedFileDate: modDate ?? Date()
                            )
                        }

                        let metadata = GalleryManager.readImageMetadata(url: photo.url)

                        var dateTaken = photo.dateTaken
                        var dateFromMetadata = false
                        if let date = metadata.date {
                            dateTaken = date
                            dateFromMetadata = true
                        } else if dateTaken == nil {
                            let attrs = try? photo.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                            dateTaken = GalleryManager.earliestFilesystemDate(
                                creation: attrs?.creationDate,
                                modification: attrs?.contentModificationDate
                            )
                        }

                        return EnrichedResult(
                            index: idx,
                            dateTaken: dateTaken,
                            dateFromMetadata: dateFromMetadata,
                            hierarchicalTags: metadata.hierarchicalTags.isEmpty ? photo.hierarchicalTags : metadata.hierarchicalTags,
                            countryCode: metadata.countryCode ?? photo.countryCode,
                            gpsLatitude: metadata.gpsLatitude ?? photo.gpsLatitude,
                            gpsLongitude: metadata.gpsLongitude ?? photo.gpsLongitude,
                            enrichedFileDate: modDate ?? Date()
                        )
                    }
                }
                var collected: [EnrichedResult] = []
                for await item in group {
                    if let item { collected.append(item) }
                    if collected.count % 5000 == 0 {
                        Log.enrich.info("Processed \(collected.count)/\(staleIndices.count)…")
                    }
                }
                return collected
            }

            var dateCount = 0
            var tagCount = 0
            var uniquePaths = Set<String>()
            for enriched in batchResults {
                result[enriched.index].dateTaken = enriched.dateTaken
                result[enriched.index].dateFromMetadata = enriched.dateFromMetadata
                result[enriched.index].hierarchicalTags = enriched.hierarchicalTags
                result[enriched.index].countryCode = enriched.countryCode
                result[enriched.index].gpsLatitude = enriched.gpsLatitude
                result[enriched.index].gpsLongitude = enriched.gpsLongitude
                result[enriched.index].enrichedFileDate = enriched.enrichedFileDate
                if enriched.dateTaken != nil { dateCount += 1 }
                if !enriched.hierarchicalTags.isEmpty {
                    tagCount += 1
                    for tag in enriched.hierarchicalTags { uniquePaths.insert(tag.fullPath.lowercased()) }
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            Log.enrich.info("Done in \(String(format: "%.1f", elapsed))s: \(dateCount) EXIF dates, \(tagCount) photos with tags, \(uniquePaths.count) unique tag paths")
            let sampleTags = result.flatMap(\.hierarchicalTags).prefix(20)
            if !sampleTags.isEmpty {
                let tagDetails = sampleTags.map { "\($0.fullPath) → ns:\($0.namespace ?? "nil") name:\($0.displayName)" }
                Log.enrich.debug("Sample hierarchical tags:\n  \(tagDetails.joined(separator: "\n  "))")
            }
            return result
        }.value

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

    /// Pre-sorted array, rebuilt when allPhotos changes
    private var _sortedPhotos: [PhotoFile] = []
    /// Lowercase search corpus per photo ID for fast substring matching
    private var searchIndex: [UUID: String] = [:]
    /// All unique tags across the library, sorted by frequency
    private(set) var allTags: [TagSuggestion] = []
    /// Generation counter to cancel stale tag aggregation tasks
    private var tagBuildGeneration = 0
    /// Tag -> photos index for fast collection lookups
    private var _photosForTag: [String: [PhotoFile]] = [:]
    /// Photo ID -> PhotoFile lookup
    private var _photoByID: [UUID: PhotoFile] = [:]
    /// Cached leaf folders (no subfolders, has photos)
    private var _cachedLeafFolders: [PhotoFolder] = []

    var sortedPhotos: [PhotoFile] { _sortedPhotos }

    /// O(1) photo lookup by ID
    func photo(byID id: UUID) -> PhotoFile? { _photoByID[id] }

    /// O(1) photos for a given tag
    func photos(forTag tag: TagSuggestion) -> [PhotoFile] {
        _photosForTag[tag.fullPath.lowercased()] ?? []
    }

    func sortPhotos(_ photos: [PhotoFile]) -> [PhotoFile] {
        photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
    }

    private func rebuildSortAndIndex() {
        let t = CFAbsoluteTimeGetCurrent()
        _sortedPhotos = sortPhotos(allPhotos)
        _photoByID = Dictionary(allPhotos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let withTags = allPhotos.filter { !$0.hierarchicalTags.isEmpty }.count
        let withDates = allPhotos.filter { $0.dateTaken != nil }.count

        // Build search index and tag-to-photos index in one pass.
        // Corpus = filename + every tag leaf + every tag full path, so substring
        // search matches both "rome" and "italy/lazio/rome".
        //
        // For Places/* we ALSO index every parent prefix as a virtual tag — a
        // photo tagged Places/Argentina/.../Montserrat counts toward Argentina,
        // the region, and the city. Lets the suggestion list surface "Argentina"
        // (with the country icon) when the user types it, and the resulting
        // tag-filter pulls up every photo nested under that prefix.
        var newSearchIndex: [UUID: String] = [:]
        var tagPhotos: [String: [PhotoFile]] = [:]
        // Canonical-cased path keyed by lowercased path, so virtual prefix tags
        // get nicely-cased displayName/fullPath even when no leaf photo carries
        // that exact intermediate path.
        var canonicalPath: [String: String] = [:]
        for photo in allPhotos {
            var terms: [String] = [photo.filename]
            for tag in photo.hierarchicalTags {
                terms.append(tag.displayName)
                terms.append(tag.fullPath)
            }
            newSearchIndex[photo.id] = terms.joined(separator: "\n").lowercased()
            // Track which keys we've already credited this photo to so we
            // don't double-count when a photo carries both a leaf tag and an
            // explicit parent tag (e.g. Places/Italy AND Places/Italy/Lazio/Rome).
            var keysCreditedForPhoto = Set<String>()
            for tag in photo.hierarchicalTags {
                let segments = tag.fullPath.split(separator: "/").map(String.init)
                let isPlaces = tag.namespace?.lowercased() == "places"
                let isHierarchical = segments.count > 1
                let leafKey = tag.fullPath.lowercased()
                if keysCreditedForPhoto.insert(leafKey).inserted {
                    tagPhotos[leafKey, default: []].append(photo)
                }
                canonicalPath[leafKey] = tag.fullPath
                // For Places/* (and any other multi-level path), also index every
                // proper prefix so parent levels become first-class tags.
                if isPlaces && isHierarchical {
                    for depth in 2..<segments.count {
                        let prefixSegments = Array(segments.prefix(depth))
                        let prefixPath = prefixSegments.joined(separator: "/")
                        let key = prefixPath.lowercased()
                        if keysCreditedForPhoto.insert(key).inserted {
                            tagPhotos[key, default: []].append(photo)
                        }
                        if canonicalPath[key] == nil {
                            canonicalPath[key] = prefixPath
                        }
                    }
                }
            }
        }
        searchIndex = newSearchIndex
        _photosForTag = tagPhotos

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
        let tagPhotosSnapshot = tagPhotos
        let canonicalPathSnapshot = canonicalPath
        Task.detached(priority: .utility) {
            // Build a TagSuggestion for every key in tagPhotos — including the
            // virtual Places/* prefixes that no photo carries exactly. We can
            // construct a HierarchicalTag from the canonical path for each key.
            let tags: [TagSuggestion] = tagPhotosSnapshot.compactMap { entry -> TagSuggestion? in
                guard let path = canonicalPathSnapshot[entry.key] else { return nil }
                let tag = HierarchicalTag(raw: path)
                return TagSuggestion(
                    id: tag.fullPath.lowercased(),
                    displayName: tag.displayName,
                    fullPath: tag.fullPath,
                    namespace: tag.namespace,
                    count: entry.value.count
                )
            }
            .sorted { $0.count > $1.count }

            // Sort people by recent-activity then count. Show all people, not just 8 —
            // pinning / featuring happens downstream in visiblePeople.
            let peopleTags = tags.filter { $0.namespace?.lowercased() == "people" }
            let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            let scoredPeople: [(tag: TagSuggestion, hasRecent: Bool)] = peopleTags.map { person in
                let photos = tagPhotosSnapshot[person.fullPath.lowercased()] ?? []
                let hasRecent = photos.contains { ($0.dateTaken ?? .distantPast) > oneYearAgo }
                return (person, hasRecent)
            }
            let computedPeople = scoredPeople
                .sorted { a, b in
                    if a.hasRecent != b.hasRecent { return a.hasRecent }
                    return a.tag.count > b.tag.count
                }
                .map(\.tag)

            await MainActor.run { [weak self] in
                guard let self, self.tagBuildGeneration == generation else { return }
                self.allTags = tags
                self.topPeople = computedPeople
                Log.index.info("Tags: \(tags.count) unique, \(computedPeople.count) people")
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
        let today = Calendar.current.startOfDay(for: Date())
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
        try? FileManager.default.removeItem(at: memoriesCacheURL)
        Log.memory.info("Force-regenerating memories")
        generateMemoriesIfNeeded()
    }

    /// Trigger memory generation once per day. Called after scan (if no enrichment needed)
    /// or after enrichment completes, so memories always reflect the freshest EXIF/tag/GPS data.
    private func generateMemoriesIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
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
        var results = _sortedPhotos

        // Apply AND filter for each required tag. Places/* matches as a path
        // prefix so filtering by "Places/Argentina" surfaces every photo nested
        // under Argentina, not just ones tagged exactly at country level.
        for tag in requiredTags {
            let tagPath = tag.fullPath.lowercased()
            let isPlaces = tag.namespace?.lowercased() == "places"
            results = results.filter { photo in
                photo.hierarchicalTags.contains { ht in
                    let hp = ht.fullPath.lowercased()
                    if hp == tagPath { return true }
                    if isPlaces, hp.hasPrefix(tagPath + "/") { return true }
                    return false
                }
            }
        }

        guard !query.isEmpty else {
            if !requiredTags.isEmpty {
                Log.search.debug("tags:\(requiredTags.map(\.displayName)) → \(results.count) matches")
            }
            return results
        }

        let q = query.lowercased()
        // If query matches a known tag path exactly, filter by that tag.
        let matchedTag = allTags.first { $0.fullPath.lowercased() == q }
        if let matchedTag {
            let isPlaces = matchedTag.namespace?.lowercased() == "places"
            results = results.filter { photo in
                photo.hierarchicalTags.contains { ht in
                    let hp = ht.fullPath.lowercased()
                    if hp == q { return true }
                    if isPlaces, hp.hasPrefix(q + "/") { return true }
                    return false
                }
            }
        } else {
            results = results.filter { photo in
                searchIndex[photo.id]?.contains(q) ?? false
            }
        }
        Log.search.debug("\"\(query)\" tags:\(requiredTags.map(\.displayName)) → \(results.count) matches\(matchedTag != nil ? " (exact tag)" : "")")
        return results
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
        memories.filter { !hiddenMemories.contains($0.id) }
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
        if let id = featuredPhotoByPerson[tag.fullPath], let photo = _photoByID[id] {
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
    /// both manual links and the auto-match-by-name fallback are honored, and
    /// keep `Contacts.framework` out of the exporter.
    /// In-flight debounced export. Successive calls within the coalesce window
    /// cancel the previous task so only the newest snapshot (with the latest
    /// `allPhotos` / `allTags` / `memories`) actually runs.
    private var pendingWidgetExport: Task<Void, Never>?

    func exportWidgetSnapshot() {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day], from: Date())
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
        let inputs = WidgetSnapshotExporter.Inputs(
            allPhotos: allPhotos,
            memories: memories,
            allTags: allTags,
            rootFolder: rootFolder,
            leafFolders: _cachedLeafFolders,
            todayBirthdays: birthdays
        )
        // 200ms coalesce: a single scan often fires this 3× in quick
        // succession (post-scan + post-tag-aggregation + post-memory-regen).
        // Cancel the prior task so we run once with the freshest state.
        pendingWidgetExport?.cancel()
        pendingWidgetExport = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await WidgetSnapshotExporter.shared.export(inputs)
        }
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
        memory.photoIDs.compactMap { _photoByID[$0] }
    }

    /// One-shot diagnostic dump covering the inputs `generateMemories` consumes:
    /// date provenance (embedded vs filesystem fallback), GPS coverage, People/*
    /// tag coverage, and the densest single-day clusters. Helps identify bulk-
    /// import date pollution and missing metadata.
    private nonisolated static func logMemoryInputSummary(allPhotos: [PhotoFile]) {
        let total = allPhotos.count
        guard total > 0 else { return }

        let withDate       = allPhotos.filter { $0.dateTaken != nil }
        let fromMetadata   = allPhotos.filter { $0.dateFromMetadata }.count
        let fallbackDate   = withDate.count - fromMetadata
        let withGPS        = allPhotos.filter { $0.gpsLatitude != nil && $0.gpsLongitude != nil }.count
        let withAnyTag     = allPhotos.filter { !$0.hierarchicalTags.isEmpty }.count

        let peoplePhotos = allPhotos.filter { photo in
            photo.hierarchicalTags.contains { $0.namespace?.lowercased() == "people" }
        }
        let personNameCounts = Dictionary(
            peoplePhotos.flatMap { photo in
                photo.hierarchicalTags
                    .filter { $0.namespace?.lowercased() == "people" }
                    .map { ($0.displayName, 1) }
            },
            uniquingKeysWith: +
        )
        let topPeople = personNameCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        Log.memory.info("""
            Input summary: \(total) photos total
              dates: \(fromMetadata) from metadata, \(fallbackDate) filesystem fallback, \(total - withDate.count) missing
              GPS: \(withGPS) photos
              tags: \(withAnyTag) tagged, \(peoplePhotos.count) with People/*, \(personNameCounts.count) unique names
              top People: \(topPeople.isEmpty ? "(none)" : topPeople)
            """)

        // Top 5 densest single days — smoking gun for bulk-import clustering.
        let cal = Calendar.current
        struct DayStat { var total = 0; var fromMetadata = 0 }
        var byDay: [DateComponents: DayStat] = [:]
        for photo in withDate {
            guard let date = photo.dateTaken else { continue }
            let key = cal.dateComponents([.year, .month, .day], from: date)
            var stat = byDay[key, default: DayStat()]
            stat.total += 1
            if photo.dateFromMetadata { stat.fromMetadata += 1 }
            byDay[key] = stat
        }
        let densest = byDay.sorted { $0.value.total > $1.value.total }.prefix(5)
        let dayLines = densest.map { (k, s) -> String in
            let y = k.year ?? 0, m = k.month ?? 0, d = k.day ?? 0
            return String(format: "%04d-%02d-%02d: %d photos (%d from metadata, %d fallback)",
                          y, m, d, s.total, s.fromMetadata, s.total - s.fromMetadata)
        }
        Log.memory.info("Top 5 densest days:\n  \(dayLines.joined(separator: "\n  "))")
    }

    private func generateMemories(from allPhotos: [PhotoFile], leafFolders: [PhotoFolder]) async {
        let t = CFAbsoluteTimeGetCurrent()

        Self.logMemoryInputSummary(allPhotos: allPhotos)

        // Capture contact-related state from the main actor before crossing into
        // the detached task. Birthday memory generation runs alongside the other
        // categories so the once-per-day gate covers it too.
        let contactsSnapshot = self.contacts
        let linksSnapshot = self.personContactLinks
        let lowerNameIndexSnapshot = self.contactLinker.contactsByLowerName
        let birthdaysEnabledSnapshot = self.birthdayMemoriesEnabled

        let results: [Memory] = await Task.detached(priority: .utility) {
            let calendar = Calendar.current
            let today = Date()
            let todayComponents = calendar.dateComponents([.month, .day], from: today)
            let currentYear = calendar.component(.year, from: today)
            let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
            var candidates: [Memory] = []

            let photosWithDates = allPhotos.compactMap { photo -> (PhotoFile, Date)? in
                guard let date = photo.dateTaken else { return nil }
                return (photo, date)
            }

            // === 1. On This Day ===
            let onThisDay = photosWithDates.filter { (_, date) in
                let c = calendar.dateComponents([.month, .day, .year], from: date)
                return c.month == todayComponents.month && c.day == todayComponents.day && c.year != currentYear
            }.sorted { $0.1 < $1.1 }

            if onThisDay.count >= 2 {
                let years = Set(onThisDay.map { calendar.component(.year, from: $0.1) })
                let ids = onThisDay.map(\.0.id)
                candidates.append(Memory(
                    id: "onThisDay", type: .onThisDay,
                    title: "On this day",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: onThisDay.first!.1...onThisDay.last!.1,
                    score: Double(ids.count) * 2.0 + Double(years.count) * 3.0,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 2. X Years Ago ===
            for milestone in [1, 2, 3, 5, 10, 15, 20] {
                guard let targetDate = calendar.date(byAdding: .year, value: -milestone, to: today),
                      let windowStart = calendar.date(byAdding: .day, value: -3, to: targetDate),
                      let windowEnd = calendar.date(byAdding: .day, value: 3, to: targetDate) else { continue }

                let window = photosWithDates.filter { $0.1 >= windowStart && $0.1 <= windowEnd }
                    .sorted { $0.1 < $1.1 }
                guard window.count >= 3,
                      let first = window.first?.1, let last = window.last?.1 else { continue }

                let targetYear = calendar.component(.year, from: targetDate)
                let ids = window.map(\.0.id)
                candidates.append(Memory(
                    id: "yearsAgo-\(milestone)", type: .yearsAgo,
                    title: "On this day in \(targetYear)",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: first...last,
                    score: Double(ids.count) * 1.5 + (milestone >= 5 ? 10.0 : 5.0),
                    yearsAgo: milestone, personName: nil
                ))
            }

            // === 3. Person Through the Years ===
            let peoplePairs = allPhotos.flatMap { photo in
                photo.hierarchicalTags
                    .filter { $0.namespace?.lowercased() == "people" }
                    .map { (name: $0.displayName, photo: photo) }
            }
            let byPerson = Dictionary(grouping: peoplePairs, by: { $0.name })

            for (name, entries) in byPerson {
                let withDates = entries.compactMap { entry -> (PhotoFile, Date)? in
                    guard let date = entry.photo.dateTaken else { return nil }
                    return (entry.photo, date)
                }
                let years = Set(withDates.map { calendar.component(.year, from: $0.1) })
                guard years.count >= 3, withDates.count >= 5 else { continue }
                let sorted = withDates.sorted { $0.1 < $1.1 }
                let ids = sorted.map(\.0.id)
                guard let first = sorted.first?.1, let last = sorted.last?.1 else { continue }
                candidates.append(Memory(
                    id: "person-\(name)", type: .personOverTime,
                    title: "\(name) over the years",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids.last!,
                    dateRange: first...last,
                    score: Double(years.count) * 4.0 + Double(ids.count) * 0.5,
                    yearsAgo: nil, personName: name
                ))
            }

            // === 4. Folder-based Event Memories ===
            for folder in leafFolders {
                let withDates = folder.photos.compactMap { photo -> (PhotoFile, Date)? in
                    guard let date = photo.dateTaken else { return nil }
                    return (photo, date)
                }.sorted { $0.1 < $1.1 }
                guard withDates.count >= 8,
                      let first = withDates.first?.1, let last = withDates.last?.1,
                      calendar.dateComponents([.month, .year], from: last) != currentMonthYear
                else { continue }

                let daySpan = calendar.dateComponents([.day], from: first, to: last).day ?? 0
                let spanBonus = min(Double(daySpan), 14.0)
                let ids = withDates.map(\.0.id)

                candidates.append(Memory(
                    id: "folder-\(folder.url.lastPathComponent)", type: .folderEvent,
                    title: folder.name,
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 3],
                    dateRange: first...last,
                    score: Double(ids.count) * 0.8 + spanBonus * 2.0,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 5. Photo Density Detection ===
            let byDay = Dictionary(grouping: photosWithDates) { (_, date) -> DateComponents in
                calendar.dateComponents([.year, .month, .day], from: date)
            }
            let avgPerDay = photosWithDates.isEmpty ? 0.0 : Double(photosWithDates.count) / Double(max(byDay.count, 1))
            let densityThreshold = max(10, Int(avgPerDay * 3.0))

            for (dayComp, dayEntries) in byDay where dayEntries.count >= densityThreshold {
                guard let dayDate = calendar.date(from: dayComp),
                      !calendar.isDateInToday(dayDate),
                      calendar.dateComponents([.month, .year], from: dayDate) != currentMonthYear
                else { continue }

                let sorted = dayEntries.sorted { $0.1 < $1.1 }
                let ids = sorted.map(\.0.id)
                guard let first = sorted.first?.1, let last = sorted.last?.1 else { continue }
                let dayKey = "\(dayComp.year ?? 0)-\(dayComp.month ?? 0)-\(dayComp.day ?? 0)"

                candidates.append(Memory(
                    id: "density-\(dayKey)", type: .photoDensity,
                    title: "A busy day",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: first...last,
                    score: Double(ids.count) * 1.2,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 6. Trip Detection ===
            Self.generateTripMemories(from: photosWithDates, calendar: calendar, today: today, into: &candidates)

            // === 7. Birthdays ===
            // Surface a memory only when today (month + day) matches a contact's
            // birthday and the person has at least 1 tagged photo. Explicit
            // entries in `linksSnapshot` override the auto-match by name (or
            // suppress it entirely when `.disabled`). Skipped entirely when
            // the user has disabled the master toggle in Settings
            // (`birthdayMemoriesEnabled`).
            if birthdaysEnabledSnapshot {
                Self.generateBirthdayMemories(
                    from: allPhotos,
                    contacts: contactsSnapshot,
                    links: linksSnapshot,
                    lowerNameIndex: lowerNameIndexSnapshot,
                    calendar: calendar,
                    todayComponents: todayComponents,
                    into: &candidates
                )
            }

            // Cap per-memory photo count to keep slideshow/grid responsive.
            // Sample evenly across the range to preserve temporal spread.
            let maxPhotosPerMemory = 75
            candidates = candidates.map { mem in
                guard mem.photoIDs.count > maxPhotosPerMemory else { return mem }
                let step = Double(mem.photoIDs.count) / Double(maxPhotosPerMemory)
                let sampled = (0..<maxPhotosPerMemory).map { mem.photoIDs[Int(Double($0) * step)] }
                return Memory(
                    id: mem.id, type: mem.type, title: mem.title, subtitle: mem.subtitle,
                    photoIDs: sampled, coverPhotoID: mem.coverPhotoID,
                    dateRange: mem.dateRange, score: mem.score,
                    yearsAgo: mem.yearsAgo, personName: mem.personName
                )
            }

            // Standardize every memory's subtitle to "<first date> – <last date> · N photos".
            // Done after the photo-count sampling above so the count reflects what the
            // user will actually see in the grid/slideshow.
            candidates = candidates.map { mem in
                let unified = Self.subtitleWithCount(dateRange: mem.dateRange, count: mem.photoIDs.count)
                return Memory(
                    id: mem.id, type: mem.type, title: mem.title, subtitle: unified,
                    photoIDs: mem.photoIDs, coverPhotoID: mem.coverPhotoID,
                    dateRange: mem.dateRange, score: mem.score,
                    yearsAgo: mem.yearsAgo, personName: mem.personName
                )
            }

            // Sort by score, then greedily select top 20 with overlap penalty.
            // Sub-trips are intentionally inside their parent trip's photo set,
            // so they bypass the overlap filter — losing them defeats the goal
            // of surfacing finer-grained legs of long journeys.
            candidates.sort { $0.score > $1.score }
            var selected: [Memory] = []
            var usedPhotoIDs = Set<UUID>()
            for candidate in candidates {
                let isSubtrip = candidate.id.hasPrefix("subtrip-")
                let candidateSet = Set(candidate.photoIDs)
                if !isSubtrip {
                    let overlapCount = candidateSet.intersection(usedPhotoIDs).count
                    let overlapRatio = candidateSet.isEmpty ? 0.0 : Double(overlapCount) / Double(candidateSet.count)
                    if overlapRatio > 0.7 { continue }
                }
                selected.append(candidate)
                usedPhotoIDs.formUnion(candidateSet)
                if selected.count >= 20 { break }
            }

            return selected
        }.value

        let elapsed = (CFAbsoluteTimeGetCurrent() - t) * 1000
        self.memories = results
        saveMemoriesCache()
        Log.memory.info("Generated \(results.count) memories in \(String(format: "%.0f", elapsed))ms")

        // Memories changed → refresh the widget snapshot so the Memories widget
        // picks up new "On this day" / "Years ago" content the same day they
        // become valid.
        exportWidgetSnapshot()
    }

    // MARK: Birthday Detection

    /// Build "Happy birthday, <name>" memories for every person whose linked
    /// (manual or auto-matched) contact has a birthday equal to today's
    /// month/day. Photo set = every photo carrying the People/* tag for that
    /// person, sorted oldest → newest so the slideshow tells a story.
    private nonisolated static func generateBirthdayMemories(
        from allPhotos: [PhotoFile],
        contacts: [ContactInfo],
        links: [String: PersonLink],
        lowerNameIndex: [String: ContactInfo],
        calendar: Calendar,
        todayComponents: DateComponents,
        into candidates: inout [Memory]
    ) {
        guard let todayMonth = todayComponents.month,
              let todayDay = todayComponents.day else { return }

        // Group photos by person tag fullPath, retaining the original casing.
        struct PersonBundle { let fullPath: String; let displayName: String; var photos: [PhotoFile] }
        var byPath: [String: PersonBundle] = [:]
        for photo in allPhotos {
            for tag in photo.hierarchicalTags where tag.namespace?.lowercased() == "people" {
                if var existing = byPath[tag.fullPath] {
                    existing.photos.append(photo)
                    byPath[tag.fullPath] = existing
                } else {
                    byPath[tag.fullPath] = PersonBundle(
                        fullPath: tag.fullPath,
                        displayName: tag.displayName,
                        photos: [photo]
                    )
                }
            }
        }

        let contactByID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })

        for (path, bundle) in byPath {
            // Resolve effective contact: explicit `.disabled` skips this tag,
            // a `.manual` link wins over name-based auto-match, and absence
            // means "auto-match by displayName".
            let contact: ContactInfo?
            switch links[path] {
            case .disabled:
                continue
            case .manual(let id):
                contact = contactByID[id]
            case nil:
                contact = lowerNameIndex[bundle.displayName.lowercased()]
            }
            guard let contact,
                  let bMonth = contact.birthday?.month,
                  let bDay = contact.birthday?.day,
                  bMonth == todayMonth, bDay == todayDay else { continue }

            // Sort by date when available; undated photos go to the end so the
            // cover (most recent) prefers a real timestamp.
            let sorted = bundle.photos.sorted { a, b in
                (a.dateTaken ?? .distantPast) < (b.dateTaken ?? .distantPast)
            }
            let ids = sorted.map(\.id)
            guard let coverID = ids.last else { continue }

            let dateRange: ClosedRange<Date>?
            if let first = sorted.first?.dateTaken, let last = sorted.last?.dateTaken {
                dateRange = first...last
            } else {
                dateRange = nil
            }

            // Score sits well above on-this-day / years-ago so birthdays float
            // to the front of the rail on the matching day.
            candidates.append(Memory(
                id: "birthday-\(path)",
                type: .birthday,
                title: "Happy birthday, \(bundle.displayName)",
                subtitle: nil,
                photoIDs: ids,
                coverPhotoID: coverID,
                dateRange: dateRange,
                score: 100.0 + Double(min(ids.count, 50)) * 0.5,
                yearsAgo: nil,
                personName: bundle.displayName
            ))
        }
    }

    // MARK: Trip Detection

    private nonisolated static func generateTripMemories(
        from photosWithDates: [(PhotoFile, Date)],
        calendar: Calendar,
        today: Date,
        into candidates: inout [Memory]
    ) {
        let geoPhotos = photosWithDates
            .filter { $0.0.gpsLatitude != nil && $0.0.gpsLongitude != nil }
            .sorted { $0.1 < $1.1 }

        guard geoPhotos.count >= 5 else { return }

        let allLats = geoPhotos.compactMap(\.0.gpsLatitude).sorted()
        let allLons = geoPhotos.compactMap(\.0.gpsLongitude).sorted()
        let homeLat = allLats[allLats.count / 2]
        let homeLon = allLons[allLons.count / 2]

        let distanceThresholdKm = 50.0
        var currentTrip: [(PhotoFile, Date)] = []

        for entry in geoPhotos {
            guard let lat = entry.0.gpsLatitude, let lon = entry.0.gpsLongitude else { continue }
            let dist = haversineKm(lat1: homeLat, lon1: homeLon, lat2: lat, lon2: lon)

            if dist > distanceThresholdKm {
                if let lastDate = currentTrip.last?.1,
                   entry.1.timeIntervalSince(lastDate) > 48 * 3600 {
                    flushTrip(currentTrip, calendar: calendar, today: today, into: &candidates)
                    currentTrip = []
                }
                currentTrip.append(entry)
            } else {
                flushTrip(currentTrip, calendar: calendar, today: today, into: &candidates)
                currentTrip = []
            }
        }
        flushTrip(currentTrip, calendar: calendar, today: today, into: &candidates)
    }

    private nonisolated static func flushTrip(
        _ entries: [(PhotoFile, Date)],
        calendar: Calendar,
        today: Date,
        into candidates: inout [Memory]
    ) {
        guard entries.count >= 5 else { return }
        let sorted = entries.sorted { $0.1 < $1.1 }
        guard let first = sorted.first?.1, let last = sorted.last?.1 else { return }

        let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
        guard calendar.dateComponents([.month, .year], from: last) != currentMonthYear else { return }

        let days = max(1, calendar.dateComponents([.day], from: first, to: last).day ?? 1)
        let ids = sorted.map(\.0.id)
        let tripKey = "\(calendar.component(.year, from: first))-\(calendar.component(.month, from: first))-\(calendar.component(.day, from: first))"

        let locationLabel = tripLabel(for: sorted.map(\.0))
        let title: String
        if let locationLabel {
            title = "A trip to \(locationLabel)"
        } else {
            title = "A trip"
            let sampleTags = sorted.prefix(3).flatMap { $0.0.hierarchicalTags.map(\.fullPath) }
            let sampleCountries = sorted.prefix(3).compactMap { $0.0.countryCode }
            Log.memory.debug("Trip \(tripKey): no location label. sampleTags=\(sampleTags) countryCodes=\(sampleCountries)")
        }

        candidates.append(Memory(
            id: "trip-\(tripKey)", type: .trip,
            title: title,
            subtitle: nil,
            photoIDs: ids,
            coverPhotoID: ids[ids.count / 3],
            dateRange: first...last,
            score: Double(ids.count) * 1.5 + Double(days) * 2.0 + 8.0,
            yearsAgo: nil, personName: nil
        ))

        // Surface meaningful sub-trips inside long parent trips — e.g. the
        // Buenos Aires leg of a 3-month South America journey. We split the
        // sorted photos by country code first, then by city-level Places path
        // when only one country is present. A segment qualifies if it spans at
        // least 2 days, has 5+ photos, and is meaningfully smaller than the
        // parent (so we don't duplicate the parent as a sub-trip).
        guard days >= 5 else { return }
        let parentSet = Set(ids)
        let segments: [(label: String, key: String, entries: [(PhotoFile, Date)])]
        let countriesPresent = Set(sorted.compactMap { $0.0.countryCode?.uppercased() })
        if countriesPresent.count >= 2 {
            segments = consecutiveCountrySegments(in: sorted)
        } else {
            segments = consecutivePlacesSegments(in: sorted)
        }
        for seg in segments {
            guard seg.entries.count >= 5,
                  let segFirst = seg.entries.first?.1,
                  let segLast = seg.entries.last?.1 else { continue }
            let segDays = max(1, calendar.dateComponents([.day], from: segFirst, to: segLast).day ?? 1)
            guard segDays >= 2 else { continue }
            // Sub-trip must be a strict subset of the parent and noticeably
            // smaller — otherwise it's just the trip again.
            let segIDs = seg.entries.map(\.0.id)
            let segSet = Set(segIDs)
            guard segSet != parentSet,
                  Double(segSet.count) <= Double(parentSet.count) * 0.85 else { continue }

            let subTitle = "A trip to \(seg.label)"
            candidates.append(Memory(
                id: "subtrip-\(tripKey)-\(seg.key)", type: .trip,
                title: subTitle,
                subtitle: nil,
                photoIDs: segIDs,
                coverPhotoID: segIDs[segIDs.count / 3],
                dateRange: segFirst...segLast,
                // Slightly under the parent so the parent floats first when
                // both surface, but high enough that ranks above generic items.
                score: Double(segIDs.count) * 1.4 + Double(segDays) * 1.8 + 6.0,
                yearsAgo: nil, personName: nil
            ))
        }
    }

    /// Group a sorted-by-date photo run into consecutive-country segments.
    private nonisolated static func consecutiveCountrySegments(
        in entries: [(PhotoFile, Date)]
    ) -> [(label: String, key: String, entries: [(PhotoFile, Date)])] {
        var out: [(label: String, key: String, entries: [(PhotoFile, Date)])] = []
        var current: [(PhotoFile, Date)] = []
        var currentCode: String? = nil
        func flush() {
            guard let code = currentCode, !current.isEmpty else { return }
            let label = countryName(from: code) ?? code
            out.append((label, code.lowercased(), current))
        }
        for e in entries {
            let code = e.0.countryCode?.uppercased()
            if code != currentCode {
                flush()
                current = []
                currentCode = code
            }
            if currentCode != nil { current.append(e) }
        }
        flush()
        return out
    }

    /// Group a sorted-by-date photo run by deepest Places leaf (city or below).
    /// Used when the trip stays in one country — surfaces city-level legs.
    private nonisolated static func consecutivePlacesSegments(
        in entries: [(PhotoFile, Date)]
    ) -> [(label: String, key: String, entries: [(PhotoFile, Date)])] {
        func cityKey(for photo: PhotoFile) -> (label: String, key: String)? {
            // Pick the longest Places path on the photo and use the city-level
            // segment (depth 3 = country/region/city). Fall back to the deepest
            // available.
            let placesPaths = photo.hierarchicalTags
                .filter { $0.namespace?.lowercased() == "places" }
                .map { $0.fullPath.split(separator: "/").map(String.init) }
            guard let longest = placesPaths.max(by: { $0.count < $1.count }), longest.count > 1 else { return nil }
            // segments without "Places"
            let segs = Array(longest.dropFirst())
            let cityIdx = min(2, segs.count - 1) // 0=country, 1=region, 2=city
            let label = segs[cityIdx]
            let key = segs.prefix(cityIdx + 1).joined(separator: "-").lowercased()
            return (label, key)
        }
        var out: [(label: String, key: String, entries: [(PhotoFile, Date)])] = []
        var current: [(PhotoFile, Date)] = []
        var currentLabel: String? = nil
        var currentKey: String? = nil
        func flush() {
            guard let label = currentLabel, let key = currentKey, !current.isEmpty else { return }
            out.append((label, key, current))
        }
        for e in entries {
            let info = cityKey(for: e.0)
            let label = info?.label
            let key = info?.key
            if key != currentKey {
                flush()
                current = []
                currentLabel = label
                currentKey = key
            }
            if currentKey != nil { current.append(e) }
        }
        flush()
        return out
    }

    // MARK: Trip Labeling

    /// Derives a location-based title for a trip from `Places/*` tags and
    /// `photo-tools:CountryCode`. Returns nil when no tag data is available so
    /// the caller can fall back to the generic "A trip" title.
    private nonisolated static func tripLabel(for photos: [PhotoFile]) -> String? {
        var countryCounts: [String: Int] = [:]
        for photo in photos {
            if let code = photo.countryCode, !code.isEmpty {
                countryCounts[code, default: 0] += 1
            }
        }

        if countryCounts.count >= 2 {
            let sorted = countryCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            if sorted.count > 3 {
                return "\(sorted.count) countries"
            }
            let names = sorted.map { countryName(from: $0.key) ?? $0.key }
            if names.count == 2 {
                return "\(names[0]) & \(names[1])"
            }
            return "\(names[0]), \(names[1]) & \(names[2])"
        }

        let prefix = deepestSharedPlacesPrefix(in: photos)
        if let leaf = prefix.last {
            return leaf
        }

        if let (code, _) = countryCounts.first {
            return countryName(from: code) ?? code
        }

        return nil
    }

    /// Longest `Places/*` path segments shared by every photo that carries at
    /// least one `Places/*` tag. Photos without any `Places/*` tag are skipped
    /// (collapse-on-missing-levels, per photo-tools xmp-schema.md §2.2).
    /// Returns `[]` when no photo has a `Places/*` tag.
    private nonisolated static func deepestSharedPlacesPrefix(in photos: [PhotoFile]) -> [String] {
        var perPhotoSegments: [[String]] = []
        for photo in photos {
            let placesPaths = photo.hierarchicalTags
                .filter { $0.namespace?.lowercased() == "places" }
                .map { $0.fullPath.split(separator: "/").dropFirst().map(String.init) }
            guard let longest = placesPaths.max(by: { $0.count < $1.count }), !longest.isEmpty else {
                continue
            }
            perPhotoSegments.append(longest)
        }
        guard let first = perPhotoSegments.first else { return [] }
        var prefix = first
        for segments in perPhotoSegments.dropFirst() {
            let limit = min(prefix.count, segments.count)
            var i = 0
            while i < limit && prefix[i].caseInsensitiveCompare(segments[i]) == .orderedSame {
                i += 1
            }
            prefix = Array(prefix.prefix(i))
            if prefix.isEmpty { break }
        }
        return prefix
    }

    nonisolated private static func countryName(from code: String) -> String? {
        Locale.current.localizedString(forRegionCode: code)
    }

    // MARK: Memory Helpers

    nonisolated private static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private nonisolated static func formatDateRange(_ first: Date, _ last: Date) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return fmt.string(from: first)
        }
        return "\(fmt.string(from: first)) – \(fmt.string(from: last))"
    }

    /// Standardized memory subtitle: "<first date> – <last date> · N photos".
    /// Falls back to just the photo count when no date range is available
    /// (e.g. birthday memories whose photos all lack dateTaken).
    private nonisolated static func subtitleWithCount(
        dateRange: ClosedRange<Date>?,
        count: Int
    ) -> String {
        let countText = "\(count) \(count == 1 ? "photo" : "photos")"
        guard let range = dateRange else { return countText }
        return "\(formatDateRange(range.lowerBound, range.upperBound)) · \(countText)"
    }

    // MARK: - Thumbnails

    func cachedThumbnail(for url: URL) -> UIImage? {
        thumbnailCache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL, size: CGSize, isVideo: Bool = false) async -> UIImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            return cached
        }

        let maxPixelSize = max(size.width, size.height) * UIScreen.main.scale
        let diskPath = thumbnailDiskCacheDir.appendingPathComponent(
            PhotoFile.stableID(for: url).uuidString + ".jpg"
        )

        do {
            // Check disk cache
            let image = try await Self.loadThumbnail(
                for: url, maxPixelSize: maxPixelSize, isVideo: isVideo, diskPath: diskPath
            )
            guard let image else { return nil }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            thumbnailCache.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        } catch is CancellationError {
            Log.thumb.debug("Cancelled: \(url.lastPathComponent)")
            return nil
        } catch {
            return nil
        }
    }

    /// Generates or loads a thumbnail — nonisolated for cooperative pool execution with cancellation support
    private nonisolated static func loadThumbnail(
        for url: URL, maxPixelSize: CGFloat, isVideo: Bool, diskPath: URL
    ) async throws -> UIImage? {
        try Task.checkCancellation()

        // Try disk cache first (compare modification dates)
        if FileManager.default.fileExists(atPath: diskPath.path) {
            let sourceModDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let cacheModDate = (try? diskPath.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let src = sourceModDate, let cache = cacheModDate, cache >= src,
               let data = try? Data(contentsOf: diskPath),
               let image = UIImage(data: data) {
                return image
            }
        }

        try Task.checkCancellation()

        if isVideo {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            try Task.checkCancellation()
            guard let cgImage = try? await generator.image(at: .zero).image else {
                return nil
            }
            try Task.checkCancellation()
            if let jpegData = opaqueJPEGData(from: cgImage, quality: 0.7) {
                try? jpegData.write(to: diskPath, options: .atomic)
            }
            return UIImage(cgImage: cgImage)
        } else {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                return nil
            }
            try Task.checkCancellation()
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            try Task.checkCancellation()

            // Write to disk cache (fire-and-forget)
            if let jpegData = opaqueJPEGData(from: cgImage, quality: 0.7) {
                try? jpegData.write(to: diskPath, options: .atomic)
            }
            return UIImage(cgImage: cgImage)
        }
    }

    /// JPEG-encode a CGImage after flattening onto an opaque bitmap — avoids the
    /// `writeImageAtIndex: trying to save an opaque image with AlphaPremulLast`
    /// warning emitted by UIImage.jpegData when the source has an alpha channel.
    private nonisolated static func opaqueJPEGData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return flattened.jpegData(compressionQuality: quality)
    }

    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
        try? FileManager.default.removeItem(at: thumbnailDiskCacheDir)
        try? FileManager.default.createDirectory(at: thumbnailDiskCacheDir, withIntermediateDirectories: true)
        Log.thumb.info("Thumbnail cache cleared")
    }

    // MARK: - EXIF

    func loadEXIF(for photo: PhotoFile) async -> EXIFData? {
        do {
            return try await Self.readEXIF(url: photo.url)
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    /// Reads the `photo-tools` custom XMP namespace (§1.2 of xmp-schema.md)
    /// from embedded XMP and the optional `.xmp` sidecar.
    func loadPhotoToolsMetadata(for photo: PhotoFile) async -> PhotoToolsMetadata {
        await Task.detached(priority: .userInitiated) {
            Self.readPhotoToolsMetadata(url: photo.url)
        }.value
    }

    private nonisolated static func readPhotoToolsMetadata(url: URL) -> PhotoToolsMetadata {
        var meta = PhotoToolsMetadata()

        // Embedded XMP — tag names come back without namespace prefix.
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
           let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let tags = CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag] ?? []
            for tag in tags {
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                guard let value = CGImageMetadataTagCopyValue(tag) as? String,
                      !value.isEmpty else { continue }
                switch name {
                case "TaggerVersion": meta.taggerVersion = meta.taggerVersion ?? value
                case "TaggedAt":      meta.taggedAt = meta.taggedAt ?? value
                case "CountryCode":   meta.countryCode = meta.countryCode ?? value.uppercased()
                case "CLIPModel":     meta.clipModel = meta.clipModel ?? value
                case "CLIPTimestamp": meta.clipTimestamp = meta.clipTimestamp ?? value
                default: break
                }
            }
        }

        // Sidecar — simple tag extraction for scalar fields.
        let xmpURL = url.appendingPathExtension("xmp")
        if let data = try? Data(contentsOf: xmpURL),
           let xml = String(data: data, encoding: .utf8) {
            func scalar(_ localName: String) -> String? {
                for prefix in ["photo-tools:\(localName)", "phototools:\(localName)"] {
                    if let s = xml.range(of: "<\(prefix)>"),
                       let e = xml.range(of: "</\(prefix)>", range: s.upperBound..<xml.endIndex) {
                        let v = xml[s.upperBound..<e.lowerBound]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { return v }
                    }
                }
                return nil
            }
            meta.taggerVersion = meta.taggerVersion ?? scalar("TaggerVersion")
            meta.taggedAt = meta.taggedAt ?? scalar("TaggedAt")
            if meta.countryCode == nil, let cc = scalar("CountryCode") { meta.countryCode = cc.uppercased() }
            meta.clipModel = meta.clipModel ?? scalar("CLIPModel")
            meta.clipTimestamp = meta.clipTimestamp ?? scalar("CLIPTimestamp")
        }

        return meta
    }

    private nonisolated static func readEXIF(url: URL) async throws -> EXIFData? {
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        try Task.checkCancellation()

        let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var data = EXIFData()

        data.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        data.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        data.cameraMake = tiffDict?[kCGImagePropertyTIFFMake] as? String
        data.cameraModel = tiffDict?[kCGImagePropertyTIFFModel] as? String

        data.lens = exifDict?[kCGImagePropertyExifLensModel] as? String
        data.aperture = exifDict?[kCGImagePropertyExifFNumber] as? Double
        data.shutterSpeed = exifDict?[kCGImagePropertyExifExposureTime] as? Double
        data.iso = (exifDict?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first

        if let dateString = exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            data.dateTimeOriginal = formatter.date(from: dateString)
        }

        if let lat = gpsDict?[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gpsDict?[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gpsDict?[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gpsDict?[kCGImagePropertyGPSLongitudeRef] as? String
            data.gpsLatitude = latRef == "S" ? -lat : lat
            data.gpsLongitude = lonRef == "W" ? -lon : lon
        }

        return data
    }

    // MARK: - Full Resolution

    func loadFullImage(for url: URL) async -> UIImage? {
        if let cached = fullImageCache.object(forKey: url as NSURL) {
            return cached
        }
        do {
            guard let image = try await Self.generateFullImage(for: url) else { return nil }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            fullImageCache.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        } catch is CancellationError {
            Log.thumb.debug("Cancelled full image: \(url.lastPathComponent)")
            return nil
        } catch {
            return nil
        }
    }

    private nonisolated static func generateFullImage(for url: URL) async throws -> UIImage? {
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        try Task.checkCancellation()
        // 2000px is sharp on phone screens, much faster to decode than 3600px
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 2000,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        try Task.checkCancellation()
        return UIImage(cgImage: cgImage)
    }
}
