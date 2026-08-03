//! Deterministic, path-derived photo/folder identity.
//!
//! Byte-for-byte mirror of `StableUUID.derive(from:)` in
//! `LocalGallery/Models/PhotoFile.swift`. Both implementations are pinned
//! against the same conformance vectors
//! (`LocalGalleryTests/Support/Fixtures/stable_uuid_vectors.json`), so a change
//! to either one without the other fails `cargo test` *and* `xcodebuild test`.

use sha2::{Digest, Sha256};
use uuid::Uuid;

/// SHA-256-truncated deterministic UUID with RFC 4122 variant + version-5 marker.
///
/// Namespace-less: this is *not* an RFC 4122 name-based UUID (no namespace is
/// mixed in), it only wears the version/variant markers — so do not reach for
/// `Uuid::new_v5`, it would produce different bytes.
///
/// Normalization is the caller's job. Swift feeds in `url.standardized.path`,
/// so `..` segments and trailing slashes are already resolved before hashing.
/// No Unicode normalization is applied either: NFC and NFD spellings of the
/// same visible name derive *different* UUIDs (pinned as distinct vectors;
/// whether to normalize is a Phase 3 question).
pub fn derive(input: &str) -> Uuid {
    let digest = Sha256::digest(input.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50; // version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant RFC 4122
    Uuid::from_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_deterministic() {
        let path = "/Volumes/Library/2024/IMG_0001.jpg";
        assert_eq!(derive(path), derive(path));
    }

    #[test]
    fn differs_across_inputs() {
        assert_ne!(derive("/a/IMG_0001.jpg"), derive("/a/IMG_0002.jpg"));
    }

    #[test]
    fn stamps_version_and_variant_markers() {
        let bytes = *derive("/library/x.jpg").as_bytes();
        assert_eq!(bytes[6] & 0xF0, 0x50, "version-5 nibble must be 5");
        assert_eq!(bytes[8] & 0xC0, 0x80, "RFC 4122 variant must be 10xx");
    }

    #[test]
    fn renders_lowercase_hyphenated() {
        let rendered = derive("/library/x.jpg").to_string();
        assert_eq!(rendered.len(), 36);
        assert_eq!(rendered, rendered.to_lowercase());
    }
}
