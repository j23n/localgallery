//! The extension table, checked against `UTType`.
//!
//! `metadata_conformance.json` records a `scannerKind` per asset —
//! `image` / `video` / `skipped` — computed by asking `UTType` whether the
//! extension conforms to `.image` or `.movie`. There is no `UTType` off
//! Apple's platforms, so `gallery_scan::classify` is a hand-maintained table;
//! this is what keeps it honest for every extension the fixture set contains.
//!
//! Extensions *outside* the fixture set are the port's own judgement. See the
//! port notes for the list and for why it errs narrow.

use std::path::PathBuf;

use gallery_scan::{classify, MediaKind};
use serde::Deserialize;

#[derive(Deserialize)]
struct Dump {
    files: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    path: String,
    #[serde(rename = "scannerKind")]
    scanner_kind: String,
}

#[test]
fn every_fixture_asset_classifies_the_way_uttype_classified_it() {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "scan-conformance",
        "metadata_conformance.json",
    ]
    .iter()
    .collect();
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    let dump: Dump = serde_json::from_slice(&bytes).expect("metadata_conformance.json");
    assert!(dump.files.len() >= 50);

    let mut wrong = Vec::new();
    for entry in &dump.files {
        let name = entry.path.rsplit('/').next().unwrap();
        let got = match classify(name) {
            MediaKind::Image => "image",
            MediaKind::Video => "video",
            // The fixture has one bucket for "the scanner never sees it";
            // this crate splits sidecars out of it, and `.xmp` files are not
            // in the fixture's file list at all.
            MediaKind::Sidecar | MediaKind::Skipped => "skipped",
        };
        if got != entry.scanner_kind {
            wrong.push(format!(
                "{}: expected {} got {got}",
                entry.path, entry.scanner_kind
            ));
        }
    }
    assert!(
        wrong.is_empty(),
        "the extension table disagrees with UTType:\n{}",
        wrong.join("\n")
    );
}

/// The two directions of the extension-vs-content disagreement, spelled out.
#[test]
fn classification_is_by_extension_and_only_by_extension() {
    // PNG bytes named `.jpg`: the scanner takes it as an image, and
    // `MetadataReader` reads it fine because ImageIO sniffs content.
    assert_eq!(classify("actually_png.jpg"), MediaKind::Image);
    // JPEG bytes named `.txt`: the scanner never sees it at all, even though
    // the reader would happily parse it.
    assert_eq!(classify("actually_jpeg.txt"), MediaKind::Skipped);
}
