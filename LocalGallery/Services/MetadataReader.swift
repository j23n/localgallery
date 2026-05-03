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
        gpsLongitude: Double?,
        faceRegions: [FaceRegion]
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
        var faceRegions: [FaceRegion] = []

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
                // MWG `mwg-rs:RegionInfo` is a structured tag — `CGImageMetadataCopyTags`
                // doesn't surface its leaf fields (x/y/w/h/Name) in a usable form.
                // Re-serialise the XMP packet to raw bytes and run our string
                // parser, the same one that handles the .xmp sidecar.
                if let xmpData = CGImageMetadataCreateXMPData(xmpMetadata, nil) as Data?,
                   let xmpString = String(data: xmpData, encoding: .utf8) {
                    faceRegions.append(contentsOf: parseMWGRegions(in: xmpString))
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

        // XMP sidecar file (.xmp) — same fields as embedded, plus MWG regions.
        // Sidecar wins when both sources exist (digiKam typically writes the
        // authoritative copy there); otherwise keep what the embedded XMP gave us.
        let sidecar = readXMPSidecar(for: url)
        rawTags.append(contentsOf: sidecar.rawTags)
        if countryCode == nil { countryCode = sidecar.countryCode }
        if !sidecar.faceRegions.isEmpty { faceRegions = sidecar.faceRegions }

        // Deduplicate hierarchical tags by path (case-insensitive).
        var seenPaths = Set<String>()
        let hierarchicalTags = rawTags.compactMap { raw -> HierarchicalTag? in
            let key = raw.lowercased()
            guard !seenPaths.contains(key) else { return nil }
            seenPaths.insert(key)
            return HierarchicalTag(raw: raw)
        }

        return (captureDate, hierarchicalTags, countryCode, gpsLat, gpsLon, faceRegions)
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
    private static func readXMPSidecar(for imageURL: URL) -> (rawTags: [String], countryCode: String?, faceRegions: [FaceRegion]) {
        let xmpURL = imageURL.appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: xmpURL.path),
              let data = try? Data(contentsOf: xmpURL),
              let xml = String(data: data, encoding: .utf8) else { return ([], nil, []) }

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

        let faceRegions = parseMWGRegions(in: xml)
        return (rawTags, countryCode, faceRegions)
    }

    /// Extract face/region rectangles from MWG `mwg-rs:RegionInfo` blocks in
    /// the XMP. Coords are normalized 0…1; only entries marked
    /// `stArea:unit="normalized"` are accepted (the schema spec, see
    /// photo-tools xmp-schema.md §3).
    ///
    /// We target `<mwg-rs:Area>` tags directly rather than walking `<rdf:li>`
    /// boundaries — different writers (digiKam, exiftool, Lightroom, Apple
    /// Photos) serialise the region container differently (sometimes as a
    /// self-closing rdf:li with all attrs, sometimes as nested
    /// rdf:Description, sometimes with rdf:parseType="Resource"), but every
    /// MWG region has exactly one `<mwg-rs:Area>` whose coords we want.
    static func parseMWGRegions(in xml: String) -> [FaceRegion] {
        var regions: [FaceRegion] = []
        var search = xml.startIndex..<xml.endIndex
        while let areaStart = xml.range(of: "<mwg-rs:Area", range: search) {
            guard let openEnd = xml.range(of: ">", range: areaStart.upperBound..<xml.endIndex) else { break }
            let openTag = String(xml[areaStart.lowerBound..<openEnd.upperBound])
            var attrs = openTag
            // If non-self-closing, also include any element-form children
            // (`<stArea:x>...</stArea:x>` etc.) up to `</mwg-rs:Area>`.
            if openTag.hasSuffix("/>") {
                search = openEnd.upperBound..<xml.endIndex
            } else if let close = xml.range(of: "</mwg-rs:Area>", range: openEnd.upperBound..<xml.endIndex) {
                attrs += String(xml[openEnd.upperBound..<close.lowerBound])
                search = close.upperBound..<xml.endIndex
            } else {
                // Malformed — skip this Area entirely.
                search = openEnd.upperBound..<xml.endIndex
                continue
            }

            let unit = readField(in: attrs, names: ["stArea:unit"])
            guard unit == nil || unit?.lowercased() == "normalized" else { continue }
            guard let xStr = readField(in: attrs, names: ["stArea:x"]),
                  let yStr = readField(in: attrs, names: ["stArea:y"]),
                  let wStr = readField(in: attrs, names: ["stArea:w"]),
                  let hStr = readField(in: attrs, names: ["stArea:h"]),
                  let x = Double(xStr), let y = Double(yStr),
                  let w = Double(wStr), let h = Double(hStr) else { continue }

            // Look back to find the nearest `mwg-rs:Name` — the parent
            // `<rdf:Description>` typically writes Name as an attribute or
            // element above the Area. 2KB is plenty even for verbose
            // serialisations with Type / Rotation / etc.
            let backDistance = min(2_000, xml.distance(from: xml.startIndex, to: areaStart.lowerBound))
            let lookbackStart = xml.index(areaStart.lowerBound, offsetBy: -backDistance)
            let name = lastMWGName(in: String(xml[lookbackStart..<areaStart.lowerBound]))
            regions.append(FaceRegion(name: name, centerX: x, centerY: y, width: w, height: h))
        }
        if regions.isEmpty, xml.contains("mwg-rs") {
            // The XMP carries the namespace marker but our parser found no
            // Areas — treat as a parser bug and surface it. Sample 200 chars
            // around the first mwg-rs occurrence so the user can see the
            // shape we're failing on.
            if let r = xml.range(of: "mwg-rs") {
                let start = xml.index(r.lowerBound, offsetBy: -min(80, xml.distance(from: xml.startIndex, to: r.lowerBound)))
                let end = xml.index(r.lowerBound, offsetBy: min(200, xml.distance(from: r.lowerBound, to: xml.endIndex)))
                let sample = String(xml[start..<end]).replacingOccurrences(of: "\n", with: " ")
                Log.enrich.warning("XMP carries 'mwg-rs' but parser found no regions. Context: …\(sample)…")
            }
        }
        return regions
    }

    /// Last (closest-preceding) `mwg-rs:Name` value in `fragment`. Tries
    /// attribute form first, then element form. Returns nil when neither matches.
    private static func lastMWGName(in fragment: String) -> String? {
        if let r = fragment.range(of: "mwg-rs:Name=\"", options: .backwards),
           let close = fragment.range(of: "\"", range: r.upperBound..<fragment.endIndex) {
            let v = String(fragment[r.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        if let open = fragment.range(of: "<mwg-rs:Name>", options: .backwards),
           let close = fragment.range(of: "</mwg-rs:Name>", range: open.upperBound..<fragment.endIndex) {
            let v = String(fragment[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// Look up a field's text value in an XMP fragment. Tries each candidate
    /// name in attribute form (`name="..."`) first, then element form
    /// (`<name>...</name>`), returning the first match.
    private static func readField(in fragment: String, names: [String]) -> String? {
        for name in names {
            // Attribute form.
            if let attrRange = fragment.range(of: "\(name)=\"") {
                let after = attrRange.upperBound
                if let close = fragment.range(of: "\"", range: after..<fragment.endIndex) {
                    return String(fragment[after..<close.lowerBound])
                }
            }
            // Element form. Strip any namespace path (we want the leaf tag).
            let leaf = name.split(separator: "/").last.map(String.init) ?? name
            if let openRange = fragment.range(of: "<\(leaf)>"),
               let closeRange = fragment.range(of: "</\(leaf)>", range: openRange.upperBound..<fragment.endIndex) {
                return String(fragment[openRange.upperBound..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
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
