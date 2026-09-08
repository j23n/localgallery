import Foundation

/// Internal fields written by the `photo-tools` custom XMP namespace.
/// See photo-tools xmp-schema.md §1.2. `CLIPEmbedding` is intentionally
/// excluded — it's a large base64 blob with no display value.
///
/// `taggerVersion` / `taggedAt` fall back to the core's `CoreModelPack` /
/// `CoreTaggedAt` sentinels: this app never stamps photo-tools'
/// `TaggerVersion` (that would make photo-tools skip the file), but the
/// info panel still needs something to show after a tagging run.
///
/// Face fields come from `CoreFacePack` / `CoreFaceTaggedAt`. The face
/// timestamp is its own field so a later tagging write cannot look like a
/// new face scan.
struct PhotoToolsMetadata: Equatable, Sendable, Codable {
    var taggerVersion: String? = nil
    var taggedAt: String? = nil
    var clipModel: String? = nil
    var clipTimestamp: String? = nil
    var facePack: String? = nil
    var faceTaggedAt: String? = nil

    var isEmpty: Bool {
        taggerVersion == nil && taggedAt == nil
            && clipModel == nil && clipTimestamp == nil
            && facePack == nil && faceTaggedAt == nil
    }

    /// Prefer this record's fields; fill gaps from `older`.
    func merging(over older: PhotoToolsMetadata) -> PhotoToolsMetadata {
        PhotoToolsMetadata(
            taggerVersion: taggerVersion ?? older.taggerVersion,
            taggedAt: taggedAt ?? older.taggedAt,
            clipModel: clipModel ?? older.clipModel,
            clipTimestamp: clipTimestamp ?? older.clipTimestamp,
            facePack: facePack ?? older.facePack,
            faceTaggedAt: faceTaggedAt ?? older.faceTaggedAt
        )
    }
}
