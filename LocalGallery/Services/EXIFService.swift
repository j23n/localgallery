import Foundation
import ImageIO

/// Lazy reader for camera EXIF (aperture, ISO, lens, capture date, GPS).
/// Tags, faces and photo-tools stamps live on the sidecar —
/// `SidecarDocument`. Pure stateless helper. Calls run on detached tasks
/// so the CGImageSource read stays off the main actor.
enum EXIFService {
    /// EXIF `"yyyy:MM:dd HH:mm:ss"` parser, for the info panel's *displayed*
    /// capture date.
    ///
    /// The last survivor of `MetadataReader`, which moved into the Rust core
    /// with the scanner. The core reads the same field for the scan/enrichment
    /// path and hands back a zone-less wall clock; this one exists because the
    /// info panel reads its own `CGImageSource` properties anyway (aperture,
    /// ISO, lens) and re-crossing the FFI for one string would be silly.
    ///
    /// Fixed-format parsing requires the POSIX locale + Gregorian calendar —
    /// with the device's own settings a non-Gregorian calendar (Buddhist,
    /// Japanese) parses to wrong years. No `timeZone` override: EXIF capture
    /// dates carry no zone, so the device zone is the least-wrong
    /// interpretation, and the core's bridge resolves its wall clock the same
    /// way. Never mutated after init; `DateFormatter` is Sendable (and
    /// documented thread-safe since iOS 7).
    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func loadEXIF(for photo: PhotoFile) async -> EXIFData? {
        // `readEXIF` only throws CancellationError (the cooperative checks).
        try? await readEXIF(url: photo.url)
    }

    private static func readEXIF(url: URL) async throws -> EXIFData? {
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        try Task.checkCancellation()

        let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var data = EXIFData()

        data.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        data.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        data.cameraMake = tiffDict?[kCGImagePropertyTIFFMake] as? String
        data.cameraModel = tiffDict?[kCGImagePropertyTIFFModel] as? String

        data.lens = exifDict?[kCGImagePropertyExifLensModel] as? String
        data.aperture = exifDict?[kCGImagePropertyExifFNumber] as? Double
        data.shutterSpeed = exifDict?[kCGImagePropertyExifExposureTime] as? Double
        data.iso = (exifDict?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first

        if let dateString = exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String {
            data.dateTimeOriginal = Self.exifDateFormatter.date(from: dateString)
        }

        if let lat = gpsDict?[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gpsDict?[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gpsDict?[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gpsDict?[kCGImagePropertyGPSLongitudeRef] as? String
            data.gpsLatitude = latRef == "S" ? -lat : lat
            data.gpsLongitude = lonRef == "W" ? -lon : lon
        }

        return data
    }
}
