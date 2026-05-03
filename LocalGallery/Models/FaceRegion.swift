import Foundation

/// MWG `mwg-rs:RegionInfo` face region. Coords are normalized 0…1 in
/// image space with **top-left origin**; `centerX`/`centerY` are the region's
/// centre (per MWG `stArea:x/y`), `width`/`height` are its full extent.
///
/// `name` is the value of `mwg-rs:Name` — for face regions, this is the
/// person's name (matches the leaf of `People/<name>` tags written by
/// digiKam). Nil for unnamed regions (e.g. OCR rectangles).
struct FaceRegion: Codable, Hashable, Sendable {
    let name: String?
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
}
