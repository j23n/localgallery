import Foundation
import ImageIO

/// Lazy reader for EXIF and the `photo-tools` custom XMP namespace. Pure
/// stateless helper — no caches, no observed state. Calls run on detached
/// tasks so the heavy CGImageSource read stays off the main actor.
enum EXIFService {
    static func loadEXIF(for photo: PhotoFile) async -> EXIFData? {
        // `readEXIF` only throws CancellationError (the cooperative checks).
        try? await readEXIF(url: photo.url)
    }

    /// Reads the `photo-tools` custom XMP namespace (§1.2 of xmp-schema.md)
    /// from embedded XMP and the optional `.xmp` sidecar.
    ///
    /// Nonisolated async, so the body already runs on the global executor —
    /// off whatever actor the caller is on — with structured cancellation
    /// intact. No `Task.detached` needed.
    static func loadPhotoToolsMetadata(for photo: PhotoFile) async -> PhotoToolsMetadata {
        readPhotoToolsMetadata(url: photo.url)
    }

    private static func readPhotoToolsMetadata(url: URL) -> PhotoToolsMetadata {
        var meta = PhotoToolsMetadata()

        // Embedded XMP — tag names come back without namespace prefix.
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
           let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let tags = CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag] ?? []
            for tag in tags {
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                guard let value = CGImageMetadataTagCopyValue(tag) as? String,
                      !value.isEmpty else { continue }
                switch name {
                case "TaggerVersion": meta.taggerVersion = meta.taggerVersion ?? value
                case "TaggedAt":      meta.taggedAt = meta.taggedAt ?? value
                case "CountryCode":   meta.countryCode = meta.countryCode ?? value.uppercased()
                case "CLIPModel":     meta.clipModel = meta.clipModel ?? value
                case "CLIPTimestamp": meta.clipTimestamp = meta.clipTimestamp ?? value
                default: break
                }
            }
        }

        // Sidecar — simple tag extraction for scalar fields.
        let xmpURL = url.appendingPathExtension("xmp")
        if let data = try? Data(contentsOf: xmpURL),
           let xml = String(data: data, encoding: .utf8) {
            func scalar(_ localName: String) -> String? {
                for prefix in ["photo-tools:\(localName)", "phototools:\(localName)"] {
                    if let s = xml.range(of: "<\(prefix)>"),
                       let e = xml.range(of: "</\(prefix)>", range: s.upperBound..<xml.endIndex) {
                        let v = xml[s.upperBound..<e.lowerBound]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { return v }
                    }
                }
                return nil
            }
            meta.taggerVersion = meta.taggerVersion ?? scalar("TaggerVersion")
            meta.taggedAt = meta.taggedAt ?? scalar("TaggedAt")
            if meta.countryCode == nil, let cc = scalar("CountryCode") { meta.countryCode = cc.uppercased() }
            meta.clipModel = meta.clipModel ?? scalar("CLIPModel")
            meta.clipTimestamp = meta.clipTimestamp ?? scalar("CLIPTimestamp")
        }

        return meta
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
            data.dateTimeOriginal = MetadataReader.exifDateFormatter.date(from: dateString)
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
