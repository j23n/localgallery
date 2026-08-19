import CoreGraphics
import Foundation
import ImageIO
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

    // MARK: - Fixture

    /// 8×8 sRGB JPEG so ImageIO has real bytes to decode and cache.
    private func writeTinyJPEG(to url: URL) throws {
        let width = 8
        let height = 8
        let bytesPerPixel = 4
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xC0
            pixels[i + 1] = 0x40
            pixels[i + 2] = 0x20
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
}
