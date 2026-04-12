import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class GalleryManager: ObservableObject {
    @Published var rootFolder: PhotoFolder?
    @Published var allPhotos: [PhotoFile] = []
    @Published var isScanning: Bool = false
    @Published var lastSyncedAt: Date?
    @Published private(set) var memories: [Memory] = []

    @Published var folderSortOrder: FolderSortOrder = .nameAscending {
        didSet { UserDefaults.standard.set(folderSortOrder.rawValue, forKey: "folderSortOrder") }
    }

    private var isEnriching = false
    private var memoriesGeneratedDate: Date?
    private let thumbnailCache = NSCache<NSURL, UIImage>()
    private let fullImageCache = NSCache<NSURL, UIImage>()
    private let bookmarkKey = "rootFolderBookmark"
    private var activeSecurityScopedURL: URL?
    private var foregroundObserver: Any?

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache.json")
    }

    init() {
        thumbnailCache.totalCostLimit = 100 * 1024 * 1024
        fullImageCache.totalCostLimit = 200 * 1024 * 1024

        if let raw = UserDefaults.standard.string(forKey: "folderSortOrder"),
           let order = FolderSortOrder(rawValue: raw) {
            folderSortOrder = order
        }

        // Load cache + start security scope synchronously so cached
        // URLs are accessible before the first SwiftUI render
        if loadCache(), let url = resolveBookmark() {
            startAccessingFolder(url)
        }

        // Rescan when app returns to foreground (e.g. user added files in Files app)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let url = self.activeSecurityScopedURL else { return }
                await self.scanFolder(at: url, silent: true)
            }
        }
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        let url = activeSecurityScopedURL
        url?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Security-Scoped Access (balanced start/stop)

    func startAccessingFolder(_ url: URL) {
        stopAccessingCurrentFolder()
        _ = url.startAccessingSecurityScopedResource()
        activeSecurityScopedURL = url
    }

    private func stopAccessingCurrentFolder() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }

    // MARK: - Bookmark Persistence

    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }

    func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: url)
            }
            return url
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }

    // MARK: - Disk Cache

    private static let cacheVersion = 10

    private struct LibraryCache: Codable {
        let version: Int
        let rootFolder: PhotoFolder
        let allPhotos: [PhotoFile]
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
                print("Failed to save cache: \(error)")
            }
        }
    }

    @discardableResult
    private func loadCache() -> Bool {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return false }
        do {
            let data = try Data(contentsOf: cacheURL)
            let cache = try JSONDecoder().decode(LibraryCache.self, from: data)
            guard cache.version == Self.cacheVersion else {
                print("[Cache] Version mismatch (\(cache.version) vs \(Self.cacheVersion)), discarding")
                try? FileManager.default.removeItem(at: cacheURL)
                return false
            }
            self.rootFolder = cache.rootFolder
            self.allPhotos = cache.allPhotos
            print("[Cache] Loaded \(cache.allPhotos.count) photos from cache v\(cache.version)")
            rebuildSortAndIndex()
            return true
        } catch {
            print("Failed to load cache: \(error)")
            return false
        }
    }

    // MARK: - Restore on Launch

    func restoreFolder() async {
        let hadCache = rootFolder != nil

        // Security scope may already be active from init()
        let url: URL
        if let active = activeSecurityScopedURL {
            url = active
        } else {
            guard let resolved = resolveBookmark() else { return }
            startAccessingFolder(resolved)
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
        guard let url = activeSecurityScopedURL else { return }
        await scanFolder(at: url, silent: true)
    }

    // MARK: - Metadata Reading

    private typealias MetadataResult = (date: Date?, keywords: [String], hierarchicalTags: [HierarchicalTag], gpsLatitude: Double?, gpsLongitude: Double?)

    /// Read capture date and keywords from image metadata (EXIF/IPTC/XMP) + XMP sidecar
    private nonisolated static func readImageMetadata(url: URL) -> MetadataResult {
        var captureDate: Date? = nil
        var keywords: [String] = []
        var rawTags: [String] = []  // preserves original hierarchical paths
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

            // IPTC keywords (flat)
            if let iptcDict = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
               let iptcKeywords = iptcDict[kCGImagePropertyIPTCKeywords] as? [String] {
                for kw in iptcKeywords {
                    keywords.append(kw)
                    rawTags.append(kw)
                }
            }

            // XMP metadata (dc:subject, lr:hierarchicalSubject, digiKam:TagsList)
            if let xmpMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                let tags = CGImageMetadataCopyTags(xmpMetadata) as? [CGImageMetadataTag] ?? []
                for tag in tags {
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                    if name == "subject" || name == "TagsList" || name == "hierarchicalSubject" {
                        if let value = CGImageMetadataTagCopyValue(tag) {
                            let items: [String]
                            if let array = value as? [String] {
                                items = array
                            } else if let str = value as? String {
                                items = [str]
                            } else {
                                items = []
                            }
                            for item in items {
                                rawTags.append(item)
                                let sep: Character? = item.contains("|") ? "|" : item.contains("/") ? "/" : item.contains(":") ? ":" : nil
                                if let sep = sep {
                                    let parts = item.split(separator: sep).map { String($0).trimmingCharacters(in: .whitespaces) }
                                    keywords.append(contentsOf: parts)
                                } else {
                                    keywords.append(item)
                                }
                            }
                        }
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

        // Also check for XMP sidecar file
        let (sidecarKeywords, sidecarRawTags) = readXMPSidecar(for: url)
        keywords.append(contentsOf: sidecarKeywords)
        rawTags.append(contentsOf: sidecarRawTags)

        // Deduplicate keywords (case-insensitive)
        var seen = Set<String>()
        keywords = keywords.filter { kw in
            let lower = kw.lowercased()
            if seen.contains(lower) { return false }
            seen.insert(lower)
            return true
        }

        // Build deduplicated hierarchical tags from raw paths
        var seenPaths = Set<String>()
        let hierarchicalTags = rawTags.compactMap { raw -> HierarchicalTag? in
            let key = raw.lowercased()
            guard !seenPaths.contains(key) else { return nil }
            seenPaths.insert(key)
            return HierarchicalTag(raw: raw)
        }

        return (captureDate, keywords, hierarchicalTags, gpsLat, gpsLon)
    }

    /// Parse XMP sidecar file (.xmp) for keywords
    private nonisolated static func readXMPSidecar(for imageURL: URL) -> (keywords: [String], rawTags: [String]) {
        let xmpURL = imageURL.appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: xmpURL.path),
              let data = try? Data(contentsOf: xmpURL),
              let xml = String(data: data, encoding: .utf8) else { return ([], []) }

        var keywords: [String] = []
        var rawTags: [String] = []

        // Parse dc:subject, digiKam:TagsList, lr:hierarchicalSubject
        let patterns = [
            "dc:subject", "digiKam:TagsList", "lr:hierarchicalSubject",
            "MicrosoftPhoto:LastKeywordXMP"
        ]

        for pattern in patterns {
            guard let startRange = xml.range(of: "<\(pattern)>") ?? xml.range(of: "<\(pattern) ") else { continue }
            guard let endRange = xml.range(of: "</\(pattern)>", range: startRange.upperBound..<xml.endIndex) else { continue }
            let block = String(xml[startRange.upperBound..<endRange.lowerBound])

            var searchRange = block.startIndex..<block.endIndex
            while let liStart = block.range(of: "<rdf:li>", range: searchRange) {
                guard let liEnd = block.range(of: "</rdf:li>", range: liStart.upperBound..<block.endIndex) else { break }
                let value = String(block[liStart.upperBound..<liEnd.lowerBound])
                rawTags.append(value)
                let sep: Character? = value.contains("|") ? "|" : value.contains("/") ? "/" : value.contains(":") ? ":" : nil
                if let sep = sep {
                    let parts = value.split(separator: sep).map { String($0).trimmingCharacters(in: .whitespaces) }
                    keywords.append(contentsOf: parts)
                } else {
                    keywords.append(value)
                }
                searchRange = liEnd.upperBound..<block.endIndex
            }
        }

        return (keywords, rawTags)
    }

    /// Read capture date from video metadata
    private nonisolated static func readVideoDate(url: URL) async -> Date? {
        let asset = AVAsset(url: url)
        guard let creationDate = try? await asset.load(.creationDate),
              let dateValue = try? await creationDate.load(.dateValue) else {
            return nil
        }
        return dateValue
    }

    // MARK: - Folder Scanning (Iterative)

    func scanFolder(at url: URL, silent: Bool = false) async {
        if !silent { isScanning = true }

        // Snapshot cached metadata so we can merge it into the fresh scan
        let cachedMetadata = Dictionary(allPhotos.map { ($0.url, (date: $0.dateTaken, keywords: $0.keywords, tags: $0.hierarchicalTags, enrichedFileDate: $0.enrichedFileDate, gpsLat: $0.gpsLatitude, gpsLon: $0.gpsLongitude)) },
                                         uniquingKeysWith: { _, b in b })

        // Heavy file I/O runs off the main actor so cached UI stays responsive
        let result: (root: PhotoFolder?, flatPhotos: [PhotoFile], needsEnrichment: Bool) = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var flatPhotos: [PhotoFile] = []
            var needsEnrichment = false

            struct FolderNode {
                let url: URL
                let name: String
                var photos: [PhotoFile]
                var childIndices: [Int]
                let parentIndex: Int?
                let dateModified: Date?
                let dateCreated: Date?
            }

            var nodes: [FolderNode] = []
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
                    struct ScannedFile {
                        let url: URL; let fileSize: Int64; let modDate: Date?; let creationDate: Date?; let isImage: Bool; let isVideo: Bool
                    }
                    var scannedFiles: [ScannedFile] = []

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
                                    scannedFiles.append(ScannedFile(
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
                        // Prefer cached EXIF date; fall back to file creation date (not modDate,
                        // which changes when metadata is rewritten and would misplace photos)
                        let dateTaken = cached?.date ?? file.creationDate
                        let keywords = cached?.keywords ?? []
                        let tags = cached?.tags ?? []
                        let cachedEnrichedDate = cached?.enrichedFileDate
                        // Re-enrich if never enriched or file was modified since last enrichment
                        let stale = cachedEnrichedDate == nil || file.modDate != cachedEnrichedDate
                        if stale {
                            needsEnrichment = true
                        }

                        photos.append(PhotoFile(
                            id: UUID(), url: file.url, filename: stem,
                            fileSize: file.fileSize,
                            dateTaken: dateTaken,
                            livePhotoVideoURL: liveURL,
                            keywords: keywords,
                            hierarchicalTags: tags,
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
                                id: UUID(), url: file.url, filename: stem,
                                fileSize: file.fileSize, dateTaken: cached?.date ?? file.creationDate ?? file.modDate,
                                isVideo: true
                            ))
                        }
                    }

                    let imageCount = scannedFiles.filter(\.isImage).count
                    let videoCount = scannedFiles.filter(\.isVideo).count
                    if videoCount > 0 {
                        print("[Scan] \(dirName): \(imageCount) images, \(videoCount) videos → \(pairedCount) live pairs, \(standaloneVideoCount) standalone videos")
                        if pairedCount == 0 && videoCount > 0 {
                            let sampleImageStems = Array(imageStemSet.prefix(3))
                            let sampleVideoStems = Array(videoByName.keys.prefix(3))
                            print("[Scan]   Image stems: \(sampleImageStems)")
                            print("[Scan]   Video stems: \(sampleVideoStems)")
                        }
                    }
                }

                let dirKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
                let dirValues = try? dirURL.resourceValues(forKeys: dirKeys)

                let nodeIndex = nodes.count
                nodes.append(FolderNode(
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
                    id: UUID(),
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

        // Back on main actor — update published properties
        if !result.flatPhotos.isEmpty || !silent {
            print("[Scan] Complete: \(result.flatPhotos.count) photos (needsEnrichment=\(result.needsEnrichment))")
            self.rootFolder = result.root
            self.allPhotos = result.flatPhotos
            rebuildSortAndIndex()
            saveCache()
        }
        isScanning = false
        lastSyncedAt = Date()

        // Phase 2: enrich with EXIF dates and keywords in background (only if needed)
        if result.needsEnrichment && !allPhotos.isEmpty {
            await enrichMetadata()
        }
    }

    /// Read EXIF dates and keywords for all photos in the background.
    /// Updates allPhotos in a single assignment so dates/keywords are live immediately.
    private func enrichMetadata() async {
        guard !isEnriching else { return }
        isEnriching = true
        defer { isEnriching = false }

        let photos = allPhotos
        let staleCount = photos.filter { $0.enrichedFileDate == nil && !$0.isVideo }.count
        let startTime = CFAbsoluteTimeGetCurrent()
        print("[Enrich] Starting metadata enrichment: \(staleCount) new/changed of \(photos.count) total")

        if staleCount == 0 {
            print("[Enrich] All photos up-to-date, skipping")
            return
        }

        let enrichedPhotos: [PhotoFile] = await Task.detached(priority: .background) {
            let fm = FileManager.default
            var result = photos
            var dateCount = 0
            var keywordCount = 0
            var uniqueKeywords = Set<String>()
            for i in result.indices where !result[i].isVideo && result[i].enrichedFileDate == nil {
                let metadata = GalleryManager.readImageMetadata(url: result[i].url)
                if let date = metadata.date {
                    result[i].dateTaken = date
                    dateCount += 1
                } else if result[i].dateTaken == nil {
                    // No EXIF date; prefer file creation date over modification date
                    // (modDate changes when metadata is rewritten externally)
                    let attrs = try? result[i].url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    result[i].dateTaken = attrs?.creationDate ?? attrs?.contentModificationDate
                }
                if !metadata.keywords.isEmpty {
                    result[i].keywords = metadata.keywords
                    result[i].hierarchicalTags = metadata.hierarchicalTags
                    keywordCount += 1
                    for kw in metadata.keywords { uniqueKeywords.insert(kw.lowercased()) }
                }
                if let lat = metadata.gpsLatitude, let lon = metadata.gpsLongitude {
                    result[i].gpsLatitude = lat
                    result[i].gpsLongitude = lon
                }
                // Stamp with the file's current modDate so we detect future changes
                let modDate = (try? fm.attributesOfItem(atPath: result[i].url.path)[.modificationDate]) as? Date
                result[i].enrichedFileDate = modDate ?? Date()
                if (i + 1) % 5000 == 0 {
                    print("[Enrich] Processed \(i + 1)/\(result.count)…")
                }
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("[Enrich] Done in \(String(format: "%.1f", elapsed))s: \(dateCount) EXIF dates, \(keywordCount) photos with keywords, \(uniqueKeywords.count) unique tags")
            if !uniqueKeywords.isEmpty {
                let sample = Array(uniqueKeywords.sorted().prefix(20))
                print("[Enrich] Sample keywords: \(sample.joined(separator: ", "))")
            }
            // Log raw hierarchical tag paths to verify namespace parsing
            let sampleTags = result.flatMap(\.hierarchicalTags).prefix(20)
            if !sampleTags.isEmpty {
                let tagDetails = sampleTags.map { "\($0.fullPath) → ns:\($0.namespace ?? "nil") name:\($0.displayName)" }
                print("[Enrich] Sample hierarchical tags:\n  \(tagDetails.joined(separator: "\n  "))")
            }
            return result
        }.value

        // Only apply if allPhotos hasn't been replaced during enrichment
        guard allPhotos.count == photos.count,
              allPhotos.first?.url == photos.first?.url else {
            print("[Enrich] Skipped — allPhotos changed during enrichment")
            return
        }

        // Single assignment updates @Published, triggers one view update
        self.allPhotos = enrichedPhotos
        rebuildSortAndIndex()

        // Also update folder tree and save cache
        if let root = rootFolder {
            let photosByURL = Dictionary(enrichedPhotos.map { ($0.url, $0) }, uniquingKeysWith: { _, b in b })
            self.rootFolder = Self.updateFolderPhotos(root, photosByURL: photosByURL)
        }
        saveCache()
        print("[Enrich] Applied enriched metadata to live data")
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
    @Published private(set) var allTags: [TagSuggestion] = []

    var sortedPhotos: [PhotoFile] { _sortedPhotos }

    func sortPhotos(_ photos: [PhotoFile]) -> [PhotoFile] {
        photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
    }

    private func rebuildSortAndIndex() {
        let t = CFAbsoluteTimeGetCurrent()
        _sortedPhotos = sortPhotos(allPhotos)
        let withKeywords = allPhotos.filter { !$0.keywords.isEmpty }.count
        let withDates = allPhotos.filter { $0.dateTaken != nil }.count

        // Build search index: includes filename, keywords, and full tag paths
        searchIndex = Dictionary(uniqueKeysWithValues: allPhotos.map { photo in
            let tagPaths = photo.hierarchicalTags.map(\.fullPath)
            let corpus = ([photo.filename] + photo.keywords + tagPaths)
                .joined(separator: "\n")
                .lowercased()
            return (photo.id, corpus)
        })

        // Aggregate global tag list for autocomplete suggestions
        var tagCounts: [String: (tag: HierarchicalTag, count: Int)] = [:]
        for photo in allPhotos {
            for tag in photo.hierarchicalTags {
                let key = tag.fullPath.lowercased()
                if let existing = tagCounts[key] {
                    tagCounts[key] = (existing.tag, existing.count + 1)
                } else {
                    tagCounts[key] = (tag, 1)
                }
            }
        }
        allTags = tagCounts.values
            .map { TagSuggestion(id: $0.tag.fullPath.lowercased(), displayName: $0.tag.displayName, fullPath: $0.tag.fullPath, namespace: $0.tag.namespace, count: $0.count) }
            .sorted { $0.count > $1.count }

        print("[Index] Built: \(allPhotos.count) photos (\(withDates) dates, \(withKeywords) keywords, \(allTags.count) unique tags) in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t) * 1000))ms")

        let today = Calendar.current.startOfDay(for: Date())
        if memoriesGeneratedDate != today && !allPhotos.isEmpty {
            memoriesGeneratedDate = today
            let snapshot = allPhotos
            let leaves = leafFolders
            Task { await generateMemories(from: snapshot, leafFolders: leaves) }
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
        var results = _sortedPhotos

        // Apply AND filter for each required tag
        for tag in requiredTags {
            let tagPath = tag.fullPath.lowercased()
            results = results.filter { photo in
                photo.hierarchicalTags.contains { $0.fullPath.lowercased() == tagPath }
            }
        }

        guard !query.isEmpty else {
            if !requiredTags.isEmpty {
                print("[Search] tags:\(requiredTags.map(\.displayName)) → \(results.count) matches")
            }
            return results
        }

        let q = query.lowercased()
        // If query matches a known tag path exactly, filter by that tag
        let isTagQuery = allTags.contains { $0.fullPath.lowercased() == q }
        if isTagQuery {
            results = results.filter { photo in
                photo.hierarchicalTags.contains { $0.fullPath.lowercased() == q }
            }
        } else {
            results = results.filter { photo in
                searchIndex[photo.id]?.contains(q) ?? false
            }
        }
        print("[Search] \"\(query)\" tags:\(requiredTags.map(\.displayName)) → \(results.count) matches\(isTagQuery ? " (exact tag)" : "")")
        return results
    }

    // MARK: - Collections Helpers

    var peopleTags: [TagSuggestion] {
        allTags.filter { $0.namespace?.lowercased() == "people" }
    }

    var leafFolders: [PhotoFolder] {
        guard let root = rootFolder else { return [] }
        return Self.collectLeafFolders(root)
    }

    private static func collectLeafFolders(_ folder: PhotoFolder) -> [PhotoFolder] {
        if folder.subfolders.isEmpty && !folder.photos.isEmpty {
            return [folder]
        }
        return folder.subfolders.flatMap { collectLeafFolders($0) }
    }

    // MARK: - Memories

    /// Resolve photo IDs from a memory back to PhotoFile instances.
    func photos(for memory: Memory) -> [PhotoFile] {
        let lookup = Dictionary(allPhotos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return memory.photoIDs.compactMap { lookup[$0] }
    }

    private func generateMemories(from allPhotos: [PhotoFile], leafFolders: [PhotoFolder]) async {
        let t = CFAbsoluteTimeGetCurrent()

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
                    subtitle: "\(years.count) different years",
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

                let yearLabel = milestone == 1 ? "1 year ago" : "\(milestone) years ago"
                let ids = window.map(\.0.id)
                candidates.append(Memory(
                    id: "yearsAgo-\(milestone)", type: .yearsAgo,
                    title: "\(yearLabel) today",
                    subtitle: Self.formatDateRange(first, last),
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
                    title: "\(name) through the years",
                    subtitle: "\(years.count) years of memories",
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
                    subtitle: Self.formatDateRange(first, last),
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
                let relDate = Self.relativeDescription(for: dayDate, calendar: calendar, today: today)
                let dayKey = "\(dayComp.year ?? 0)-\(dayComp.month ?? 0)-\(dayComp.day ?? 0)"

                candidates.append(Memory(
                    id: "density-\(dayKey)", type: .photoDensity,
                    title: "A busy day \(relDate)",
                    subtitle: Self.formatDateRange(first, last),
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: first...last,
                    score: Double(ids.count) * 1.2,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 6. Trip Detection ===
            Self.generateTripMemories(from: photosWithDates, calendar: calendar, today: today, into: &candidates)

            // Sort by score, then greedily select top 15 with overlap penalty
            candidates.sort { $0.score > $1.score }
            var selected: [Memory] = []
            var usedPhotoIDs = Set<UUID>()
            for candidate in candidates {
                let candidateSet = Set(candidate.photoIDs)
                let overlapCount = candidateSet.intersection(usedPhotoIDs).count
                let overlapRatio = candidateSet.isEmpty ? 0.0 : Double(overlapCount) / Double(candidateSet.count)
                if overlapRatio > 0.7 { continue }
                selected.append(candidate)
                usedPhotoIDs.formUnion(candidateSet)
                if selected.count >= 15 { break }
            }

            return selected
        }.value

        let elapsed = (CFAbsoluteTimeGetCurrent() - t) * 1000
        self.memories = results
        print("[Memories] Generated \(results.count) memories in \(String(format: "%.0f", elapsed))ms")
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
        let relDate = relativeDescription(for: first, calendar: calendar, today: today)
        let ids = sorted.map(\.0.id)
        let tripKey = "\(calendar.component(.year, from: first))-\(calendar.component(.month, from: first))-\(calendar.component(.day, from: first))"

        candidates.append(Memory(
            id: "trip-\(tripKey)", type: .trip,
            title: "A trip \(relDate)",
            subtitle: "\(days) \(days == 1 ? "day" : "days")",
            photoIDs: ids,
            coverPhotoID: ids[ids.count / 3],
            dateRange: first...last,
            score: Double(ids.count) * 1.5 + Double(days) * 2.0 + 8.0,
            yearsAgo: nil, personName: nil
        ))
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

    private static let dateRangeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt
    }()

    private nonisolated static func formatDateRange(_ first: Date, _ last: Date) -> String {
        let fmt = dateRangeFormatter
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return fmt.string(from: first)
        }
        return "\(fmt.string(from: first)) – \(fmt.string(from: last))"
    }

    private nonisolated static func relativeDescription(for date: Date, calendar: Calendar, today: Date) -> String {
        let years = calendar.dateComponents([.year], from: date, to: today).year ?? 0
        if years == 0 {
            let months = calendar.dateComponents([.month], from: date, to: today).month ?? 0
            return months <= 1 ? "last month" : "\(months) months ago"
        } else if years == 1 {
            return "a year ago"
        } else {
            return "\(years) years ago"
        }
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
        let result: UIImage? = await Task.detached(priority: .background) {
            if isVideo {
                let asset = AVAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    return UIImage(cgImage: cgImage)
                }
                return nil
            } else {
                let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                    return nil
                }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                    return nil
                }
                return UIImage(cgImage: cgImage)
            }
        }.value

        if let image = result {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            thumbnailCache.setObject(image, forKey: url as NSURL, cost: cost)
        }

        return result
    }

    // MARK: - EXIF

    func loadEXIF(for photo: PhotoFile) async -> EXIFData? {
        let url = photo.url
        return await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                return nil
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return nil
            }

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
        }.value
    }

    // MARK: - Full Resolution

    func loadFullImage(for url: URL) async -> UIImage? {
        if let cached = fullImageCache.object(forKey: url as NSURL) {
            return cached
        }
        let result: UIImage? = await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                return nil
            }
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
            return UIImage(cgImage: cgImage)
        }.value
        if let image = result {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            fullImageCache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return result
    }
}
