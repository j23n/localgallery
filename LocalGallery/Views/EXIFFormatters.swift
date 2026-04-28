import Foundation
import CoreGraphics

/// Pure formatters for the EXIF info sheet. Pulled out of `EXIFContentView`
/// so the values driving each row are testable without spinning up a
/// SwiftUI view.
///
/// Inputs are primitives, not the `EXIFData`/`PhotoFile` structs, so each
/// helper has a tight signature: nil-in → nil-out where the row should
/// render as "—", concrete output otherwise. The view layer takes the
/// shape it sees from the underlying property — pixel dimensions can come
/// from EXIF or from the lazily-loaded `PhotoFile.dimensions`, so the
/// dimensions helper accepts either source.
enum EXIFFormatters {
    /// "1920 × 1080 px" when both dimensions are known. Falls back to the
    /// runtime-loaded CGSize from `PhotoFile` when EXIF is missing.
    static func dimensions(exifWidth: Int?, exifHeight: Int?, runtimeSize: CGSize?) -> String? {
        if let w = exifWidth, let h = exifHeight {
            return "\(w) × \(h) px"
        }
        if let size = runtimeSize {
            return "\(Int(size.width)) × \(Int(size.height)) px"
        }
        return nil
    }

    /// "Make Model" — collapsed to just `Model` when the model string already
    /// contains the make (e.g. "Apple iPhone 15" vs Apple-prefixed model).
    static func camera(make: String?, model: String?) -> String? {
        switch (make, model) {
        case let (m?, mod?):
            if mod.localizedCaseInsensitiveContains(m) {
                return mod
            }
            return "\(m) \(mod)"
        case let (m?, nil): return m
        case let (nil, mod?): return mod
        case (nil, nil): return nil
        }
    }

    /// "f/2.8" — nil when the aperture is missing.
    static func aperture(_ value: Double?) -> String? {
        guard let aperture = value else { return nil }
        return String(format: "f/%.1f", aperture)
    }

    /// "1/250s" for fractional shutter speeds, "2.0s" for ≥ 1 second exposures.
    /// nil when missing or non-positive.
    static func shutterSpeed(_ value: Double?) -> String? {
        guard let speed = value else { return nil }
        if speed >= 1.0 {
            return String(format: "%.1fs", speed)
        } else if speed > 0 {
            let denominator = Int(round(1.0 / speed))
            return "1/\(denominator)s"
        }
        return nil
    }

    /// Localised file size via `ByteCountFormatter` (`.file` style).
    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
