import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Quality tier for the photo viewer's share menu. `.original` hands back
/// the source URL untouched; resized tiers render to a temp JPEG.
enum PhotoQuality: String, CaseIterable, Identifiable, Sendable {
    case original, high, medium, small

    var id: String { rawValue }

    /// Long-edge cap in pixels, or nil for "no resize".
    var maxEdge: Int? {
        switch self {
        case .original: return nil
        case .high:     return 4096
        case .medium:   return 2048
        case .small:    return 1024
        }
    }

    /// JPEG quality for the resized output.
    var jpegQuality: Float {
        switch self {
        case .original: return 1.0
        case .high:     return 0.90
        case .medium:   return 0.85
        case .small:    return 0.80
        }
    }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .high:     return "High"
        case .medium:   return "Medium"
        case .small:    return "Small"
        }
    }

    var dimensionLabel: String? {
        guard let edge = maxEdge else { return nil }
        return "\(edge)px"
    }

    var iconName: String {
        switch self {
        case .original: return "doc"
        case .high:     return "photo.fill"
        case .medium:   return "photo"
        case .small:    return "photo.artframe"
        }
    }

    /// Display name with the dimension cap appended in parens for resized tiers.
    var menuTitle: String {
        if let dim = dimensionLabel { return "\(displayName) (\(dim))" }
        return displayName
    }
}

/// Resizes photos to a chosen `PhotoQuality` for sharing. Resized output is
/// JPEG written to `FileManager.default.temporaryDirectory`. Videos always
/// use `.original` regardless of the requested quality.
enum PhotoExporter {
    enum ExportError: Error {
        case sourceUnavailable
        case encodeFailed
        case writeFailed
    }

    /// Returns a URL suitable to hand to a `UIActivityViewController`.
    /// `.original` and any video return `photo.url`. Other tiers render via
    /// `CGImageSource` thumbnail at `maxEdge`, encoded JPEG, written atomic.
    ///
    /// Nonisolated async, so the render already runs on the global executor,
    /// off the caller's actor — no `Task.detached` needed.
    static func export(_ photo: PhotoFile, quality: PhotoQuality) async throws -> URL {
        if quality == .original || photo.isVideo {
            return photo.url
        }
        return try renderJPEG(from: photo, quality: quality)
    }

    private static func renderJPEG(from photo: PhotoFile, quality: PhotoQuality) throws -> URL {
        guard let maxEdge = quality.maxEdge else { return photo.url }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, sourceOptions as CFDictionary) else {
            throw ExportError.sourceUnavailable
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw ExportError.encodeFailed
        }

        let stem = photo.url.deletingPathExtension().lastPathComponent
        // Stable-ID prefix: two photos named IMG_1234 in different folders
        // (or a re-share while a share sheet still references the previous
        // file) must not overwrite each other's exports.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(photo.id.uuidString.prefix(8))-\(stem)-\(quality.rawValue).jpg")
        // Pre-clean so a stale earlier export isn't picked up by mistake.
        try? FileManager.default.removeItem(at: outURL)

        guard let dest = CGImageDestinationCreateWithURL(
            outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ExportError.writeFailed
        }
        let destOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality.jpegQuality]
        // Flatten the thumbnail's `premultipliedLast` alpha before encoding so
        // ImageIO doesn't log the "save an opaque image with 'AlphaPremulLast'"
        // warning (JPEG can't carry alpha; the channel is dropped regardless).
        CGImageDestinationAddImage(dest, cgImage.opaqueCopy(), destOptions as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed
        }
        return outURL
    }
}
