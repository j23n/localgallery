//! The Rust read side, run over the same assets the Swift harness ran over.
//!
//! `core/fixtures/scan-conformance/metadata_conformance.json` is not a
//! hand-written expectation: `MetadataConformanceTests` produced it by running
//! the shipping `MetadataReader` over `assets/`. This file runs
//! [`gallery_meta::read_image_metadata`] over the identical bytes and compares
//! field by field. A disagreement means the port changed what a photo's date,
//! location, tags or faces are — not that a test is fussy.
//!
//! The `notes` on each fixture entry explain *why* each expectation is what it
//! is; several of them are the only written record of a bug this port has to
//! keep. Read them before "fixing" a failure here.

use std::path::PathBuf;

use gallery_meta::media::{read_image_metadata, read_video_date};
use gallery_model::date::AppleDate;
use gallery_vfs::StdVfs;
use serde::Deserialize;

/// Coordinates are floats that made a round trip through ImageIO's
/// rational-to-double conversion and JSON. `41.9028` and
/// `41.90280000000001` are the same place; a bit-exact comparison would fail
/// on which order the degrees/minutes/seconds were summed in.
const EPSILON: f64 = 1e-9;

// ---------------------------------------------------------------------------
// Fixture shape
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct Dump {
    schema: u32,
    files: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    path: String,
    #[serde(rename = "scannerKind")]
    scanner_kind: String,
    #[serde(rename = "dateTaken")]
    date_taken: Option<ConformanceDate>,
    #[serde(rename = "videoDate")]
    video_date: Option<ConformanceDate>,
    #[serde(rename = "countryCode")]
    country_code: Option<String>,
    #[serde(rename = "gpsLatitude")]
    gps_latitude: Option<f64>,
    #[serde(rename = "gpsLongitude")]
    gps_longitude: Option<f64>,
    #[serde(rename = "hierarchicalTags")]
    hierarchical_tags: Vec<Tag>,
    #[serde(rename = "faceRegions")]
    face_regions: Vec<Region>,
}

#[derive(Deserialize)]
struct ConformanceDate {
    basis: String,
    value: String,
}

#[derive(Deserialize, PartialEq, Debug)]
struct Tag {
    #[serde(rename = "fullPath")]
    full_path: String,
    namespace: Option<String>,
    #[serde(rename = "displayName")]
    display_name: String,
}

#[derive(Deserialize, Debug)]
struct Region {
    name: Option<String>,
    #[serde(rename = "centerX")]
    center_x: f64,
    #[serde(rename = "centerY")]
    center_y: f64,
    width: f64,
    height: f64,
}

fn fixtures_dir() -> PathBuf {
    [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "scan-conformance",
    ]
    .iter()
    .collect()
}

fn dump() -> Dump {
    let path = fixtures_dir().join("metadata_conformance.json");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_slice(&bytes).expect("metadata_conformance.json does not match its shape")
}

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

/// Accumulates every mismatch instead of stopping at the first, so one run
/// tells you the whole story rather than one sentence of it.
#[derive(Default)]
struct Failures(Vec<String>);

impl Failures {
    fn check(
        &mut self,
        path: &str,
        field: &str,
        expected: impl std::fmt::Debug,
        got: impl std::fmt::Debug,
        ok: bool,
    ) {
        if !ok {
            self.0.push(format!(
                "{path}: {field}\n    expected {expected:?}\n    got      {got:?}"
            ));
        }
    }

    fn finish(self, checked: usize) {
        if !self.0.is_empty() {
            panic!(
                "{} of {checked} metadata conformance cases diverged:\n\n{}\n",
                self.0.len(),
                self.0.join("\n")
            );
        }
    }
}

fn eq_opt_f64(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => (a - b).abs() <= EPSILON,
        _ => false,
    }
}

#[test]
fn every_asset_reads_exactly_what_the_swift_reader_read() {
    let dump = dump();
    assert_eq!(dump.schema, 1);
    assert!(dump.files.len() >= 50, "the asset tree looks truncated");

    let assets = fixtures_dir().join("assets");
    let vfs = StdVfs::new();
    let mut failures = Failures::default();

    for entry in &dump.files {
        let path = assets.join(&entry.path);
        let path = path.to_str().expect("fixture paths are UTF-8");
        let got = read_image_metadata(&vfs, path);
        let name = &entry.path;

        // --- capture date -------------------------------------------------
        // A zone-less wall clock on both sides: the fixture's `localWallClock`
        // basis exists precisely because the absolute instant depends on the
        // machine's time zone and is therefore not portable.
        let expected_date = entry.date_taken.as_ref().map(|d| {
            assert_eq!(d.basis, "localWallClock", "{name}");
            d.value.clone()
        });
        let got_date = got.capture_wall_clock.map(|d| d.format_millis(false));
        failures.check(
            name,
            "dateTaken",
            &expected_date,
            &got_date,
            expected_date == got_date,
        );

        // --- GPS ----------------------------------------------------------
        failures.check(
            name,
            "gpsLatitude",
            entry.gps_latitude,
            got.gps_latitude,
            eq_opt_f64(entry.gps_latitude, got.gps_latitude),
        );
        failures.check(
            name,
            "gpsLongitude",
            entry.gps_longitude,
            got.gps_longitude,
            eq_opt_f64(entry.gps_longitude, got.gps_longitude),
        );

        // --- country ------------------------------------------------------
        failures.check(
            name,
            "countryCode",
            &entry.country_code,
            &got.country_code,
            entry.country_code == got.country_code,
        );

        // --- tags ---------------------------------------------------------
        let got_tags: Vec<Tag> = got
            .hierarchical_tags
            .iter()
            .map(|t| Tag {
                full_path: t.full_path.clone(),
                namespace: t.namespace.clone(),
                display_name: t.display_name.clone(),
            })
            .collect();
        failures.check(
            name,
            "hierarchicalTags",
            &entry.hierarchical_tags,
            &got_tags,
            entry.hierarchical_tags == got_tags,
        );

        // --- regions ------------------------------------------------------
        let regions_match = entry.face_regions.len() == got.face_regions.len()
            && entry
                .face_regions
                .iter()
                .zip(&got.face_regions)
                .all(|(e, g)| {
                    e.name == g.name
                        && (e.center_x - g.center_x).abs() <= EPSILON
                        && (e.center_y - g.center_y).abs() <= EPSILON
                        && (e.width - g.width).abs() <= EPSILON
                        && (e.height - g.height).abs() <= EPSILON
                });
        failures.check(
            name,
            "faceRegions",
            &entry.face_regions,
            &got.face_regions,
            regions_match,
        );

        // --- video date ---------------------------------------------------
        // Run only for entries the scanner classifies as video, matching the
        // Swift harness — `readVideoDate` on a JPEG is not a case anyone has
        // an expectation for.
        if entry.scanner_kind == "video" {
            let expected = entry.video_date.as_ref().map(|d| {
                assert_eq!(d.basis, "utc", "{name}");
                d.value.clone()
            });
            let got_video = read_video_date(&std::fs::read(assets.join(&entry.path)).unwrap())
                .map(|secs| AppleDate::from_unix_secs_f64(secs as f64).to_utc_string());
            failures.check(
                name,
                "videoDate",
                &expected,
                &got_video,
                expected == got_video,
            );
        } else {
            failures.check(
                name,
                "videoDate",
                "none (not a video)",
                entry.video_date.as_ref().map(|d| &d.value),
                entry.video_date.is_none(),
            );
        }
    }

    failures.finish(dump.files.len());
}

/// The runner above is only meaningful if it actually opened the assets. A
/// typo'd path would read as "no metadata anywhere" and pass every `None`
/// expectation.
#[test]
fn the_assets_are_where_the_runner_looks_for_them() {
    let assets = fixtures_dir().join("assets");
    for entry in &dump().files {
        let path = assets.join(&entry.path);
        assert!(path.is_file(), "missing fixture asset {}", path.display());
    }
    let vfs = StdVfs::new();
    let loaded = read_image_metadata(&vfs, assets.join("xmp/tagslist.jpg").to_str().unwrap());
    assert_eq!(
        loaded.hierarchical_tags.len(),
        3,
        "the runner is reading empty files"
    );
}
