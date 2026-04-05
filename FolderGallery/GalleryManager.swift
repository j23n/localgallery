import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class GalleryManager: ObservableObject {
    @Published var rootFolder: PhotoFolder?
    @Published var allPhotos: [PhotoFile] = []
    @Published var isScanning: Bool = false

    @Published var currentSortOrder: SortOrder = .dateDescending {
        didSet { UserDefaults.standard.set(currentSortOrder.rawValue, forKey: "photoSortOrder") }
    }
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

        // Restore persisted sort orders
        if let raw = UserDefaults.standard.string(forKey: "photoSortOrder"),
           let order = SortOrder(rawValue: raw) {
            currentSortOrder = order
        }
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

    private struct LibraryCache: Codable {
        let rootFolder: PhotoFolder
        let allPhotos: [PhotoFile]
    }

    private func saveCache() {
        guard let root = rootFolder else { return }
        let cache = LibraryCache(rootFolder: root, allPhotos: allPhotos)
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
            self.rootFolder = cache.rootFolder
            self.allPhotos = cache.allPhotos
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
                    for itemURL in contents {
                        let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys))
                        let isDir = resourceValues?.isDirectory ?? false

                        if isDir {
                            subdirs.append(itemURL)
                        } else {
                            let ext = itemURL.pathExtension.lowercased()
                            if !ext.isEmpty,
                               let utType = UTType(filenameExtension: ext),
                               utType.conforms(to: .image) {
                                let fileSize = Int64(resourceValues?.fileSize ?? 0)
                                let modDate = resourceValues?.contentModificationDate
                                let photo = PhotoFile(
                                    id: UUID(),
                                    url: itemURL,
                                    filename: itemURL.deletingPathExtension().lastPathComponent,
                                    fileSize: fileSize,
                                    dateTaken: modDate
                                )
                                photos.append(photo)
                            }
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
            saveCache()
        }
        isScanning = false
    }

    // MARK: - Sorted / Search

    var sortedPhotos: [PhotoFile] {
        sortPhotos(allPhotos)
    }

    func sortPhotos(_ photos: [PhotoFile]) -> [PhotoFile] {
        switch currentSortOrder {
        case .nameAscending:
            return photos.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .nameDescending:
            return photos.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        case .dateAscending:
            return photos.sorted { ($0.dateTaken ?? .distantPast) < ($1.dateTaken ?? .distantPast) }
        case .dateDescending:
            return photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
        case .sizeAscending:
            return photos.sorted { $0.fileSize < $1.fileSize }
        case .sizeDescending:
            return photos.sorted { $0.fileSize > $1.fileSize }
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

    func search(query: String) -> [PhotoFile] {
        guard !query.isEmpty else { return sortedPhotos }
        return sortedPhotos.filter {
            $0.filename.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Thumbnails

    func cachedThumbnail(for url: URL) -> UIImage? {
        thumbnailCache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL, size: CGSize) async -> UIImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            return cached
        }

        let maxPixelSize = max(size.width, size.height) * UIScreen.main.scale
        let result: UIImage? = await Task.detached(priority: .background) {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
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
