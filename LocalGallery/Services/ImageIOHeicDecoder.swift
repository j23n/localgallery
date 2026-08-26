import CoreGraphics
import Foundation
import ImageIO

/// Hardware HEIC decode via ImageIO.
///
/// The core's software HEVC path is several seconds per 12 MP iPhone photo
/// and, worse, allocates the full frame — four workers × 48 MP RGB is what
/// jetsams a debug session. ImageIO uses the media engine, thumbs to
/// `maxPixelSize`, and (with cache flags off) does not keep a process-wide
/// decoded bitmap for every photo in the library.
final class ImageIOHeicDecoder: HeicDecoder, @unchecked Sendable {
    static let shared = ImageIOHeicDecoder()
    /// Long-side cap. Matches the size Photos uses for on-device analysis.
    static let maxPixelSize = 2048

    func decode(path: String) throws -> HeicPixels {
        let url = URL(fileURLWithPath: path)
        let openOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, openOpts as CFDictionary) else {
            Log.ml.error("ImageIO could not open \(Log.r.path(url))")
            throw HeicDecodeError.Failed(detail: "could not open")
        }
        // `ShouldCacheImmediately: true` retains a decoded bitmap in ImageIO's
        // process cache, keyed by URL. A 12-minute library scan then holds
        // every thumbnail at once. We draw into our own buffer and drop `cg`.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            Log.ml.error("ImageIO decode failed for \(Log.r.path(url))")
            throw HeicDecodeError.Failed(detail: "decode failed")
        }
        return try Self.packedRGB(cg)
    }

    private static func packedRGB(_ image: CGImage) throws -> HeicPixels {
        let width = image.width
        let height = image.height
        // 24-bit RGB when the context will take it — one buffer, not RGBA +
        // a copy-out. Some pixel formats refuse a 3-byte row; fall back.
        if let rgb = packRGB24(image, width: width, height: height) {
            return HeicPixels(width: UInt32(width), height: UInt32(height), rgb: rgb)
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else {
            throw HeicDecodeError.Failed(detail: "could not create bitmap context")
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        rgba = []
        return HeicPixels(width: UInt32(width), height: UInt32(height), rgb: Data(rgb))
    }

    private static func packRGB24(_ image: CGImage, width: Int, height: Int) -> Data? {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        let ok = rgb.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 3,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Data(rgb) : nil
    }
}
