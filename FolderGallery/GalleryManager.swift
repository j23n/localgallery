import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class GalleryManager: ObservableObject {
    @Published var rootFolder: PhotoFolder?
    @Published var allPhotos: [PhotoFile] = []
    @Published var currentSortOrder: SortOrder = .dateDescending
    @Published var isScanning: Bool = false

    private let thumbnailCache = NSCache<NSURL, UIImage>()
    private let bookmarkKey = "rootFolderBookmark"

    init() {
        thumbnailCache.totalCostLimit = 100 * 1024 * 1024
    }

    // MARK: - Bookmark Persistence (matches FolderPlayer pattern)

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

    func restoreFolder() async {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            _ = url.startAccessingSecurityScopedResource()
            if isStale {
                saveBookmark(for: url)
            }
            await scanFolder(at: url)
        } catch {
            print("Failed to resolve bookmark: \(error)")
        }
    }

    // MARK: - Folder Scanning (Iterative)

    func scanFolder(at url: URL) async {
        isScanning = true
        defer { isScanning = false }

        let fm = FileManager.default
        var flatPhotos: [PhotoFile] = []

        struct FolderNode {
            let url: URL
            let name: String
            var photos: [PhotoFile]
            var childIndices: [Int]
            let parentIndex: Int?
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
                                dateTaken: modDate,
                                dimensions: nil,
                                exif: nil
                            )
                            photos.append(photo)
                        }
                    }
                }
            }

            let nodeIndex = nodes.count
            nodes.append(FolderNode(
                url: dirURL,
                name: dirName,
                photos: photos,
                childIndices: [],
                parentIndex: parentIdx
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
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

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
                totalPhotoCount: recursiveCount
            )
        }

        let root = nodes.isEmpty ? nil : buildFolder(from: 0)
        self.rootFolder = root
        self.allPhotos = flatPhotos
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

    func search(query: String) -> [PhotoFile] {
        guard !query.isEmpty else { return sortedPhotos }
        return sortedPhotos.filter {
            $0.filename.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Thumbnails

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
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}
