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

    @Published var folderSortOrder: FolderSortOrder = .nameAscending {
        didSet { UserDefaults.standard.set(folderSortOrder.rawValue, forKey: "folderSortOrder") }
    }

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

    private static let cacheVersion = 3 // Bump to invalidate old caches (added keywords + EXIF dates)

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

    /// Read capture date and keywords from image metadata (EXIF/IPTC/XMP) + XMP sidecar
    private nonisolated static func readImageMetadata(url: URL) -> (date: Date?, keywords: [String]) {
        var captureDate: Date? = nil
        var keywords: [String] = []

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

            // IPTC keywords
            if let iptcDict = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
               let iptcKeywords = iptcDict[kCGImagePropertyIPTCKeywords] as? [String] {
                keywords.append(contentsOf: iptcKeywords)
            }

            // XMP metadata (dc:subject, lr:hierarchicalSubject)
            if let xmpMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                let tags = CGImageMetadataCopyTags(xmpMetadata) as? [CGImageMetadataTag] ?? []
                for tag in tags {
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                    if name == "subject" || name == "TagsList" || name == "hierarchicalSubject" {
                        if let value = CGImageMetadataTagCopyValue(tag) {
                            if let array = value as? [String] {
                                for item in array {
                                    // Split hierarchical tags: "People|John Smith" → ["People", "John Smith"]
                                    let parts = item.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                                    keywords.append(contentsOf: parts)
                                }
                            } else if let str = value as? String {
                                let parts = str.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                                keywords.append(contentsOf: parts)
                            }
                        }
                    }
                }
            }
        }

        // Also check for XMP sidecar file
        let sidecarKeywords = readXMPSidecar(for: url)
        keywords.append(contentsOf: sidecarKeywords)

        // Deduplicate keywords (case-insensitive)
        var seen = Set<String>()
        keywords = keywords.filter { kw in
            let lower = kw.lowercased()
            if seen.contains(lower) { return false }
            seen.insert(lower)
            return true
        }

        return (captureDate, keywords)
    }

    /// Parse XMP sidecar file (.xmp) for keywords
    private nonisolated static func readXMPSidecar(for imageURL: URL) -> [String] {
        let xmpURL = imageURL.appendingPathExtension("xmp")
        guard let data = try? Data(contentsOf: xmpURL),
              let xml = String(data: data, encoding: .utf8) else { return [] }

        var keywords: [String] = []

        // Parse dc:subject, digiKam:TagsList, lr:hierarchicalSubject
        // These appear as <rdf:li>value</rdf:li> inside their respective tags
        let patterns = [
            "dc:subject", "digiKam:TagsList", "lr:hierarchicalSubject",
            "MicrosoftPhoto:LastKeywordXMP"
        ]

        for pattern in patterns {
            guard let startRange = xml.range(of: "<\(pattern)>") ?? xml.range(of: "<\(pattern) ") else { continue }
            guard let endRange = xml.range(of: "</\(pattern)>", range: startRange.upperBound..<xml.endIndex) else { continue }
            let block = String(xml[startRange.upperBound..<endRange.lowerBound])

            // Extract <rdf:li> values
            var searchRange = block.startIndex..<block.endIndex
            while let liStart = block.range(of: "<rdf:li>", range: searchRange) {
                guard let liEnd = block.range(of: "</rdf:li>", range: liStart.upperBound..<block.endIndex) else { break }
                let value = String(block[liStart.upperBound..<liEnd.lowerBound])
                let parts = value.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                keywords.append(contentsOf: parts)
                searchRange = liEnd.upperBound..<block.endIndex
            }
        }

        return keywords
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

        // Heavy file I/O runs off the main actor so cached UI stays responsive
        let result: (root: PhotoFolder?, flatPhotos: [PhotoFile]) = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var flatPhotos: [PhotoFile] = []

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

                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .typeIdentifierKey]

                if let contents = try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    // First pass: classify files and collect metadata
                    struct ScannedFile {
                        let url: URL; let fileSize: Int64; let modDate: Date?; let isImage: Bool; let isVideo: Bool
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
                        let metadata = GalleryManager.readImageMetadata(url: file.url)
                        photos.append(PhotoFile(
                            id: UUID(), url: file.url, filename: stem,
                            fileSize: file.fileSize,
                            dateTaken: metadata.date ?? file.modDate,
                            livePhotoVideoURL: liveURL,
                            keywords: metadata.keywords
                        ))
                    }
                    // Standalone videos only (no matching image)
                    var standaloneVideoCount = 0
                    for file in scannedFiles where file.isVideo {
                        let stem = videoStem(file.url)
                        if !imageStemSet.contains(stem) {
                            standaloneVideoCount += 1
                            photos.append(PhotoFile(
                                id: UUID(), url: file.url, filename: stem,
                                fileSize: file.fileSize, dateTaken: file.modDate,
                                isVideo: true
                            ))
                        }
                    }

                    let imageCount = scannedFiles.filter(\.isImage).count
                    let videoCount = scannedFiles.filter(\.isVideo).count
                    if videoCount > 0 {
                        print("[Scan] \(dirName): \(imageCount) images, \(videoCount) videos → \(pairedCount) live pairs, \(standaloneVideoCount) standalone videos")
                        if pairedCount == 0 && videoCount > 0 {
                            // Log sample stems to debug mismatch
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
            return (root, flatPhotos)
        }.value

        // Back on main actor — update published properties
        if !result.flatPhotos.isEmpty || !silent {
            self.rootFolder = result.root
            self.allPhotos = result.flatPhotos
            rebuildSortAndIndex()
            saveCache()
        }
        isScanning = false
    }

    // MARK: - Sorted / Search

    /// Pre-sorted array, rebuilt when allPhotos changes
    private var _sortedPhotos: [PhotoFile] = []
    /// Lowercase search corpus per photo ID for fast substring matching
    private var searchIndex: [UUID: String] = [:]

    var sortedPhotos: [PhotoFile] { _sortedPhotos }

    func sortPhotos(_ photos: [PhotoFile]) -> [PhotoFile] {
        photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
    }

    private func rebuildSortAndIndex() {
        _sortedPhotos = sortPhotos(allPhotos)
        searchIndex = Dictionary(uniqueKeysWithValues: allPhotos.map { photo in
            let corpus = ([photo.filename] + photo.keywords)
                .joined(separator: " ")
                .lowercased()
            return (photo.id, corpus)
        })
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

    func search(query: String) -> [PhotoFile] {
        guard !query.isEmpty else { return _sortedPhotos }
        let q = query.lowercased()
        return _sortedPhotos.filter { photo in
            searchIndex[photo.id]?.contains(q) ?? false
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
