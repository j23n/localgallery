import Foundation

/// One reverse-geocoded place. Same fields as the photo-tools sidecar write
/// (`photoshop:*`, `Iptc4xmpCore:*`, `phototools:CountryCode`, `Places/…`).
///
/// Defined here — not in UniFFI `GalleryCore.swift` — so GeocodingService
/// compiles after a bare `xcodegen` against bindings that predate Places.
struct PlaceWrite: Equatable, Sendable {
    var path: String
    var country: String?
    var state: String?
    var city: String?
    var sublocation: String?
    var countryCode: String?
}

enum PlacesWriteError: Error, LocalizedError {
    case invalidTag(String)
    case io(path: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidTag(let tag):
            return "invalid place tag \(tag)"
        case .io(let path, let detail):
            return "places write \(path): \(detail)"
        }
    }
}

/// Write a `Places/…` keyword and the IPTC location fields into `imagePath`'s
/// sidecar (`<photo>.xmp`). Returns whether bytes were written.
///
/// A photo that already has a `Places/*` tag is left alone *unless* the
/// existing path is a strict prefix of the new one (`Places/France` →
/// `Places/France/Île-de-France/Paris`). That is how a country-only first
/// pass — CLGeocoder returning no city — gets upgraded without overwriting
/// a human or photo-tools placement of a different location.
func writePlaces(imagePath: String, place: PlaceWrite) throws -> Bool {
    let normalized = try normalizePlacesPath(place.path)
    let sidecar = imagePath + ".xmp"
    let existing = readPlacesSidecar(canonical: sidecar, imagePath: imagePath)

    let packet: String
    if let xml = existing, let current = firstPlacesPath(in: xml) {
        if current.caseInsensitiveCompare(normalized) == .orderedSame {
            return false
        }
        guard isStrictPlacesPrefix(current, of: normalized),
              let upgraded = replacePlacesPath(in: xml, from: current, to: normalized, place: place)
        else {
            return false
        }
        packet = upgraded
    } else if let xml = existing, let merged = insertPlacesDescription(into: xml, path: normalized, place: place) {
        packet = merged
    } else {
        packet = placesEnvelope(path: normalized, place: place)
    }

    let url = URL(fileURLWithPath: sidecar)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try packet.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        throw PlacesWriteError.io(path: sidecar, detail: error.localizedDescription)
    }
    return true
}

private func normalizePlacesPath(_ path: String) throws -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("Places/"), trimmed != "Places/" else {
        throw PlacesWriteError.invalidTag(path)
    }
    return trimmed
}

private func readPlacesSidecar(canonical: String, imagePath: String) -> String? {
    if let xml = try? String(contentsOfFile: canonical, encoding: .utf8),
       !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return xml
    }
    if let alt = altPlacesSidecarPath(imagePath),
       let xml = try? String(contentsOfFile: alt, encoding: .utf8),
       !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return xml
    }
    return nil
}

/// `IMG_1234.jpg` → `IMG_1234.xmp` (Lightroom form). Read-only fallback.
private func altPlacesSidecarPath(_ imagePath: String) -> String? {
    let fileStart = imagePath.lastIndex(of: "/").map { imagePath.index(after: $0) } ?? imagePath.startIndex
    guard let dot = imagePath[fileStart...].lastIndex(of: "."),
          dot != fileStart
    else { return nil }
    let ext = imagePath[dot...]
    if ext.lowercased() == ".xmp" { return nil }
    return String(imagePath[..<dot]) + ".xmp"
}

private func sidecarContainsPlacesTag(_ xml: String) -> Bool {
    firstPlacesPath(in: xml) != nil
}

/// First `Places/…` entry in `digiKam:TagsList` / any `rdf:li`.
func firstPlacesPath(in xml: String) -> String? {
    guard let regex = try? NSRegularExpression(
        pattern: #"<rdf:li>\s*(Places/[^<]+)</rdf:li>"#,
        options: .caseInsensitive
    ) else { return nil }
    let ns = xml as NSString
    guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)),
          match.numberOfRanges > 1
    else { return nil }
    return ns.substring(with: match.range(at: 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `Places/France` is a strict prefix of `Places/France/Île-de-France/Paris`.
func isStrictPlacesPrefix(_ existing: String, of newer: String) -> Bool {
    let a = existing.split(separator: "/").map(String.init)
    let b = newer.split(separator: "/").map(String.init)
    guard b.count > a.count, a.first?.caseInsensitiveCompare("Places") == .orderedSame else {
        return false
    }
    return zip(a, b).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
}

private func replacePlacesPath(
    in xml: String,
    from old: String,
    to new: String,
    place: PlaceWrite
) -> String? {
    var out = xml
    out = out.replacingOccurrences(of: escapePlacesXML(old), with: escapePlacesXML(new))
    let oldLR = old.replacingOccurrences(of: "/", with: "|")
    let newLR = new.replacingOccurrences(of: "/", with: "|")
    out = out.replacingOccurrences(of: escapePlacesXML(oldLR), with: escapePlacesXML(newLR))
    if let city = nonemptyPlacesField(place.city) {
        out = upsertPhotoshopField(in: out, tag: "photoshop:City", value: city)
    }
    if let state = nonemptyPlacesField(place.state) {
        out = upsertPhotoshopField(in: out, tag: "photoshop:State", value: state)
    }
    return out
}

private func upsertPhotoshopField(in xml: String, tag: String, value: String) -> String {
    let escaped = escapePlacesXML(value)
    let pattern = "<\(tag)>[^<]*</\(tag)>"
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
       let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length))
    {
        let ns = xml as NSString
        return ns.replacingCharacters(in: match.range, with: "<\(tag)>\(escaped)</\(tag)>")
    }
    let insertion = "  <\(tag)>\(escaped)</\(tag)>\n"
    if let range = xml.range(of: "</rdf:Description>", options: [.backwards, .caseInsensitive]) {
        return String(xml[..<range.lowerBound]) + insertion + String(xml[range.lowerBound...])
    }
    return xml
}

private func insertPlacesDescription(into xml: String, path: String, place: PlaceWrite) -> String? {
    guard let range = xml.range(of: "</rdf:RDF>", options: .caseInsensitive) else {
        return nil
    }
    return String(xml[..<range.lowerBound])
        + placesDescriptionBlock(path: path, place: place)
        + String(xml[range.lowerBound...])
}

private func placesEnvelope(path: String, place: PlaceWrite) -> String {
    """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="LocalGallery">
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    \(placesDescriptionBlock(path: path, place: place))
    </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>

    """
}

private func placesDescriptionBlock(path: String, place: PlaceWrite) -> String {
    let leaf = path.split(separator: "/").last.map(String.init) ?? path
    let lr = path.replacingOccurrences(of: "/", with: "|")
    var lines: [String] = [
        " <rdf:Description rdf:about=\"\"",
        "  xmlns:digiKam=\"http://www.digikam.org/ns/1.0/\"",
        "  xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
        "  xmlns:lr=\"http://ns.adobe.com/lightroom/1.0/\"",
        "  xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"",
        "  xmlns:Iptc4xmpCore=\"http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/\"",
        "  xmlns:phototools=\"https://github.com/j23n/photo-tools/ns/1.0/\">",
        "  <digiKam:TagsList><rdf:Seq><rdf:li>\(escapePlacesXML(path))</rdf:li></rdf:Seq></digiKam:TagsList>",
        "  <dc:subject><rdf:Bag><rdf:li>\(escapePlacesXML(leaf))</rdf:li></rdf:Bag></dc:subject>",
        "  <lr:hierarchicalSubject><rdf:Bag><rdf:li>\(escapePlacesXML(lr))</rdf:li></rdf:Bag></lr:hierarchicalSubject>",
    ]
    if let country = nonemptyPlacesField(place.country) {
        lines.append("  <photoshop:Country>\(escapePlacesXML(country))</photoshop:Country>")
    }
    if let state = nonemptyPlacesField(place.state) {
        lines.append("  <photoshop:State>\(escapePlacesXML(state))</photoshop:State>")
    }
    if let city = nonemptyPlacesField(place.city) {
        lines.append("  <photoshop:City>\(escapePlacesXML(city))</photoshop:City>")
    }
    if let sub = nonemptyPlacesField(place.sublocation) {
        lines.append("  <Iptc4xmpCore:Location>\(escapePlacesXML(sub))</Iptc4xmpCore:Location>")
    }
    if let code = nonemptyPlacesField(place.countryCode)?.uppercased(), code.count == 2 {
        lines.append("  <Iptc4xmpCore:CountryCode>\(escapePlacesXML(code))</Iptc4xmpCore:CountryCode>")
        lines.append("  <phototools:CountryCode>\(escapePlacesXML(code))</phototools:CountryCode>")
    }
    lines.append(" </rdf:Description>")
    return lines.joined(separator: "\n") + "\n"
}

private func nonemptyPlacesField(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func escapePlacesXML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
