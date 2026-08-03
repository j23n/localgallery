//! Fixture loading shared by the integration suites.
//!
//! Each integration test is its own crate, so anything one suite does not use
//! looks dead from the others' point of view.
#![allow(dead_code)]

use std::path::PathBuf;

/// Every fixture sidecar, by file name.
///
/// `phototools` and `digikam` are genuine exiftool 13.55 output (generated with
/// the photo-tools exiftool config); `minimal` and `weird_rdf` are hand-written
/// to cover shapes exiftool never emits but other writers do.
pub const FIXTURES: &[&str] = &[
    "phototools.jpg.xmp",
    "digikam.jpg.xmp",
    "minimal.jpg.xmp",
    "weird_rdf.jpg.xmp",
];

/// Absolute path to a fixture.
pub fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Fixture bytes.
pub fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(fixture_path(name)).unwrap_or_else(|e| panic!("read fixture {name}: {e}"))
}

/// Fixture as a string.
pub fn fixture_str(name: &str) -> String {
    String::from_utf8(fixture(name)).expect("fixture is UTF-8")
}
