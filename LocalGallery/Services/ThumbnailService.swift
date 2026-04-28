import Foundation
import UIKit
import ImageIO
import AVFoundation
import os

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

    private let thumbnailDiskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
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
    func thumbnail(for url: URL, size: CGSize, isVideo: Bool = false) async -> UIImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            return cached
        }

        let maxPixelSize = max(size.width, size.height) * UIScreen.main.scale
        let diskPath = thumbnailDiskCacheDir.appendingPathComponent(
            PhotoFile.stableID(for: url).uuidString + ".jpg"
        )

        do {
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

    /// Generates or loads a thumbnail — `nonisolated` for cooperative pool
    /// execution with cancellation support.
    private nonisolated static func loadThumbnail(
        for url: URL, maxPixelSize: CGFloat, isVideo: Bool, diskPath: URL
    ) async throws -> UIImage? {
        try Task.checkCancellation()

        // Try disk cache first (compare modification dates).
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

            // Write to disk cache (fire-and-forget).
            if let jpegData = opaqueJPEGData(from: cgImage, quality: 0.7) {
                try? jpegData.write(to: diskPath, options: .atomic)
            }
            return UIImage(cgImage: cgImage)
        }
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
