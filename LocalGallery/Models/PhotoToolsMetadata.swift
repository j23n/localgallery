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
struct PhotoToolsMetadata: Equatable, Sendable {
    var taggerVersion: String?
    var taggedAt: String?
    var clipModel: String?
    var clipTimestamp: String?
    var facePack: String?
    var faceTaggedAt: String?

    var isEmpty: Bool {
        taggerVersion == nil && taggedAt == nil
            && clipModel == nil && clipTimestamp == nil
            && facePack == nil && faceTaggedAt == nil
    }
}
