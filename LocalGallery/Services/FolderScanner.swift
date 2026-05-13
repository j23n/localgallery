import Foundation
import UniformTypeIdentifiers
import os

/// Iterative folder traversal that produces a `PhotoFolder` tree + flat
/// `[PhotoFile]` from a security-scoped root URL. The Store passes in a
/// snapshot of the previous scan so this stays a pure detached-task
/// operation — `@Observable` state assignment, cache save, and enrichment
/// scheduling stay on the Store side.
///
/// Two modes:
///   - **Full** (`reuseCached: false`): probe every file, rebuild every
///     `PhotoFile` from scratch. Old metadata is merged from `cachedPhotos`
///     so EXIF reads can short-circuit, but the FileProvider probe + stat
///     run for every photo. ~3 min for ~25k photos.
///   - **Light** (`reuseCached: true`): for any file whose URL + size +
///     modDate match the cached entry, reuse the cached `PhotoFile` as-is
///     (no probe, no enrichment trigger). New / changed / removed URLs
///     surface in the result so the Store can update state and enrich just
///     those. Walks the tree fully, but the per-file cost is one stat
///     instead of stat + FileProvider probe + EXIF.
enum FolderScanner {
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
        /// URLs present in the scan but not in `cachedPhotos`.
        let addedURLs: [URL]
        /// URLs present in `cachedPhotos` but absent from the scan.
        let removedURLs: [URL]
        /// URLs whose `fileSize` or `fileModificationDate` changed since the
        /// cache. Disjoint from `addedURLs`.
        let modifiedURLs: [URL]
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
    /// detached background task.
    ///
    /// - Parameters:
    ///   - rootURL: The security-scoped folder.
    ///   - cachedPhotos: URL → previous-scan `PhotoFile`. Carries forward
    ///     EXIF / tags / GPS / locality.
    ///   - reuseCached: When true, files whose `(fileSize, modDate)` match
    ///     `cachedPhotos[url]` are reused without probing. When false,
    ///     every file is re-probed (the cached entry is still used as a
    ///     fast path for EXIF / tags so enrichment can short-circuit).
    ///   - onProgress: Optional callback invoked from the detached task as
    ///     photos are discovered. Receives the cumulative count. Called
    ///     after every batch of files for throughput; safe to hop to the
    ///     main actor inside.
    static func scan(
        at rootURL: URL,
        cachedPhotos: [URL: PhotoFile] = [:],
        reuseCached: Bool = false,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var flatPhotos: [PhotoFile] = []
            var needsEnrichment = false
            var sidecarManifest: [SidecarCandidate] = []
            var addedURLs: [URL] = []
            var modifiedURLs: [URL] = []
            var seenURLs: Set<URL> = []
            // Throttle progress callbacks — fire every 100 files so the
            // main-actor hops don't dominate the walk.
            var progressTick = 0

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
                        seenURLs.insert(file.url)
                        let stem = file.url.deletingPathExtension().lastPathComponent
                        let liveURL = videoByName[stem.lowercased()]
                        if liveURL != nil { pairedCount += 1 }

                        let cached = cachedPhotos[file.url]
                        let unchanged = cached.map { c in
                            c.fileSize == file.fileSize && c.fileModificationDate == file.modDate
                        } ?? false

                        let photo: PhotoFile
                        if reuseCached, let cached, unchanged {
                            // Fast path: reuse the cached PhotoFile verbatim,
                            // only updating the live-photo pairing (which can
                            // change without the photo's own bytes changing)
                            // and the filename-derived stem field.
                            var p = cached
                            p.filename = stem
                            p.livePhotoVideoURL = liveURL
                            photo = p
                        } else {
                            // Slow path: probe + (re)build the PhotoFile. Also
                            // taken when the file's bytes changed since the
                            // last scan — `enrichedFileDate` is cleared so
                            // enrichment re-reads its EXIF.
                            // Prefer cached EXIF date; fall back to earliest filesystem date.
                            // creationDate = when the file appeared on THIS volume (e.g. download time);
                            // modDate = sometimes preserved from the original file (AirDrop, chat saves).
                            // min() picks the one closer to the actual photo date.
                            let dateTaken = (unchanged ? cached?.dateTaken : nil)
                                ?? MetadataReader.earliestFilesystemDate(creation: file.creationDate, modification: file.modDate)
                            let tags = unchanged ? (cached?.hierarchicalTags ?? []) : []
                            let cachedEnrichedDate = cached?.enrichedFileDate
                            // Re-enrich if never enriched or file was modified since last enrichment.
                            let stale = !unchanged || cachedEnrichedDate == nil || file.modDate != cachedEnrichedDate
                            if stale {
                                needsEnrichment = true
                            }

                            let photoProbe = FileProviderDetector.probe(file.url)
                            let locality: PhotoLocality = photoProbe.isFileProvider
                                ? .remote(downloaded: photoProbe.status == .local)
                                : .local
                            let photoID = PhotoFile.stableID(for: file.url)

                            photo = PhotoFile(
                                id: photoID, url: file.url, filename: stem,
                                fileSize: file.fileSize,
                                dateTaken: dateTaken,
                                livePhotoVideoURL: liveURL,
                                hierarchicalTags: tags,
                                countryCode: unchanged ? cached?.countryCode : nil,
                                enrichedFileDate: stale ? nil : cachedEnrichedDate,
                                fileModificationDate: file.modDate,
                                gpsLatitude: unchanged ? cached?.gpsLatitude : nil,
                                gpsLongitude: unchanged ? cached?.gpsLongitude : nil,
                                faceRegions: unchanged ? (cached?.faceRegions ?? []) : [],
                                locality: locality
                            )
                        }
                        photos.append(photo)

                        if cached == nil {
                            addedURLs.append(file.url)
                            needsEnrichment = true
                        } else if !unchanged {
                            modifiedURLs.append(file.url)
                            needsEnrichment = true
                        }

                        // Sidecar manifest row — `<basename>.xmp` (e.g.
                        // `IMG_1234.heic.xmp`).
                        let basenameKey = file.url.lastPathComponent.lowercased()
                        if let sidecarURL = sidecarsByPhotoBasename[basenameKey] {
                            let sidecarProbe = FileProviderDetector.probe(sidecarURL)
                            sidecarManifest.append(SidecarCandidate(
                                photoID: photo.id,
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
                            seenURLs.insert(file.url)
                            let cached = cachedPhotos[file.url]
                            let unchanged = cached.map { c in
                                c.fileSize == file.fileSize && c.fileModificationDate == file.modDate
                            } ?? false

                            let photo: PhotoFile
                            if reuseCached, let cached, unchanged {
                                var p = cached
                                p.filename = stem
                                photo = p
                            } else {
                                let dateTaken = (unchanged ? cached?.dateTaken : nil)
                                    ?? MetadataReader.earliestFilesystemDate(creation: file.creationDate, modification: file.modDate)
                                let cachedEnrichedDate = cached?.enrichedFileDate
                                let stale = !unchanged || cachedEnrichedDate == nil || file.modDate != cachedEnrichedDate
                                if stale { needsEnrichment = true }
                                let videoProbe = FileProviderDetector.probe(file.url)
                                let locality: PhotoLocality = videoProbe.isFileProvider
                                    ? .remote(downloaded: videoProbe.status == .local)
                                    : .local
                                photo = PhotoFile(
                                    id: PhotoFile.stableID(for: file.url), url: file.url, filename: stem,
                                    fileSize: file.fileSize,
                                    dateTaken: dateTaken,
                                    isVideo: true,
                                    hierarchicalTags: unchanged ? (cached?.hierarchicalTags ?? []) : [],
                                    countryCode: unchanged ? cached?.countryCode : nil,
                                    enrichedFileDate: stale ? nil : cachedEnrichedDate,
                                    fileModificationDate: file.modDate,
                                    gpsLatitude: unchanged ? cached?.gpsLatitude : nil,
                                    gpsLongitude: unchanged ? cached?.gpsLongitude : nil,
                                    faceRegions: unchanged ? (cached?.faceRegions ?? []) : [],
                                    locality: locality
                                )
                            }
                            photos.append(photo)
                            if cached == nil {
                                addedURLs.append(file.url)
                                needsEnrichment = true
                            } else if !unchanged {
                                modifiedURLs.append(file.url)
                                needsEnrichment = true
                            }
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
                progressTick += photos.count
                if progressTick >= 100, let onProgress {
                    onProgress(flatPhotos.count)
                    progressTick = 0
                }

                let sortedSubdirs = subdirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                for subdir in sortedSubdirs {
                    stack.append((subdir, nodeIndex))
                }
            }

            // Final progress flush so the UI ends on the true total.
            if let onProgress { onProgress(flatPhotos.count) }

            // Anything in the cache that didn't appear in the listing was
            // moved/removed/unmounted between scans. The Store drops them
            // from `allPhotos` so the grid reflects the change immediately.
            var removedURLs: [URL] = []
            for url in cachedPhotos.keys where !seenURLs.contains(url) {
                removedURLs.append(url)
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
                sidecarManifest: sidecarManifest,
                addedURLs: addedURLs,
                removedURLs: removedURLs,
                modifiedURLs: modifiedURLs
            )
        }.value
    }
}
