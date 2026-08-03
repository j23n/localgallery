//! Shared fixture plumbing for the integration tests.

#![allow(dead_code)]

use std::path::PathBuf;

/// Path to `tests/fixtures/<name>`.
pub fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Bytes of `tests/fixtures/<name>`.
pub fn fixture(name: &str) -> Vec<u8> {
    let path = fixture_path(name);
    std::fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "missing fixture {}: {e}\nregenerate with tests/make_test_pack.py",
            path.display()
        )
    })
}

/// Path to the committed test model pack. Schema 1: tagging only.
pub fn test_pack_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/testpack")
}

/// Path to the committed face-capable test pack. Schema 2.
pub fn face_pack_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/facepack")
}

/// Lowercase hex SHA-256.
pub fn sha256_hex(bytes: &[u8]) -> String {
    gallery_ml::pack::sha256_hex(bytes)
}
