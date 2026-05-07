import Foundation
import UIKit
import ImageIO
import AVFoundation
import QuickLookThumbnailing
import os

// MARK: - Decode concurrency limiter

/// Async counting semaphore — gates concurrent ImageIO / AVAsset thumbnail
/// decodes so fast scrolling doesn't exhaust the IOSurface pool (the
/// `CMPhotoJFIFUtilities -17102` / `IOSurface creation failed` errors).
private actor DecodeLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            active -= 1
        }
    }
}

/// File-level instance — `Sendable` because actors are always `Sendable`.
private let decodeLimiter = DecodeLimiter(limit: 4)

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

    private let thumbnailDiskCacheDir: URL

    static var defaultDiskCacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
    }

    init(thumbnailDir: URL = ThumbnailService.defaultDiskCacheDir) {
        self.thumbnailDiskCacheDir = thumbnailDir
        try? FileManager.default.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
        thumbnailCache.totalCostLimit = 100 * 1024 * 1024
        fullImageCache.totalCostLimit = 200 * 1024 * 1024
    }

    /// Sync hit on the in-memory cache. Returns nil on miss without touching
    /// disk — used by the viewer to populate an initial bitmap before the
    /// async path loads at full size.
    func cachedThumbnail(for url: URL) -> UIImage? {
        thumbnailCache.object(forKey: url as NSURL)
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
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            return cached
        }

        let maxPixelSize = max(size.width, size.height) * UIScreen.main.scale
        let stableID = PhotoFile.stableID(for: url).uuidString
        let diskPath = thumbnailDiskCacheDir.appendingPathComponent(stableID + ".jpg")
        let sentinelPath = thumbnailDiskCacheDir.appendingPathComponent(stableID + ".nothumb")

        // Sentinel: provider didn't vend a thumbnail on a previous attempt.
        // Skip the generator entirely so a 50k-photo cloud library doesn't
        // burn battery re-asking on every scroll.
        if FileManager.default.fileExists(atPath: sentinelPath.path) {
            return nil
        }

        do {
            let image = try await Self.loadThumbnail(
                for: url, maxPixelSize: maxPixelSize, isVideo: isVideo,
                useQuickLook: useQuickLook,
                size: size,
                diskPath: diskPath, sentinelPath: sentinelPath
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
        if FileManager.default.fileExists(atPath: diskPath.path) {
            let sourceModDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let cacheModDate = (try? diskPath.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // For placeholder files we trust the disk cache regardless of
            // mod-date — reading the source's mtime might be a metadata-only
            // call but the source itself has no bytes to compare against.
            // Cache wins as long as it exists.
            if useQuickLook {
                if let source = CGImageSourceCreateWithURL(diskPath as CFURL, nil),
                   let cgImage = CGImageSourceCreateImageAtIndex(
                       source, 0,
                       [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                   ) {
                    return UIImage(cgImage: cgImage)
                }
            } else if let src = sourceModDate, let cache = cacheModDate, cache >= src,
               let source = CGImageSourceCreateWithURL(diskPath as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(
                   source, 0,
                   [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
               ) {
                return UIImage(cgImage: cgImage)
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
        }
        return UIImage(cgImage: cgImage)
    }

    /// JPEG-encode a CGImage after flattening onto an opaque bitmap — avoids
    /// the `writeImageAtIndex: trying to save an opaque image with
    /// AlphaPremulLast` warning emitted by `UIImage.jpegData` when the source
    /// has an alpha channel.
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
        // 2000px is sharp on phone screens, much faster to decode than 3600px.
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
