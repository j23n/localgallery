//! Conformance vectors shared with Swift.
//!
//! Reads the *same* file `LocalGalleryTests/Support/Fixtures/stable_uuid_vectors.json`
//! that `StableUUIDVectorTests` reads — there is exactly one copy in the repo,
//! and it is generated from the Swift implementation by
//! `scripts/gen_stable_uuid_vectors.swift`. If Rust and Swift ever disagree,
//! one of the two suites goes red.

use serde::Deserialize;
use std::path::PathBuf;

#[derive(Deserialize)]
struct Vector {
    label: String,
    input: String,
    uuid: String,
}

fn vectors() -> Vec<Vector> {
    // core/gallery-model → repo root → the fixture the Swift tests bundle.
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "..",
        "LocalGalleryTests",
        "Support",
        "Fixtures",
        "stable_uuid_vectors.json",
    ]
    .iter()
    .collect();
    let json = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&json).expect("stable_uuid_vectors.json is not a vector array")
}

#[test]
fn matches_every_swift_vector() {
    let vectors = vectors();
    assert!(
        vectors.len() >= 30,
        "expected the full vector set, got {}",
        vectors.len()
    );
    for v in &vectors {
        assert_eq!(
            gallery_model::stable_uuid::derive(&v.input).to_string(),
            v.uuid,
            "vector `{}` diverged (input {:?})",
            v.label,
            v.input
        );
    }
}

#[test]
fn nfc_and_nfd_are_distinct() {
    // Guards the fixture itself: if an editor or filesystem ever normalizes the
    // JSON, the paired vectors would collapse and the parity claim would be
    // vacuous. Also documents the standing behaviour — no normalization.
    let vectors = vectors();
    for stem in ["cafe", "zurich", "hangul"] {
        let nfc = vectors
            .iter()
            .find(|v| v.label == format!("nfc-{stem}"))
            .unwrap_or_else(|| panic!("missing nfc-{stem} vector"));
        let nfd = vectors
            .iter()
            .find(|v| v.label == format!("nfd-{stem}"))
            .unwrap_or_else(|| panic!("missing nfd-{stem} vector"));
        assert_ne!(nfc.input, nfd.input, "{stem}: fixture was normalized");
        assert_ne!(nfc.uuid, nfd.uuid, "{stem}: composed/decomposed must differ");
    }
}
