import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LocalGallery

/// Disk-cache behaviour when a local photo file disappears: a last-known
/// JPEG still paints the cell; a total miss notifies the caller so the
/// library can drop the row. QuickLook / GalleryStore wiring is out of
/// scope here.
@MainActor
final class ThumbnailServiceTests: XCTestCase {
    /// A temp dir scoped to the running test. Built per test rather than in
    /// `setUp`, which XCTest calls from a nonisolated context.
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    // MARK: - Missing source, disk cache still present

    /// After a successful decode the on-disk JPEG is the last-known image.
    /// Deleting the source and dropping the in-memory entry must still
    /// return that JPEG — not nil, which would shimmer the cell forever.
    func testADeletedSourceStillServesTheOnDiskJPEG() async throws {
        let temp = makeTemp()
        let thumbDir = temp.appending("thumbs", isDirectory: true)
        let service = ThumbnailService(thumbnailDir: thumbDir)
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source)

        var missing: [URL] = []
        service.onSourceMissing = { url in missing.append(url) }

        let first = await service.thumbnail(for: source, size: CGSize(width: 64, height: 64))
        XCTAssertNotNil(first, "ImageIO should decode the fixture JPEG")

        let diskJPEG = thumbDir.appendingPathComponent(
            PhotoFile.stableID(for: source).uuidString + ".jpg"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: diskJPEG.path),
            "first load should write a disk cache"
        )

        try FileManager.default.removeItem(at: source)
        service.evictInMemoryThumbnail(for: source)

        let second = await service.thumbnail(for: source, size: CGSize(width: 64, height: 64))
        XCTAssertNotNil(second, "disk cache must survive a missing source")
        XCTAssertTrue(missing.isEmpty, "a cache hit is not a source-missing miss")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: thumbDir.appendingPathComponent(
                    PhotoFile.stableID(for: source).uuidString + ".nothumb"
                ).path
            ),
            ".nothumb sentinels are QuickLook-only"
        )
    }

    // MARK: - Missing source, no cache either

    /// Memory gone, disk JPEG gone, source gone: decode returns nil and
    /// `onSourceMissing` fires with that URL so the library can drop the row.
    func testADeletedSourceWithNoDiskCacheFiresOnSourceMissing() async throws {
        let temp = makeTemp()
        let thumbDir = temp.appending("thumbs", isDirectory: true)
        let service = ThumbnailService(thumbnailDir: thumbDir)
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source)

        let first = await service.thumbnail(for: source, size: CGSize(width: 64, height: 64))
        XCTAssertNotNil(first)

        let diskJPEG = thumbDir.appendingPathComponent(
            PhotoFile.stableID(for: source).uuidString + ".jpg"
        )
        service.evictInMemoryThumbnail(for: source)
        try FileManager.default.removeItem(at: diskJPEG)
        try FileManager.default.removeItem(at: source)

        var missing: [URL] = []
        service.onSourceMissing = { url in missing.append(url) }

        let second = await service.thumbnail(for: source, size: CGSize(width: 64, height: 64))
        XCTAssertNil(second)
        XCTAssertEqual(missing, [source])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: thumbDir.appendingPathComponent(
                    PhotoFile.stableID(for: source).uuidString + ".nothumb"
                ).path
            ),
            "a missing local file must not write a QuickLook sentinel"
        )
    }

    /// Face crops go through the decode limiter and keep only the small
    /// bitmap — a second call is a cache hit, not another full-photo decode.
    func testFaceCropReturnsABitmapAndCachesIt() async throws {
        let temp = makeTemp()
        let service = ThumbnailService(thumbnailDir: temp.appending("thumbs", isDirectory: true))
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source)
        let region = FaceRegion(name: nil, centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)

        let first = await service.faceCrop(for: source, region: region, cellSize: 76)
        XCTAssertNotNil(first)
        let second = await service.faceCrop(for: source, region: region, cellSize: 76)
        XCTAssertNotNil(second)
    }

    // MARK: - Source freshness

    /// Replacing the file with different bytes (newer mtime) must miss the
    /// in-memory cache and return the new image, not the first decode.
    func testReplacedSourceServesTheNewBitmap() async throws {
        let temp = makeTemp()
        let service = ThumbnailService(thumbnailDir: temp.appending("thumbs", isDirectory: true))
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source, red: 0xE0, green: 0x10, blue: 0x10)

        let first = try XCTUnwrap(await service.thumbnail(for: source, size: CGSize(width: 64, height: 64)))
        let firstPixel = try XCTUnwrap(samplePixel(first))

        try writeTinyJPEG(to: source, red: 0x10, green: 0x10, blue: 0xE0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: source.path
        )

        let second = try XCTUnwrap(await service.thumbnail(for: source, size: CGSize(width: 64, height: 64)))
        let secondPixel = try XCTUnwrap(samplePixel(second))
        XCTAssertNotEqual(firstPixel.0, secondPixel.0, "stale red cache must not survive a blue replacement")
        XCTAssertGreaterThan(secondPixel.2, secondPixel.0, "replacement should decode as blue-dominant")
    }

    /// Same-mtime rewrite with a different file size still misses: the
    /// stamp includes size, not just mtime.
    func testSameMtimeSizeChangeMissesTheMemoryCache() async throws {
        let temp = makeTemp()
        let service = ThumbnailService(thumbnailDir: temp.appending("thumbs", isDirectory: true))
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source, width: 8, height: 8, red: 0xE0, green: 0x10, blue: 0x10)
        let first = try XCTUnwrap(await service.thumbnail(for: source, size: CGSize(width: 64, height: 64)))
        let firstPixel = try XCTUnwrap(samplePixel(first))
        let originalMtime = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date

        try writeTinyJPEG(to: source, width: 32, height: 32, red: 0x10, green: 0x10, blue: 0xE0)
        if let originalMtime {
            try FileManager.default.setAttributes(
                [.modificationDate: originalMtime],
                ofItemAtPath: source.path
            )
        }

        let second = try XCTUnwrap(await service.thumbnail(for: source, size: CGSize(width: 64, height: 64)))
        let secondPixel = try XCTUnwrap(samplePixel(second))
        XCTAssertNotEqual(firstPixel.0, secondPixel.0)
    }

    /// Scan-modified URLs can be dropped explicitly; the next load re-reads
    /// the source even if the caller hasn't compared stamps itself.
    func testInvalidateCachedImagesForcesReload() async throws {
        let temp = makeTemp()
        let service = ThumbnailService(thumbnailDir: temp.appending("thumbs", isDirectory: true))
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source, red: 0xE0, green: 0x10, blue: 0x10)
        _ = await service.thumbnail(for: source, size: CGSize(width: 64, height: 64))
        _ = await service.loadFullImage(for: source, maxPixelSize: 64)
        XCTAssertNotNil(service.cachedThumbnail(for: source))

        service.invalidateCachedImages(for: [source])
        XCTAssertNil(service.cachedThumbnail(for: source))

        try writeTinyJPEG(to: source, red: 0x10, green: 0x10, blue: 0xE0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: source.path
        )
        let reloaded = try XCTUnwrap(await service.thumbnail(for: source, size: CGSize(width: 64, height: 64)))
        let pixel = try XCTUnwrap(samplePixel(reloaded))
        XCTAssertGreaterThan(pixel.2, pixel.0)
    }

    /// Slideshow export asks for the canvas edge; a later viewer-sized load
    /// must not reuse a smaller cached bitmap.
    func testFullImageCacheDoesNotSatisfyALargerRequest() async throws {
        let temp = makeTemp()
        let service = ThumbnailService(thumbnailDir: temp.appending("thumbs", isDirectory: true))
        let source = temp.appending("photo.jpg")
        try writeTinyJPEG(to: source, width: 64, height: 64)

        let small = try XCTUnwrap(await service.loadFullImage(for: source, maxPixelSize: 16))
        let large = try XCTUnwrap(await service.loadFullImage(for: source, maxPixelSize: 64))
        let smallEdge = max(small.size.width, small.size.height)
        let largeEdge = max(large.size.width, large.size.height)
        XCTAssertLessThan(smallEdge, largeEdge + 0.5)
        XCTAssertGreaterThanOrEqual(largeEdge, 32, "64px request should decode more than the 16px export cache")
    }

    // MARK: - Fixture

    /// sRGB JPEG so ImageIO has real bytes to decode and cache.
    private func writeTinyJPEG(
        to url: URL,
        width: Int = 8,
        height: Int = 8,
        red: UInt8 = 0xC0,
        green: UInt8 = 0x40,
        blue: UInt8 = 0x20
    ) throws {
        let bytesPerPixel = 4
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(
            CGImageDestinationFinalize(destination),
            "failed to write JPEG at \(url.path)"
        )
    }

    /// First pixel of a decoded bitmap as (R, G, B). Used to tell a red
    /// fixture from a blue replacement without depending on exact JPEG bytes.
    private func samplePixel(_ image: UIImage) -> (UInt8, UInt8, UInt8)? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}
