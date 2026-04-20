import Foundation
import AVFoundation
import UIKit

/// Renders a memory's photo list as a crossfading slideshow MP4 file.
/// Output is 1080×1080 square, H.264, 30 fps. Each photo is held then
/// cross-fades into the next.
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

        // Preload images at target res.
        await progress(0)
        var images: [CGImage] = []
        images.reserveCapacity(photos.count)
        for (i, photo) in photos.enumerated() {
            let ui = await loadImage(photo.url, canvas)
            guard let cg = ui?.cgImage ?? ui?.normalizedCGImage() else {
                continue
            }
            images.append(cg)
            let p = Double(i + 1) / Double(photos.count) * 0.25
            await progress(p)
        }
        guard !images.isEmpty else { throw RenderError.thumbnailFailed }

        let holdFrames = Int(options.holdSeconds * Double(options.frameRate))
        let crossFrames = Int(options.crossfadeSeconds * Double(options.frameRate))
        let fpsDuration = CMTimeMake(value: 1, timescale: options.frameRate)

        var frameIndex: Int64 = 0
        let queue = DispatchQueue(label: "slideshow.render")
        let totalSegments = images.count

        for (idx, cg) in images.enumerated() {
            // Hold the current frame.
            for _ in 0..<holdFrames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                guard let buffer = makePixelBuffer(adaptor: adaptor, canvas: canvas) else {
                    throw RenderError.pixelBufferPoolFailed
                }
                try await draw(into: buffer, top: cg, bottom: nil, alpha: 1.0, canvas: canvas, queue: queue)
                let time = CMTimeMultiply(fpsDuration, multiplier: Int32(frameIndex))
                if !adaptor.append(buffer, withPresentationTime: time) {
                    throw RenderError.appendFailed
                }
                frameIndex += 1
            }

            // Crossfade to the next (if there is one).
            if idx < images.count - 1 {
                let next = images[idx + 1]
                for f in 0..<crossFrames {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                    guard let buffer = makePixelBuffer(adaptor: adaptor, canvas: canvas) else {
                        throw RenderError.pixelBufferPoolFailed
                    }
                    let alpha = Double(f + 1) / Double(crossFrames)
                    try await draw(into: buffer, top: next, bottom: cg, alpha: alpha, canvas: canvas, queue: queue)
                    let time = CMTimeMultiply(fpsDuration, multiplier: Int32(frameIndex))
                    if !adaptor.append(buffer, withPresentationTime: time) {
                        throw RenderError.appendFailed
                    }
                    frameIndex += 1
                }
            }

            // 25% for load, then 75% for the render portion.
            let p = 0.25 + Double(idx + 1) / Double(totalSegments) * 0.75
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

    // MARK: - Frame rendering

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

    /// Draws `bottom` (opaque) then `top` blended at `alpha` on top, aspect-fill centered.
    private static func draw(
        into pixelBuffer: CVPixelBuffer,
        top: CGImage,
        bottom: CGImage?,
        alpha: Double,
        canvas: CGSize,
        queue: DispatchQueue
    ) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
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
                    cont.resume(); return
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
    func normalizedCGImage() -> CGImage? {
        if let cg = cgImage { return cg }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()
        return out
    }
}
