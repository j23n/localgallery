import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import LocalGallery

/// Decode-window and cancellation behaviour for slideshow export. Full MP4
/// encode is out of scope here — `streamFrames` is the same window `render`
/// uses, without AVAssetWriter.
final class SlideshowVideoRendererTests: XCTestCase {

    /// 75 photos must never decode more than current+next at once, and the
    /// loader must see the requested canvas (not a discarded `_` size).
    func testSeventyFivePhotosKeepATwoFrameWindow() async throws {
        let canvas = CGSize(width: 48, height: 32)
        let photos = (0..<75).map { i in
            PhotoFile.fixture(url: URL(fileURLWithPath: "/slideshow/\(i).jpg"))
        }

        let stats = LoadStats()
        let image = try XCTUnwrap(solidImage(color: .red, size: CGSize(width: 8, height: 8)))

        SlideshowVideoRenderer.RetentionMetrics.reset()
        try await SlideshowVideoRenderer.streamFrames(
            photos: photos,
            canvas: canvas,
            loadImage: { _, size in
                stats.beginLoad(size: size)
                defer { stats.endLoad() }
                return image
            }
        ) { _, next in
            stats.recordVisit(hasNext: next != nil)
            XCTAssertLessThanOrEqual(
                SlideshowVideoRenderer.RetentionMetrics.currentRetained,
                2,
                "stream window is current + optional next"
            )
        }

        XCTAssertEqual(stats.visitPairs, 75)
        XCTAssertEqual(stats.nextNonNil, 74, "every photo but the last has a next frame for crossfade")
        XCTAssertEqual(stats.requestedSizes.count, 75)
        XCTAssertTrue(stats.requestedSizes.allSatisfy { $0 == canvas }, "caller-requested canvas must reach the loader")
        XCTAssertEqual(stats.maxInflight, 1, "loads are sequential; at most one decode in flight")
        XCTAssertLessThanOrEqual(SlideshowVideoRenderer.RetentionMetrics.maxRetainedImages, 2)
        XCTAssertEqual(SlideshowVideoRenderer.RetentionMetrics.currentRetained, 0)
    }

    func testFailedLoadsAreSkippedAndCrossfadeUsesTheNextDecodable() async throws {
        let photos = (0..<4).map { i in
            PhotoFile.fixture(url: URL(fileURLWithPath: "/slideshow/skip-\(i).jpg"))
        }
        let image = try XCTUnwrap(solidImage(color: .green, size: CGSize(width: 4, height: 4)))
        let stats = LoadStats()

        try await SlideshowVideoRenderer.streamFrames(
            photos: photos,
            canvas: CGSize(width: 16, height: 16),
            loadImage: { url, _ in
                url.lastPathComponent.contains("1") ? nil : image
            }
        ) { _, next in
            stats.recordVisit(hasNext: next != nil)
        }

        XCTAssertEqual(stats.visitPairs, 3, "one failed load is dropped, three frames remain")
        XCTAssertEqual(stats.nextNonNil, 2)
    }

    func testCancellationStopsBeforeVisitingRemainingFrames() async throws {
        let photos = (0..<20).map { i in
            PhotoFile.fixture(url: URL(fileURLWithPath: "/slideshow/cancel-\(i).jpg"))
        }
        let image = try XCTUnwrap(solidImage(color: .blue, size: CGSize(width: 4, height: 4)))
        let stats = LoadStats()

        let task = Task {
            try await SlideshowVideoRenderer.streamFrames(
                photos: photos,
                canvas: CGSize(width: 16, height: 16),
                loadImage: { _, _ in image }
            ) { _, _ in
                if stats.recordVisit(hasNext: false) == 1 {
                    throw CancellationError()
                }
            }
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(stats.visitPairs, 1)
    }

    func testEmptyPhotoListThrows() async {
        do {
            try await SlideshowVideoRenderer.streamFrames(
                photos: [],
                canvas: CGSize(width: 16, height: 16),
                loadImage: { _, _ in nil }
            ) { _, _ in }
            XCTFail("expected noPhotos")
        } catch SlideshowVideoRenderer.RenderError.noPhotos {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Fixture

    private final class LoadStats: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var inflight = 0
        private(set) var maxInflight = 0
        private(set) var requestedSizes: [CGSize] = []
        private(set) var visitPairs = 0
        private(set) var nextNonNil = 0

        func beginLoad(size: CGSize) {
            lock.lock()
            inflight += 1
            maxInflight = max(maxInflight, inflight)
            requestedSizes.append(size)
            lock.unlock()
        }

        func endLoad() {
            lock.lock()
            inflight -= 1
            lock.unlock()
        }

        @discardableResult
        func recordVisit(hasNext: Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            visitPairs += 1
            if hasNext { nextNonNil += 1 }
            return visitPairs
        }
    }

    private func solidImage(color: UIColor, size: CGSize) -> UIImage? {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8(clamping: Int(r * 255))
            pixels[i + 1] = UInt8(clamping: Int(g * 255))
            pixels[i + 2] = UInt8(clamping: Int(b * 255))
            pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }
}
