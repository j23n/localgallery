import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import QuickLookThumbnailing
import os

// MARK: - Decode concurrency limiter

/// Gates concurrent ImageIO / AVAsset thumbnail decodes so fast scrolling
/// doesn't exhaust the IOSurface pool (the `CMPhotoJFIFUtilities -17102` /
/// `IOSurface creation failed` errors). File-level instance — `Sendable`
/// because actors are always `Sendable`.
private let decodeLimiter = AsyncSemaphore(limit: 4)

/// Owns the in-memory and on-disk thumbnail caches plus the full-resolution
/// image cache used by the viewer/slideshow. Generation runs on detached
/// tasks via `nonisolated static` helpers so cooperative cancellation works
/// across a scrolling grid (rapid Task spawn/cancel pairs).
///
/// `NSCache` itself is thread-safe; gating access through this `@MainActor`
/// type just preserves the existing call shape from the views.
@MainActor
final class ThumbnailService {
    private let thumbnailCache = NSCache<NSURL, UIImage>()
    private let fullImageCache = NSCache<NSURL, UIImage>()
    /// Cropped face cells. Keyed by path + region + cell size + source stamp,
    /// not by photo — two faces in one group shot must not share a bitmap.
    private let faceCropCache = NSCache<NSString, UIImage>()

    /// Source identity recorded when an in-memory thumbnail was stored.
    /// Lookups compare this to the live size/mtime (or content identifier)
    /// so a replaced file doesn't keep painting the old JPEG.
    private var thumbnailStamps: [NSURL: FileProviderDetector.ContentVersion] = [:]
    private var fullImageStamps: [NSURL: FileProviderDetector.ContentVersion] = [:]
    /// Pixel-size of the bitmap sitting in `fullImageCache` for that URL.
    /// A 1080 export must not satisfy a later 2000 viewer load.
    private var fullImagePixelSizes: [NSURL: CGFloat] = [:]
    /// Face-crop cache keys per source URL, so scan-modified invalidation
    /// can drop every region/size variant without enumerating `NSCache`.
    private var faceCropKeysByURL: [URL: Set<NSString>] = [:]

    private let thumbnailDiskCacheDir: URL

    /// How long a `.nothumb` negative-cache sentinel suppresses QuickLook
    /// retries before the provider gets asked again.
    private static let sentinelTTL: TimeInterval = 24 * 60 * 60

    /// Called when a local (non-QuickLook) load needed the source file and
    /// it was gone. Not fired for placeholder misses or cancellation.
    /// The caller coalesces these; firing once per failed cell load is
    /// enough. The service is `@MainActor`, so the callback runs there.
    var onSourceMissing: (@MainActor (URL) -> Void)?

    /// No default — the directory comes from `GalleryPaths` (via the Store)
    /// so a missed injection can't silently write to production paths in
    /// tests.
    init(thumbnailDir: URL) {
        self.thumbnailDiskCacheDir = thumbnailDir
        try? FileManager.default.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
        thumbnailCache.totalCostLimit = 100 * 1024 * 1024
        fullImageCache.totalCostLimit = 200 * 1024 * 1024
        faceCropCache.totalCostLimit = 40 * 1024 * 1024
    }

    /// Sync hit on the in-memory cache. Returns nil on miss without touching
    /// disk — used by the viewer to populate an initial bitmap before the
    /// async path loads at full size.
    func cachedThumbnail(for url: URL) -> UIImage? {
        let key = url as NSURL
        guard let image = thumbnailCache.object(forKey: key) else { return nil }
        guard isFresh(url, stamp: thumbnailStamps[key]) else {
            evictInMemoryThumbnail(for: url)
            return nil
        }
        return image
    }

    /// Async load: memory cache → disk cache → ImageIO/AVAsset generation.
    /// Caches the result back into the memory cache on hit.
    ///
    /// `useQuickLook` switches the decode strategy: when true (i.e. the photo
    /// is a non-downloaded file-provider placeholder), generation goes through
    /// `QLThumbnailGenerator` which transparently uses provider-vended
    /// thumbnails. Once a thumbnail has been written to the on-disk cache it
    /// survives the source's eviction, so subsequent grid scrolls don't have
    /// to re-fetch.
    func thumbnail(for url: URL, size: CGSize, isVideo: Bool = false, useQuickLook: Bool = false) async -> UIImage? {
        if let cached = cachedThumbnail(for: url) {
            return cached
        }

        let maxPixelSize = max(size.width, size.height) * UIScreen.main.scale
        let stableID = PhotoFile.stableID(for: url).uuidString
        let diskPath = thumbnailDiskCacheDir.appendingPathComponent(stableID + ".jpg")
        let sentinelPath = thumbnailDiskCacheDir.appendingPathComponent(stableID + ".nothumb")

        // Sentinel: provider didn't vend a thumbnail on a previous attempt.
        // Skip the generator so a 50k-photo cloud library doesn't burn battery
        // re-asking on every scroll. Only honoured for placeholder decodes —
        // once the file is downloaded the ImageIO path can succeed, so a
        // stale negative result must not blank the cell. Sentinels also
        // expire after `sentinelTTL`: the original failure may have been
        // transient (provider timeout, rate limit).
        if useQuickLook {
            if let written = (try? sentinelPath.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if Date().timeIntervalSince(written) < Self.sentinelTTL {
                    return nil
                }
                try? FileManager.default.removeItem(at: sentinelPath)
            }
        } else {
            // Locality flipped to local: drop any placeholder-era sentinel.
            try? FileManager.default.removeItem(at: sentinelPath)
        }

        do {
            let image = try await Self.loadThumbnail(
                for: url, maxPixelSize: maxPixelSize, isVideo: isVideo,
                useQuickLook: useQuickLook,
                size: size,
                diskPath: diskPath, sentinelPath: sentinelPath
            )
            guard let image else {
                notifyIfSourceMissing(url, useQuickLook: useQuickLook)
                return nil
            }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            let key = url as NSURL
            thumbnailStamps[key] = Self.sourceStamp(for: url)
            thumbnailCache.setObject(image, forKey: key, cost: cost)
            return image
        } catch is CancellationError {
            Log.thumb.debug("Cancelled: \(Log.r.filename(url.lastPathComponent))")
            return nil
        } catch {
            notifyIfSourceMissing(url, useQuickLook: useQuickLook)
            return nil
        }
    }

    /// Local cells that fail because the photo file is gone — not a
    /// QuickLook miss, not a cancelled in-flight load.
    private func notifyIfSourceMissing(_ url: URL, useQuickLook: Bool) {
        guard !useQuickLook, !FileManager.default.fileExists(atPath: url.path) else { return }
        onSourceMissing?(url)
    }

    /// Drops the in-memory entry for `url` without touching the on-disk JPEG.
    /// Tests use this to force a disk-cache hit after the source file is gone.
    func evictInMemoryThumbnail(for url: URL) {
        let key = url as NSURL
        thumbnailCache.removeObject(forKey: key)
        thumbnailStamps.removeValue(forKey: key)
    }

    /// Drops in-memory thumbnails, full images, and face crops for URLs the
    /// scanner reported as modified. Disk JPEGs stay; the next load compares
    /// size/mtime and regenerates when the source is newer.
    func invalidateCachedImages(for urls: [URL]) {
        for url in urls {
            evictInMemoryThumbnail(for: url)
            let key = url as NSURL
            fullImageCache.removeObject(forKey: key)
            fullImageStamps.removeValue(forKey: key)
            fullImagePixelSizes.removeValue(forKey: key)
            if let keys = faceCropKeysByURL.removeValue(forKey: url) {
                for cropKey in keys {
                    faceCropCache.removeObject(forKey: cropKey)
                }
            }
        }
    }

    /// Generates or loads a thumbnail — `nonisolated` for cooperative pool
    /// execution with cancellation support.
    private nonisolated static func loadThumbnail(
        for url: URL, maxPixelSize: CGFloat, isVideo: Bool,
        useQuickLook: Bool, size: CGSize,
        diskPath: URL, sentinelPath: URL
    ) async throws -> UIImage? {
        try Task.checkCancellation()

        // Try disk cache first (compare modification dates).
        // Load via ImageIO with ShouldCacheImmediately so the returned
        // UIImage has decoded pixel data. UIImage(data:) would create a
        // *lazy* image whose JPEG decode is deferred to the render pipeline,
        // where it runs unbounded and exhausts the IOSurface pool during
        // fast scrolling (the CMPhotoJFIFUtilities -17102 cascade).
        //
        // If the source file has disappeared, still serve the on-disk JPEG
        // as a last-known image rather than falling through to ImageIO on
        // a missing path (that returns nil and the cell shimmers forever).
        if FileManager.default.fileExists(atPath: diskPath.path) {
            // For placeholder files we trust the disk cache regardless of
            // mod-date — reading the source's mtime might be a metadata-only
            // call but the source itself has no bytes to compare against.
            // Cache wins as long as it exists.
            if useQuickLook {
                if let image = loadDiskCachedJPEG(at: diskPath) {
                    return image
                }
            } else if sourceFileIsMissing(url) {
                if let image = loadDiskCachedJPEG(at: diskPath) {
                    return image
                }
            } else {
                if diskStampMatchesSource(diskPath: diskPath, source: url),
                   let image = loadDiskCachedJPEG(at: diskPath) {
                    return image
                }
            }
        }

        try Task.checkCancellation()

        // Gate the expensive decode — at most `decodeLimiter.limit`
        // concurrent ImageIO / AVAsset operations to avoid IOSurface
        // exhaustion during fast scrolling.
        await decodeLimiter.acquire()

        do {
            try Task.checkCancellation()
            let result: UIImage?
            if useQuickLook {
                result = try await decodeQuickLook(
                    url: url, size: size, diskPath: diskPath, sentinelPath: sentinelPath
                )
            } else if isVideo {
                result = try await decodeVideo(url: url, maxPixelSize: maxPixelSize, diskPath: diskPath)
            } else {
                result = try await decodeImage(url: url, maxPixelSize: maxPixelSize, diskPath: diskPath)
            }
            await decodeLimiter.release()
            return result
        } catch {
            await decodeLimiter.release()
            throw error
        }
    }

    /// Decode a cached JPEG with `ShouldCacheImmediately` so the UIImage
    /// carries decoded pixels (see the disk-cache branch in `loadThumbnail`).
    private nonisolated static func loadDiskCachedJPEG(at diskPath: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(diskPath as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                  source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// True when the original photo is gone (or the filesystem reports it
    /// as not found). A last-known on-disk JPEG is then the best we can show.
    private nonisolated static func sourceFileIsMissing(_ url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        do {
            _ = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isReadableKey,
            ])
            return false
        } catch {
            return isNotFoundError(error)
        }
    }

    /// Cheap size/mtime/content-identifier read — the same keys
    /// `FileProviderDetector.sizeKeys` uses, without the ubiquitous probe.
    nonisolated static func sourceStamp(for url: URL) -> FileProviderDetector.ContentVersion {
        let values = try? url.resourceValues(forKeys: [
            .fileContentIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        return FileProviderDetector.ContentVersion(
            contentIdentifier: values?.fileContentIdentifier.map(String.init),
            modificationDate: values?.contentModificationDate,
            size: values?.fileSize.map(Int64.init)
        )
    }

    /// True when the cached bitmap still matches the live file. A missing
    /// source keeps the last-known image (same contract as the disk JPEG).
    private func isFresh(_ url: URL, stamp: FileProviderDetector.ContentVersion?) -> Bool {
        guard let stamp else { return false }
        if Self.sourceFileIsMissing(url) { return true }
        return FileProviderDetector.ContentVersion.sameContent(stamp, Self.sourceStamp(for: url))
    }

    private nonisolated static func stampURL(nextTo diskPath: URL) -> URL {
        diskPath.deletingPathExtension().appendingPathExtension("stamp")
    }

    private nonisolated static func writeDiskStamp(
        _ stamp: FileProviderDetector.ContentVersion, nextTo diskPath: URL
    ) {
        let size = stamp.size.map(String.init) ?? ""
        // Milliseconds avoid Date equality failing after a Double string round-trip.
        let mtime = stamp.modificationDate.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? ""
        let id = stamp.contentIdentifier ?? ""
        try? "\(size)|\(mtime)|\(id)".data(using: .utf8)?.write(
            to: stampURL(nextTo: diskPath), options: .atomic
        )
    }

    /// Disk JPEG is reusable when its sibling stamp matches the live source
    /// (size + mtime + content identifier). Legacy JPEGs without a stamp
    /// fall back to cache-mtime >= source-mtime.
    private nonisolated static func diskStampMatchesSource(diskPath: URL, source: URL) -> Bool {
        let stampPath = stampURL(nextTo: diskPath)
        if let data = try? Data(contentsOf: stampPath),
           let text = String(data: data, encoding: .utf8) {
            let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let size = parts.first.flatMap { Int64($0) }
            let storedMs = parts.count > 1 ? Int64(parts[1]) : nil
            let contentID = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let live = sourceStamp(for: source)
            if let l = contentID, let r = live.contentIdentifier {
                return l == r
            }
            let liveMs = live.modificationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            return size == live.size && storedMs == liveMs
        }
        let sourceModDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let cacheModDate = (try? diskPath.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let src = sourceModDate, let cache = cacheModDate {
            return cache >= src
        }
        return false
    }

    private nonisolated static func isNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        return false
    }

    /// Generate a thumbnail for a non-downloaded file-provider placeholder via
    /// `QLThumbnailGenerator`. QL transparently uses provider-vended
    /// thumbnails when the underlying bytes haven't been fetched. On failure
    /// (no thumb vended), writes a sentinel so subsequent calls can short-circuit.
    private nonisolated static func decodeQuickLook(
        url: URL, size: CGSize, diskPath: URL, sentinelPath: URL
    ) async throws -> UIImage? {
        try Task.checkCancellation()
        let scale = await MainActor.run { UIScreen.main.scale }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale,
            representationTypes: .thumbnail
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            try Task.checkCancellation()
            let cgImage = rep.cgImage
            if let jpegData = opaqueJPEGData(from: cgImage, quality: 0.7) {
                try? jpegData.write(to: diskPath, options: .atomic)
                writeDiskStamp(sourceStamp(for: url), nextTo: diskPath)
            }
            return rep.uiImage
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Provider didn't vend a thumbnail. Drop a sentinel so we don't
            // ask again on every scroll.
            try? Data().write(to: sentinelPath, options: .atomic)
            return nil
        }
    }

    // MARK: - Decode helpers (run inside the concurrency gate)

    private nonisolated static func decodeVideo(
        url: URL, maxPixelSize: CGFloat, diskPath: URL
    ) async throws -> UIImage? {
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
            writeDiskStamp(sourceStamp(for: url), nextTo: diskPath)
        }
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func decodeImage(
        url: URL, maxPixelSize: CGFloat, diskPath: URL
    ) async throws -> UIImage? {
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
        if let jpegData = opaqueJPEGData(from: cgImage, quality: 0.7) {
            try? jpegData.write(to: diskPath, options: .atomic)
            writeDiskStamp(sourceStamp(for: url), nextTo: diskPath)
        }
        return UIImage(cgImage: cgImage)
    }

    /// ImageIO thumbnail at `maxPixelSize`, no disk write. Used for face
    /// crops so the grid JPEG cache stays at cell size.
    private nonisolated static func decodeImagePixels(
        url: URL, maxPixelSize: CGFloat
    ) async throws -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        try Task.checkCancellation()
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        try Task.checkCancellation()
        return UIImage(cgImage: cgImage)
    }

    /// JPEG-encode a CGImage directly via `CGImageDestination`. The previous
    /// implementation routed through `UIGraphicsImageRenderer` to flatten any
    /// alpha channel, but `UIGraphicsImageRendererFormat()`'s default init
    /// reads `UIScreen.main.scale` / `UITraitCollection.current.displayScale`
    /// — both main-thread-asserting on iOS 26 — and this helper runs from
    /// `nonisolated static` thumbnail-decode paths on the cooperative pool.
    /// Off-main entry would trip `_dispatch_assert_queue_fail` and crash.
    ///
    /// CGImageSource thumbnails come back tagged `premultipliedLast`, so we
    /// flatten to an opaque bitmap via `opaqueCopy()` before handing the image
    /// to the destination — otherwise ImageIO logs a "trying to save an opaque
    /// image with 'AlphaPremulLast' … ignoring alpha" warning on every write.
    private nonisolated static func opaqueJPEGData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage.opaqueCopy(), props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
        fullImageCache.removeAllObjects()
        faceCropCache.removeAllObjects()
        thumbnailStamps.removeAll()
        fullImageStamps.removeAll()
        fullImagePixelSizes.removeAll()
        faceCropKeysByURL.removeAll()
        try? FileManager.default.removeItem(at: thumbnailDiskCacheDir)
        try? FileManager.default.createDirectory(at: thumbnailDiskCacheDir, withIntermediateDirectories: true)
        Log.thumb.info("Thumbnail cache cleared")
    }

    /// A face-sized crop for a review cell. Decodes through the same limiter
    /// as grid thumbnails, crops, then drops the source so a 300-face grid
    /// never holds 300 viewer-sized bitmaps.
    func faceCrop(for url: URL, region: FaceRegion, cellSize: CGFloat) async -> UIImage? {
        let stamp = Self.sourceStamp(for: url)
        let key = Self.faceCropKey(url: url, region: region, cellSize: cellSize, stamp: stamp)
        if let cached = faceCropCache.object(forKey: key) {
            return cached
        }
        let maxPixelSize = PersonThumbnailView.sourcePixelSize(
            cellSize: cellSize,
            region: region,
            scale: UIScreen.main.scale
        )
        do {
            await decodeLimiter.acquire()
            try Task.checkCancellation()
            let source = try await Self.decodeImagePixels(url: url, maxPixelSize: maxPixelSize)
            await decodeLimiter.release()
            guard let source else { return nil }
            let cropped = PersonThumbnailView.crop(source, to: region)
            let cost = cropped.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            faceCropCache.setObject(cropped, forKey: key, cost: cost)
            faceCropKeysByURL[url, default: []].insert(key)
            return cropped
        } catch is CancellationError {
            await decodeLimiter.release()
            return nil
        } catch {
            await decodeLimiter.release()
            return nil
        }
    }

    private static func faceCropKey(
        url: URL, region: FaceRegion, cellSize: CGFloat,
        stamp: FileProviderDetector.ContentVersion
    ) -> NSString {
        let stampPart = "\(stamp.contentIdentifier ?? "")|\(stamp.size ?? 0)|\(stamp.modificationDate?.timeIntervalSince1970 ?? 0)"
        return "\(url.path)#\(region.centerX),\(region.centerY),\(region.width),\(region.height)#\(Int(cellSize.rounded()))#\(stampPart)" as NSString
    }

    // MARK: - Full Resolution

    func loadFullImage(for url: URL, maxPixelSize: CGFloat = 2000) async -> UIImage? {
        let key = url as NSURL
        if let cached = fullImageCache.object(forKey: key),
           let cachedSize = fullImagePixelSizes[key],
           cachedSize >= maxPixelSize,
           isFresh(url, stamp: fullImageStamps[key]) {
            return cached
        }
        do {
            guard let image = try await Self.generateFullImage(for: url, maxPixelSize: maxPixelSize) else { return nil }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            fullImageCache.setObject(image, forKey: key, cost: cost)
            fullImagePixelSizes[key] = maxPixelSize
            fullImageStamps[key] = Self.sourceStamp(for: url)
            return image
        } catch is CancellationError {
            Log.thumb.debug("Cancelled full image: \(Log.r.filename(url.lastPathComponent))")
            return nil
        } catch {
            return nil
        }
    }

    private nonisolated static func generateFullImage(for url: URL, maxPixelSize: CGFloat) async throws -> UIImage? {
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        try Task.checkCancellation()
        // 2000px is sharp on phone screens, much faster to decode than 3600px.
        // Slideshow export passes the requested canvas edge so we don't decode
        // a 2000px bitmap only to scale it down to 1080.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        try Task.checkCancellation()
        return UIImage(cgImage: cgImage)
    }
}
