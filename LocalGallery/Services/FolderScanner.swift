import Foundation
import UniformTypeIdentifiers
import os

/// Iterative folder traversal that produces a `PhotoFolder` tree + flat
/// `[PhotoFile]` from a security-scoped root URL. The Store passes in a
/// snapshot of cached metadata so this stays a pure detached-task operation
/// — `@Observable` state assignment, cache save, and enrichment scheduling
/// stay on the Store side.
enum FolderScanner {
    /// Cached EXIF / tag / location data the Store carries forward across
    /// scans. Keyed by file URL. Sendable so the Store can hand a snapshot
    /// to the detached scan task.
    struct CachedPhotoMetadata: Sendable {
        let date: Date?
        let tags: [HierarchicalTag]
        let countryCode: String?
        let enrichedFileDate: Date?
        let gpsLatitude: Double?
        let gpsLongitude: Double?
        let faceRegions: [FaceRegion]
    }

    /// One row of the sidecar manifest the scanner emits. Carries the photo's
    /// stable UUID, the `.xmp` URL, and the URLResourceKey-derived version of
    /// the sidecar at scan time. Used by `SidecarSyncService` to diff against
    /// the cache without re-reading anything.
    struct SidecarCandidate: Sendable {
        let photoID: UUID
        let sidecarURL: URL
        let currentVersion: FileProviderDetector.ContentVersion
        let downloadStatus: FileProviderDetector.DownloadStatus
    }

    struct Result: Sendable {
        let rootFolder: PhotoFolder?
        let flatPhotos: [PhotoFile]
        let needsEnrichment: Bool
        let sidecarManifest: [SidecarCandidate]
    }

    /// Internal scratch nodes used during traversal — flat array indexed by
    /// `parentIndex` / `childIndices` so we can build the recursive
    /// `PhotoFolder` tree in a second pass without intermediate copies.
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
        let url: URL
        let fileSize: Int64
        let modDate: Date?
        let creationDate: Date?
        let isImage: Bool
        let isVideo: Bool
    }

    /// Walk the security-scoped folder iteratively and build the result on a
    /// detached background task. `cachedMetadata` is a per-URL snapshot the
    /// Store carries forward to avoid re-reading EXIF for unchanged files;
    /// the scanner uses it only as a fast path.
    static func scan(
        at rootURL: URL,
        cachedMetadata: [URL: CachedPhotoMetadata]
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var flatPhotos: [PhotoFile] = []
            var needsEnrichment = false
            var sidecarManifest: [SidecarCandidate] = []

            var nodes: [ScanFolderNode] = []
            var stack: [(URL, Int?)] = [(rootURL, nil)]

            while !stack.isEmpty {
                let (dirURL, parentIdx) = stack.removeLast()
                let dirName = dirURL.lastPathComponent

                var photos: [PhotoFile] = []
                var subdirs: [URL] = []

                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey]

                let contents: [URL]?
                do {
                    contents = try fm.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                } catch {
                    Log.scan.error("contentsOfDirectory failed for \(dirURL.path): \(error.localizedDescription)")
                    contents = nil
                }

                if let contents {
                    // First pass: classify files and collect metadata.
                    // Photos and videos go into `scannedFiles`; `.xmp` siblings
                    // are tracked separately so the manifest can emit one row
                    // per photo that has a sidecar adjacent to it.
                    var scannedFiles: [ScanFile] = []
                    // Lower-cased basename ("img_1234.heic") → URL of the
                    // sidecar file. digiKam writes sidecars as `<photo>.xmp`
                    // (basename + ".xmp"), so the manifest matches by exact
                    // photo basename.
                    var sidecarsByPhotoBasename: [String: URL] = [:]

                    for itemURL in contents {
                        let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys))
                        let isDir = resourceValues?.isDirectory ?? false

                        if isDir {
                            subdirs.append(itemURL)
                        } else {
                            let ext = itemURL.pathExtension.lowercased()
                            if ext == "xmp" {
                                // Sidecar URL: `IMG.heic.xmp` → key `img.heic`.
                                let key = itemURL.deletingPathExtension().lastPathComponent.lowercased()
                                sidecarsByPhotoBasename[key] = itemURL
                            } else if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
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
                        let dateTaken = cached?.date ?? MetadataReader.earliestFilesystemDate(creation: file.creationDate, modification: file.modDate)
                        let tags = cached?.tags ?? []
                        let cachedEnrichedDate = cached?.enrichedFileDate
                        // Re-enrich if never enriched or file was modified since last enrichment
                        let stale = cachedEnrichedDate == nil || file.modDate != cachedEnrichedDate
                        if stale {
                            needsEnrichment = true
                        }

                        let photoProbe = FileProviderDetector.probe(file.url)
                        let locality: PhotoLocality = photoProbe.isFileProvider
                            ? .remote(downloaded: photoProbe.status == .local)
                            : .local
                        let photoID = PhotoFile.stableID(for: file.url)

                        photos.append(PhotoFile(
                            id: photoID, url: file.url, filename: stem,
                            fileSize: file.fileSize,
                            dateTaken: dateTaken,
                            livePhotoVideoURL: liveURL,
                            hierarchicalTags: tags,
                            countryCode: cached?.countryCode,
                            enrichedFileDate: stale ? nil : cachedEnrichedDate,
                            gpsLatitude: cached?.gpsLatitude,
                            gpsLongitude: cached?.gpsLongitude,
                            faceRegions: cached?.faceRegions ?? [],
                            locality: locality
                        ))

                        // Sidecar manifest row — `<basename>.xmp` (e.g.
                        // `IMG_1234.heic.xmp`).
                        let basenameKey = file.url.lastPathComponent.lowercased()
                        if let sidecarURL = sidecarsByPhotoBasename[basenameKey] {
                            let sidecarProbe = FileProviderDetector.probe(sidecarURL)
                            sidecarManifest.append(SidecarCandidate(
                                photoID: photoID,
                                sidecarURL: sidecarURL,
                                currentVersion: sidecarProbe.version,
                                downloadStatus: sidecarProbe.status
                            ))
                        }
                    }
                    // Standalone videos only (no matching image)
                    var standaloneVideoCount = 0
                    for file in scannedFiles where file.isVideo {
                        let stem = videoStem(file.url)
                        if !imageStemSet.contains(stem) {
                            standaloneVideoCount += 1
                            let cached = cachedMetadata[file.url]
                            let videoProbe = FileProviderDetector.probe(file.url)
                            let locality: PhotoLocality = videoProbe.isFileProvider
                                ? .remote(downloaded: videoProbe.status == .local)
                                : .local
                            photos.append(PhotoFile(
                                id: PhotoFile.stableID(for: file.url), url: file.url, filename: stem,
                                fileSize: file.fileSize,
                                dateTaken: cached?.date ?? MetadataReader.earliestFilesystemDate(creation: file.creationDate, modification: file.modDate),
                                isVideo: true,
                                locality: locality
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
            return Result(
                rootFolder: root,
                flatPhotos: flatPhotos,
                needsEnrichment: needsEnrichment,
                sidecarManifest: sidecarManifest
            )
        }.value
    }
}
