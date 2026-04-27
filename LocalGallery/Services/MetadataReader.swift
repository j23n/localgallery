import Foundation
import ImageIO
import AVFoundation

/// Pure stateless readers for the image / video / sidecar metadata that the
/// folder-scan + enrichment pipeline consumes. All methods are nonisolated
/// statics so the scanner / enricher can call them from detached tasks.
enum MetadataReader {
    typealias Result = (
        date: Date?,
        hierarchicalTags: [HierarchicalTag],
        countryCode: String?,
        gpsLatitude: Double?,
        gpsLongitude: Double?
    )

    /// Read capture date, hierarchical tags, country code, and GPS from image
    /// metadata (EXIF/XMP) + the optional `.xmp` sidecar. Tag source is
    /// `digiKam:TagsList`; country code is `photo-tools:CountryCode` (see
    /// photo-tools xmp-schema.md §1).
    static func readImageMetadata(url: URL) -> Result {
        var captureDate: Date? = nil
        var rawTags: [String] = []
        var countryCode: String? = nil
        var gpsLat: Double? = nil
        var gpsLon: Double? = nil

        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {

            // EXIF date: DateTimeOriginal → DateTimeDigitized → TIFF DateTime
            let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

            let dateStrings = [
                exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String,
                exifDict?[kCGImagePropertyExifDateTimeDigitized] as? String,
                tiffDict?[kCGImagePropertyTIFFDateTime] as? String,
            ]
            for dateString in dateStrings {
                if let s = dateString, let d = dateFormatter.date(from: s) {
                    captureDate = d
                    break
                }
            }

            // XMP: digiKam:TagsList (hierarchical paths) + photo-tools:CountryCode
            if let xmpMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                let tags = CGImageMetadataCopyTags(xmpMetadata) as? [CGImageMetadataTag] ?? []
                for tag in tags {
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                    let value = CGImageMetadataTagCopyValue(tag)
                    if name == "TagsList", let value {
                        rawTags.append(contentsOf: xmpStringArray(value))
                    } else if name == "CountryCode", countryCode == nil,
                              let str = value as? String, !str.isEmpty {
                        countryCode = str.uppercased()
                    }
                }
            }

            // GPS coordinates
            if let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gpsDict[kCGImagePropertyGPSLatitude] as? Double,
               let lon = gpsDict[kCGImagePropertyGPSLongitude] as? Double {
                let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef] as? String
                let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String
                gpsLat = latRef == "S" ? -lat : lat
                gpsLon = lonRef == "W" ? -lon : lon
            }
        }

        // XMP sidecar file (.xmp) — same fields as embedded
        let sidecar = readXMPSidecar(for: url)
        rawTags.append(contentsOf: sidecar.rawTags)
        if countryCode == nil { countryCode = sidecar.countryCode }

        // Deduplicate hierarchical tags by path (case-insensitive).
        var seenPaths = Set<String>()
        let hierarchicalTags = rawTags.compactMap { raw -> HierarchicalTag? in
            let key = raw.lowercased()
            guard !seenPaths.contains(key) else { return nil }
            seenPaths.insert(key)
            return HierarchicalTag(raw: raw)
        }

        return (captureDate, hierarchicalTags, countryCode, gpsLat, gpsLon)
    }

    /// Pick the earlier of creation/modification dates. Handles AirDrop and
    /// chat-saved files where the original modDate is preserved but
    /// `creationDate` reflects the download time on this volume.
    static func earliestFilesystemDate(creation: Date?, modification: Date?) -> Date? {
        switch (creation, modification) {
        case let (c?, m?): return min(c, m)
        case let (c?, nil): return c
        case let (nil, m?): return m
        case (nil, nil): return nil
        }
    }

    /// Coerce a `CGImageMetadataTag` value into `[String]`.
    ///
    /// rdf:Bag / rdf:Seq values come back as `CFArray` of `CGImageMetadataTag`
    /// (one per `<rdf:li>`), not `CFArray` of `CFString` — so `as? [String]`
    /// silently yields `nil` and we'd lose every embedded hierarchical tag.
    /// Recurse on each child via `CGImageMetadataTagCopyValue`.
    private static func xmpStringArray(_ value: CFTypeRef) -> [String] {
        let tagTypeID = CGImageMetadataTagGetTypeID()
        if CFGetTypeID(value) == tagTypeID {
            let tag = value as! CGImageMetadataTag
            if let nested = CGImageMetadataTagCopyValue(tag) {
                return xmpStringArray(nested)
            }
            return []
        }
        if CFGetTypeID(value) == CFArrayGetTypeID() {
            let array = value as! CFArray
            let count = CFArrayGetCount(array)
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
                let item = unsafeBitCast(raw, to: CFTypeRef.self)
                out.append(contentsOf: xmpStringArray(item))
            }
            return out
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return []
    }

    /// Parse XMP sidecar file (.xmp) for digiKam:TagsList + photo-tools:CountryCode.
    private static func readXMPSidecar(for imageURL: URL) -> (rawTags: [String], countryCode: String?) {
        let xmpURL = imageURL.appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: xmpURL.path),
              let data = try? Data(contentsOf: xmpURL),
              let xml = String(data: data, encoding: .utf8) else { return ([], nil) }

        var rawTags: [String] = []

        // Hierarchical tags from digiKam:TagsList.
        if let startRange = xml.range(of: "<digiKam:TagsList>") ?? xml.range(of: "<digiKam:TagsList "),
           let endRange = xml.range(of: "</digiKam:TagsList>", range: startRange.upperBound..<xml.endIndex) {
            let block = String(xml[startRange.upperBound..<endRange.lowerBound])
            var searchRange = block.startIndex..<block.endIndex
            while let liStart = block.range(of: "<rdf:li>", range: searchRange) {
                guard let liEnd = block.range(of: "</rdf:li>", range: liStart.upperBound..<block.endIndex) else { break }
                let value = String(block[liStart.upperBound..<liEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { rawTags.append(value) }
                searchRange = liEnd.upperBound..<block.endIndex
            }
        }

        // photo-tools:CountryCode — a simple scalar, optional prefix may vary.
        var countryCode: String? = nil
        for prefix in ["photo-tools:CountryCode", "phototools:CountryCode"] {
            if let startRange = xml.range(of: "<\(prefix)>"),
               let endRange = xml.range(of: "</\(prefix)>", range: startRange.upperBound..<xml.endIndex) {
                let value = String(xml[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { countryCode = value.uppercased(); break }
            }
        }

        return (rawTags, countryCode)
    }

    /// Read capture date from video metadata via AVURLAsset.creationDate.
    static func readVideoDate(url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let creationDate = try? await asset.load(.creationDate),
              let dateValue = try? await creationDate.load(.dateValue) else {
            return nil
        }
        return dateValue
    }
}
