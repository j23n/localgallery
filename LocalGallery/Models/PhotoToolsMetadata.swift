import Foundation

/// Internal fields written by the `photo-tools` custom XMP namespace.
/// See photo-tools xmp-schema.md §1.2. `CLIPEmbedding` is intentionally
/// excluded — it's a large base64 blob with no display value.
struct PhotoToolsMetadata: Equatable, Sendable {
    var taggerVersion: String?
    var taggedAt: String?
    var countryCode: String?
    var clipModel: String?
    var clipTimestamp: String?

    var isEmpty: Bool {
        taggerVersion == nil && taggedAt == nil && countryCode == nil
            && clipModel == nil && clipTimestamp == nil
    }
}
