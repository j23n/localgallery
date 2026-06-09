import CoreGraphics

extension CGImage {
    /// Returns a copy of this image drawn into an opaque, alpha-free bitmap.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` hands back images tagged
    /// `premultipliedLast` even when the source JPEG has no alpha. Re-encoding
    /// such an image as JPEG makes ImageIO log, once per write:
    ///
    ///   writeImageAtIndex: ERROR: trying to save an opaque image with
    ///   'AlphaPremulLast' … --> ignoring alpha.
    ///
    /// before it drops the channel anyway. Drawing into a `noneSkipLast`
    /// context removes the alpha component up front, silencing the warning and
    /// halving the bitmap's decode footprint. The context is malloc-backed (no
    /// IOSurface) and never touches UIKit, so it is safe to call from the
    /// `nonisolated` decode pools that generate thumbnails off the main actor.
    func opaqueCopy() -> CGImage {
        guard width > 0, height > 0 else { return self }
        // Preserve a wide-gamut RGB source's colour space; fall back to device
        // RGB for grayscale / CMYK / indexed images that `noneSkipLast` (a
        // 32-bit RGBX layout) can't represent directly.
        let space: CGColorSpace = {
            if let cs = colorSpace, cs.model == .rgb { return cs }
            return CGColorSpaceCreateDeviceRGB()
        }()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return self }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? self
    }
}
