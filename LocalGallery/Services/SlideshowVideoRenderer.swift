import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Renders a memory's photo list as a crossfading slideshow MP4 file.
/// Output defaults to 1080×1080 square, H.264, 30 fps. Each photo is held
/// then cross-fades into the next.
///
/// Decode is a two-frame window (current + next). Finished frames are
/// released before the following photo is loaded so a 75-photo memory never
/// retains 75 decoded bitmaps.
enum SlideshowVideoRenderer {
    struct Options {
        var canvasSize = CGSize(width: 1080, height: 1080)
        var frameRate: Int32 = 30
        var holdSeconds: Double = 2.6
        var crossfadeSeconds: Double = 0.5
    }

    enum RenderError: Error {
        case noPhotos
        case writerSetupFailed
        case pixelBufferPoolFailed
        case thumbnailFailed
        case appendFailed
    }

    /// Peak number of decoded frames held by the most recent `streamFrames`
    /// / `render` call. Tests assert the window stays at current+next.
    enum RetentionMetrics: @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var retained = 0
        nonisolated(unsafe) private static var maxRetained = 0

        static var currentRetained: Int {
            lock.lock(); defer { lock.unlock() }
            return retained
        }

        static var maxRetainedImages: Int {
            lock.lock(); defer { lock.unlock() }
            return maxRetained
        }

        static func reset() {
            lock.lock()
            retained = 0
            maxRetained = 0
            lock.unlock()
        }

        fileprivate static func record(_ count: Int) {
            lock.lock()
            retained = count
            if count > maxRetained { maxRetained = count }
            lock.unlock()
        }
    }

    /// Renders `photos` to an MP4 file in the caches directory.
    /// - Parameter progress: called on the main actor with 0…1
    /// - Returns: URL of the written file.
    static func render(
        photos: [PhotoFile],
        title: String,
        options: Options = .init(),
        loadImage: @escaping (URL, CGSize) async -> UIImage?,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard !photos.isEmpty else { throw RenderError.noPhotos }

        let outURL = cachesURL(forTitle: title)
        try? FileManager.default.removeItem(at: outURL)

        let canvas = options.canvasSize
        let writer = try AVAssetWriter(url: outURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: bufferAttrs)

        guard writer.canAdd(input) else { throw RenderError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw RenderError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        let holdFrames = Int(options.holdSeconds * Double(options.frameRate))
        let crossFrames = Int(options.crossfadeSeconds * Double(options.frameRate))
        let fpsDuration = CMTimeMake(value: 1, timescale: options.frameRate)
        let queue = DispatchQueue(label: "slideshow.render")

        var frameIndex: Int64 = 0
        var segmentsDone = 0

        try await streamFrames(
            photos: photos,
            canvas: canvas,
            loadImage: loadImage,
            progress: { @MainActor p in
                // streamFrames reports decode-window progress in 0…0.25;
                // encode fills 0.25…0.99 via the visit callback below.
                if p <= 0.25 { await progress(p) }
            }
        ) { current, next in
            try Task.checkCancellation()

            for _ in 0..<holdFrames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                try await appendFrame(
                    adaptor: adaptor,
                    canvas: canvas,
                    queue: queue,
                    frameIndex: frameIndex,
                    fpsDuration: fpsDuration,
                    top: current,
                    bottom: nil,
                    alpha: 1.0
                )
                frameIndex += 1
            }

            if let next {
                for f in 0..<crossFrames {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    let alpha = Double(f + 1) / Double(max(crossFrames, 1))
                    try await appendFrame(
                        adaptor: adaptor,
                        canvas: canvas,
                        queue: queue,
                        frameIndex: frameIndex,
                        fpsDuration: fpsDuration,
                        top: next,
                        bottom: current,
                        alpha: alpha
                    )
                    frameIndex += 1
                }
            }

            segmentsDone += 1
            let p = 0.25 + Double(segmentsDone) / Double(max(photos.count, 1)) * 0.75
            await progress(min(p, 0.99))
        }

        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? RenderError.writerSetupFailed
        }
        await progress(1.0)
        return outURL
    }

    /// Walks `photos` with a two-frame decode window. `visit` receives the
    /// current frame and the already-decoded next frame (nil on the last
    /// photo). After `visit` returns, `current` is released and `next`
    /// becomes current.
    ///
    /// Failed loads are skipped, matching the historical renderer. Throws
    /// `thumbnailFailed` when every photo fails to decode.
    static func streamFrames(
        photos: [PhotoFile],
        canvas: CGSize,
        loadImage: @escaping (URL, CGSize) async -> UIImage?,
        progress: (@MainActor (Double) -> Void)? = nil,
        visit: (CGImage, CGImage?) async throws -> Void
    ) async throws {
        guard !photos.isEmpty else { throw RenderError.noPhotos }
        RetentionMetrics.reset()
        defer { RetentionMetrics.record(0) }

        var nextIndex = 0
        func loadCG() async throws -> CGImage? {
            while nextIndex < photos.count {
                try Task.checkCancellation()
                let photo = photos[nextIndex]
                nextIndex += 1
                let ui = await loadImage(photo.url, canvas)
                if let cg = autoreleasepool(invoking: { ui?.cgImage ?? ui?.normalizedCGImage() }) {
                    return cg
                }
            }
            return nil
        }

        if let progress { await progress(0) }
        guard var current = try await loadCG() else { throw RenderError.thumbnailFailed }
        RetentionMetrics.record(1)
        if let progress {
            let loaded = Double(nextIndex) / Double(photos.count)
            await progress(min(loaded * 0.25, 0.25))
        }

        while true {
            try Task.checkCancellation()
            let next = try await loadCG()
            RetentionMetrics.record(next == nil ? 1 : 2)
            if let progress {
                let loaded = Double(nextIndex) / Double(photos.count)
                await progress(min(loaded * 0.25, 0.25))
            }
            try await visit(current, next)
            guard let next else { break }
            current = next
            RetentionMetrics.record(1)
        }
    }

    // MARK: - Frame rendering

    private static func appendFrame(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        canvas: CGSize,
        queue: DispatchQueue,
        frameIndex: Int64,
        fpsDuration: CMTime,
        top: CGImage,
        bottom: CGImage?,
        alpha: Double
    ) async throws {
        guard let buffer = makePixelBuffer(adaptor: adaptor, canvas: canvas) else {
            throw RenderError.pixelBufferPoolFailed
        }
        try await draw(into: buffer, top: top, bottom: bottom, alpha: alpha, canvas: canvas, queue: queue)
        let time = CMTimeMultiply(fpsDuration, multiplier: Int32(frameIndex))
        if !adaptor.append(buffer, withPresentationTime: time) {
            throw RenderError.appendFailed
        }
    }

    private static func makePixelBuffer(adaptor: AVAssetWriterInputPixelBufferAdaptor, canvas: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            if let pb { return pb }
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(nil, Int(canvas.width), Int(canvas.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb
    }

    /// `CVPixelBuffer` (a `CVBuffer` class) isn't `Sendable`, but in this
    /// renderer the buffer is owned by exactly one task and accessed serially
    /// on the writer queue (locked via `CVPixelBufferLockBaseAddress`). This
    /// wrapper is the documented escape hatch for handing it across the
    /// `queue.async` `@Sendable` boundary under Swift 6 strict concurrency.
    private struct UnsafeSendable<T>: @unchecked Sendable {
        let value: T
    }

    /// Draws `bottom` (opaque) then `top` blended at `alpha` on top, aspect-fill centered.
    private static func draw(
        into pixelBuffer: CVPixelBuffer,
        top: CGImage,
        bottom: CGImage?,
        alpha: Double,
        canvas: CGSize,
        queue: DispatchQueue
    ) async throws {
        let pb = UnsafeSendable(value: pixelBuffer)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                autoreleasepool {
                    let pixelBuffer = pb.value
                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    let base = CVPixelBufferGetBaseAddress(pixelBuffer)
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    guard let ctx = CGContext(data: base, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                              space: colorSpace, bitmapInfo: bitmapInfo) else {
                        return
                    }

                    // Paint black background (memory slideshow look).
                    ctx.setFillColor(UIColor.black.cgColor)
                    ctx.fill(CGRect(origin: .zero, size: canvas))

                    // Image is drawn flipped — stored in context-ascending pixel space.
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: canvas.height)
                    ctx.scaleBy(x: 1, y: -1)

                    if let bottom {
                        draw(image: bottom, in: ctx, canvas: canvas, alpha: 1.0)
                    }
                    draw(image: top, in: ctx, canvas: canvas, alpha: CGFloat(alpha))

                    ctx.restoreGState()
                }
                cont.resume()
            }
        }
    }

    private static func draw(image: CGImage, in ctx: CGContext, canvas: CGSize, alpha: CGFloat) {
        // Aspect-fill the canvas.
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = max(canvas.width / iw, canvas.height / ih)
        let w = iw * scale, h = ih * scale
        let x = (canvas.width - w) / 2
        let y = (canvas.height - h) / 2
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
        ctx.restoreGState()
    }

    private static func cachesURL(forTitle title: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        let name = safe.isEmpty ? "slideshow" : "slideshow-\(safe)"
        return caches.appendingPathComponent("\(name).mp4")
    }
}

private extension UIImage {
    /// Returns a CGImage even when `cgImage` is nil (e.g. CIImage-backed UIImages).
    /// Previously routed through `UIGraphicsBeginImageContextWithOptions` —
    /// that's the legacy per-thread context-stack API which is fragile on
    /// iOS 26's tightened UIKit-from-background rules. Slideshow rendering
    /// happens off the main actor via `SlideshowVideoRenderer.render`, so we
    /// use a `CIContext` (thread-safe, no UIKit dependency) to materialise
    /// the CIImage backing into a CGImage instead.
    func normalizedCGImage() -> CGImage? {
        if let cg = cgImage { return cg }
        if let ci = ciImage {
            return CIContext(options: nil).createCGImage(ci, from: ci.extent)
        }
        return nil
    }
}
