//! Phase-3 conformance fixtures, read from Rust.
//!
//! `core/fixtures/scan-conformance/` holds the spec the scanner/metadata port
//! has to satisfy: one copy in the repo, bundled into `LocalGalleryTests` as a
//! folder resource and read here straight off disk — the same arrangement as
//! `stable_uuid_vectors.json` and `expected_tags.json`.
//!
//! What this file does *today* is deliberately narrow: it proves the fixtures
//! parse from Rust, pins the invariants a porting mistake would break first,
//! and asserts the landmines are still recorded. It does not implement the
//! port. When `gallery-scan` / the `gallery-meta` read side land, their tests
//! replace these assertions with real comparisons against real output — and
//! this file's job becomes making sure nobody quietly deletes a landmine
//! fixture instead of matching it.
//!
//! Lives in `gallery-model` because that is already where the cross-language
//! conformance vectors live; move it when the crates that consume the
//! fixtures exist.

use serde::Deserialize;
use std::path::PathBuf;

fn fixture(name: &str) -> String {
    // core/gallery-model → core → fixtures/scan-conformance
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "scan-conformance",
        name,
    ]
    .iter()
    .collect();
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn json(name: &str) -> serde_json::Value {
    serde_json::from_str(&fixture(name)).unwrap_or_else(|e| panic!("{name} is not valid JSON: {e}"))
}

// ---------------------------------------------------------------------------
// metadata_conformance.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct MetadataDump {
    schema: u32,
    files: Vec<MetadataEntry>,
}

#[derive(Deserialize)]
struct MetadataEntry {
    path: String,
    #[serde(rename = "scannerKind")]
    scanner_kind: String,
    #[serde(rename = "hasSidecar")]
    has_sidecar: bool,
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
    notes: Vec<String>,
}

#[derive(Deserialize)]
struct ConformanceDate {
    basis: String,
    value: String,
}

#[derive(Deserialize)]
struct Tag {
    #[serde(rename = "fullPath")]
    full_path: String,
    namespace: Option<String>,
    #[serde(rename = "displayName")]
    display_name: String,
}

#[derive(Deserialize)]
struct Region {
    name: Option<String>,
    #[serde(rename = "centerX")]
    center_x: f64,
    #[serde(rename = "centerY")]
    center_y: f64,
    width: f64,
    height: f64,
}

fn metadata() -> MetadataDump {
    serde_json::from_str(&fixture("metadata_conformance.json"))
        .expect("metadata_conformance.json does not match the expected shape")
}

fn entry<'a>(dump: &'a MetadataDump, path: &str) -> &'a MetadataEntry {
    dump.files
        .iter()
        .find(|e| e.path == path)
        .unwrap_or_else(|| panic!("no fixture entry for {path}"))
}

#[test]
fn metadata_fixture_deserializes() {
    let dump = metadata();
    assert_eq!(dump.schema, 1);
    assert!(
        dump.files.len() >= 50,
        "the asset tree looks truncated: {} entries",
        dump.files.len()
    );
    // Sorted by path, so the port can compare positionally.
    let mut sorted: Vec<&str> = dump.files.iter().map(|e| e.path.as_str()).collect();
    let original = sorted.clone();
    sorted.sort_unstable();
    assert_eq!(sorted, original, "entries must stay sorted by path");

    for e in &dump.files {
        assert!(
            matches!(e.scanner_kind.as_str(), "image" | "video" | "skipped"),
            "{}: unexpected scannerKind {}",
            e.path,
            e.scanner_kind
        );
        if let Some(d) = &e.date_taken {
            assert_eq!(d.basis, "localWallClock", "{}", e.path);
            assert!(!d.value.is_empty());
        }
        if let Some(d) = &e.video_date {
            assert_eq!(d.basis, "utc", "{}", e.path);
            assert!(d.value.ends_with('Z'), "{}", e.path);
        }
        if e.video_date.is_some() {
            assert_eq!(e.scanner_kind, "video", "{}", e.path);
        }
        for t in &e.hierarchical_tags {
            // The namespace is the first `/`-separated segment, and only when
            // there is more than one.
            match t.full_path.split('/').count() {
                1 => assert!(t.namespace.is_none(), "{}: {}", e.path, t.full_path),
                _ => assert!(t.namespace.is_some(), "{}: {}", e.path, t.full_path),
            }
            assert!(t.full_path.ends_with(&t.display_name), "{}", t.full_path);
        }
        for r in &e.face_regions {
            assert!(r.width > 0.0 && r.height > 0.0, "{}", e.path);
            let _ = (r.center_x, r.center_y, &r.name);
        }
        if let Some(cc) = &e.country_code {
            assert_eq!(cc, &cc.to_uppercase(), "country codes are uppercased");
        }
    }
}

/// The landmines. Each of these is a place the obvious Rust implementation
/// would be *more correct* than the Swift baseline — and therefore wrong.
#[test]
fn metadata_fixture_still_records_the_known_oddities() {
    let dump = metadata();

    // 1. MWG region names are shifted by one when Area precedes Name.
    let shifted = entry(&dump, "regions/exiftool_order.jpg");
    let names: Vec<Option<&str>> = shifted
        .face_regions
        .iter()
        .map(|r| r.name.as_deref())
        .collect();
    assert_eq!(
        names,
        vec![None, Some("Alice"), Some("Bob")],
        "the backwards-Name off-by-one must stay pinned; \
         the sidecar was written Alice, Bob, Carol"
    );
    let correct = entry(&dump, "regions/digikam_order.jpg");
    assert_eq!(
        correct
            .face_regions
            .iter()
            .map(|r| r.name.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("Alice"), Some("Bob"), Some("Carol")],
        "Name-before-Area is the ordering that works"
    );

    // 2. ImageIO re-serialises struct fields alphabetically, so EVERY embedded
    //    region hits the same off-by-one regardless of how it was written.
    for path in [
        "xmp/regions_digikam_order.jpg",
        "xmp/regions_exiftool_order.jpg",
    ] {
        let e = entry(&dump, path);
        assert_eq!(
            e.face_regions.first().and_then(|r| r.name.as_deref()),
            None,
            "{path}: embedded regions come back with the first one unnamed"
        );
    }

    // 3. Sidecar-vs-embedded precedence.
    let conflict = entry(&dump, "sidecar/conflict.jpg");
    assert_eq!(
        conflict
            .hierarchical_tags
            .iter()
            .map(|t| t.full_path.as_str())
            .collect::<Vec<_>>(),
        vec!["People/Alice", "Objects/Car", "Scenes/Beach"],
        "union, embedded first, and the EMBEDDED spelling wins a case conflict"
    );
    assert_eq!(conflict.country_code.as_deref(), Some("IT"), "embedded wins");
    assert_eq!(
        conflict
            .face_regions
            .iter()
            .map(|r| r.name.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("SidecarFace")],
        "sidecar regions replace embedded ones outright"
    );

    // 4. A sidecar's dates and GPS are read by nobody.
    let ignored = entry(&dump, "sidecar/date_and_gps_ignored.jpg");
    assert!(ignored.has_sidecar);
    assert!(ignored.date_taken.is_none());
    assert!(ignored.gps_latitude.is_none() && ignored.gps_longitude.is_none());

    // 5. EXIF date parsing: month 13 and the 0000:00:00 sentinel are rejected
    //    (fall through to DateTimeDigitized) but hour 24 rolls over.
    assert_eq!(
        entry(&dump, "exif/zero_date.jpg")
            .date_taken
            .as_ref()
            .map(|d| d.value.as_str()),
        Some("2020-05-05T05:05:05.000")
    );
    assert_eq!(
        entry(&dump, "exif/impossible_date.jpg")
            .date_taken
            .as_ref()
            .map(|d| d.value.as_str()),
        Some("2021-07-04T08:09:10.000")
    );
    assert_eq!(
        entry(&dump, "exif/hour_24.jpg")
            .date_taken
            .as_ref()
            .map(|d| d.value.as_str()),
        Some("2021-07-05T00:00:00.000"),
        "hour 24 rolls into the next day — a strict 0..=23 parser would return None"
    );
    // Subseconds and the offset are dropped: the format has no field for them.
    assert_eq!(
        entry(&dump, "exif/full.jpg")
            .date_taken
            .as_ref()
            .map(|d| d.value.as_str()),
        Some("2021-07-04T08:09:10.000")
    );

    // 6. GPS refs are compared case-sensitively.
    let lower = entry(&dump, "gps/zero_and_lowercase_ref.jpg");
    assert!(
        lower.gps_longitude.unwrap() > 0.0,
        "a lowercase \"w\" ref does not negate"
    );

    // 7. Only digiKam:TagsList feeds the tag list.
    let disagree = entry(&dump, "xmp/tag_sources_disagree.jpg");
    assert_eq!(
        disagree
            .hierarchical_tags
            .iter()
            .map(|t| t.full_path.as_str())
            .collect::<Vec<_>>(),
        vec!["People/Alice"],
        "lr:hierarchicalSubject and dc:subject are invisible"
    );

    // 8. Video dates: QuickTime only, offsets applied, zone-less read as UTC.
    assert_eq!(
        entry(&dump, "video/qt_offset.mov")
            .video_date
            .as_ref()
            .map(|d| d.value.as_str()),
        Some("2018-06-15T09:03:07.000Z")
    );
    assert_eq!(
        entry(&dump, "video/qt_naive.mov")
            .video_date
            .as_ref()
            .map(|d| d.value.as_str()),
        Some("2019-09-09T09:09:09.000Z"),
        "a zone-less QuickTime ©day is UTC, unlike a zone-less EXIF date"
    );
    assert!(
        entry(&dump, "video/isom_udta.mp4").video_date.is_none(),
        "an ISO-branded MP4 with moov/udta/@day reads as nil — a Rust atom \
         parser that accepts it would be MORE permissive than the baseline"
    );

    // Every landmine entry carries its explanation with it.
    for path in [
        "regions/exiftool_order.jpg",
        "regions/malformed_first.jpg",
        "sidecar/conflict.jpg",
        "video/isom_udta.mp4",
        "exif/hour_24.jpg",
    ] {
        assert!(
            !entry(&dump, path).notes.is_empty(),
            "{path} lost its notes"
        );
    }
}

// ---------------------------------------------------------------------------
// scanner_conformance.json + scanner_tree.json
// ---------------------------------------------------------------------------

#[test]
fn scanner_fixture_deserializes_and_pins_the_light_scan_blind_spot() {
    let dump = json("scanner_conformance.json");
    assert_eq!(dump["schema"], 1);
    let passes = dump["passes"].as_array().expect("passes");
    let names: Vec<&str> = passes.iter().map(|p| p["name"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        vec![
            "1-full-cold",
            "2-light-after-mutations",
            "3-full-after-mutations",
            "4-light-after-unlock",
        ]
    );

    let strings = |v: &serde_json::Value| -> Vec<String> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap().to_string())
            .collect()
    };

    // Light never notices a change to a file it already knows; full does.
    assert!(!strings(&passes[1]["modifiedPaths"]).contains(&"a.jpg".to_string()));
    assert!(strings(&passes[2]["modifiedPaths"]).contains(&"a.jpg".to_string()));

    // A same-size, same-mtime rewrite is invisible to both.
    for p in passes {
        assert!(
            !strings(&p["modifiedPaths"])
                .iter()
                .any(|s| s.contains("emoji")),
            "neither scan kind hashes content"
        );
    }

    // An unreadable directory is reported, and its photos are NOT reported as
    // removed — that carry-forward is what stops a transient I/O error from
    // wiping a subtree.
    assert_eq!(strings(&passes[1]["failedDirectoryPaths"]), vec!["Locked"]);
    assert_eq!(strings(&passes[2]["failedDirectoryPaths"]), vec!["Locked"]);
    assert!(passes[3]["failedDirectoryPaths"]
        .as_array()
        .unwrap()
        .is_empty());
    for i in 1..=3 {
        let removed = strings(&passes[i]["removedPaths"]);
        assert_eq!(removed, vec!["Nested/nested1.jpg"], "pass {}", i + 1);
    }

    // Ids are derived from the absolute path, so the fixture records the
    // match rather than the value.
    for p in passes {
        for photo in p["flatPhotos"].as_array().unwrap() {
            assert_eq!(photo["idMatchesStableUUIDOfPath"], true);
        }
    }

    // Folder order is specified; within-folder order is not.
    let root = &passes[0]["rootFolder"];
    let subs: Vec<&str> = root["subfolders"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        subs,
        vec!["Empty", "Junk", "Locked", "Media", "Nested", "Unicode"],
        "subdirectories are visited in ascending localizedStandardCompare order"
    );
    assert_eq!(root["totalPhotoCount"], 15);

    // A standalone video's filename is lowercased; an image's is not.
    let photos = passes[0]["flatPhotos"].as_array().unwrap();
    let find = |path: &str| {
        photos
            .iter()
            .find(|p| p["path"] == path)
            .unwrap_or_else(|| panic!("no photo {path}"))
    };
    assert_eq!(find("Media/Clip.MOV")["filename"], "clip");
    assert_eq!(find("B.JPG")["filename"], "B");

    // A video never gets a sidecar manifest row, even with a .xmp next to it.
    let manifest_paths: Vec<&str> = passes[0]["sidecarManifest"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["photoPath"].as_str().unwrap())
        .collect();
    assert!(!manifest_paths.contains(&"Media/Clip.MOV"));
    assert!(manifest_paths.contains(&"B.JPG"));
}

#[test]
fn scanner_fixture_pins_both_normalization_forms() {
    let dump = json("scanner_conformance.json");
    let photos = dump["passes"][0]["flatPhotos"].as_array().unwrap();
    let forms: Vec<&str> = photos
        .iter()
        .map(|p| p["pathNormalization"].as_str().unwrap())
        .collect();
    assert!(
        forms.contains(&"NFD"),
        "the decomposed fixture path was normalized away"
    );
    assert!(
        forms.contains(&"NFC"),
        "the precomposed fixture path was normalized away"
    );

    // …and the recorded token still describes the recorded bytes. Rust string
    // equality is byte equality, so unlike Swift it can check this directly.
    for p in photos {
        let path = p["path"].as_str().unwrap();
        let form = p["pathNormalization"].as_str().unwrap();
        let has_combining = path.chars().any(|c| ('\u{0300}'..='\u{036F}').contains(&c));
        match form {
            "NFD" => assert!(has_combining, "{path} is tagged NFD but carries no combining mark"),
            "NFC" => assert!(!has_combining, "{path} is tagged NFC but carries a combining mark"),
            "ascii" => assert!(path.is_ascii() || !has_combining, "{path}"),
            other => panic!("{path}: unexpected normalization token {other}"),
        }
    }
}

#[test]
fn scanner_tree_keeps_the_decomposed_input_path() {
    let tree = json("scanner_tree.json");
    let files: Vec<&str> = tree["initial"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e["file"].as_str())
        .collect();
    assert!(
        files.iter().any(|f| f.contains('\u{0301}')),
        "the NFD input path lost its combining acute — the Unicode cases are \
         now duplicates of each other"
    );
    assert!(
        files.iter().any(|f| f.contains('\u{00e9}')),
        "the NFC input path lost its precomposed é"
    );
    assert_eq!(tree["root"], "ScannerFixtureLibrary");
}

// ---------------------------------------------------------------------------
// library_snapshot_v20.json
// ---------------------------------------------------------------------------

/// The persisted-library wire format. serde has to read exactly this and emit
/// something Swift decodes identically, or a warm relaunch after the port
/// turns into a full rescan.
#[test]
fn library_snapshot_fixture_matches_the_documented_encoding() {
    let snapshot = json("library_snapshot_v20.json");

    // Envelope: version probed before the payload.
    assert_eq!(snapshot["version"], 20);
    let value = &snapshot["value"];
    let keys: Vec<&String> = value.as_object().unwrap().keys().collect();
    assert_eq!(keys.len(), 2, "LibrarySnapshot has exactly two fields today");
    assert!(value.get("rootFolder").is_some() && value.get("allPhotos").is_some());

    let photos = value["allPhotos"].as_array().unwrap();
    assert_eq!(photos.len(), 5);

    for p in photos {
        // URLs are absoluteString: percent-encoded file:// URLs.
        let url = p["url"].as_str().expect("url is a string");
        assert!(url.starts_with("file:///fixtures/PhotoLibrary/"), "{url}");
        assert!(!url.contains(' '), "spaces are percent-encoded: {url}");
        // UUIDs are uppercase hyphenated strings.
        let id = p["id"].as_str().expect("id is a string");
        assert_eq!(id, id.to_uppercase(), "{id}");
        assert_eq!(id.len(), 36);
        // Dates are NUMBERS, never strings.
        for key in ["dateTaken", "enrichedFileDate", "fileModificationDate"] {
            if let Some(v) = p.get(key) {
                assert!(v.is_f64() || v.is_i64(), "{key} must be a number, got {v}");
            }
        }
        // Runtime-only fields are never persisted.
        for key in ["locality", "sidecarStatus", "dimensions", "exif"] {
            assert!(p.get(key).is_none(), "{key} must not be persisted");
        }
    }

    // Dates are seconds since the 2001-01-01 reference date, not the Unix
    // epoch — a Unix-epoch reading of this value lands in 1990.
    let decorated = photos
        .iter()
        .find(|p| p["filename"] == "IMG_0001")
        .expect("IMG_0001");
    assert_eq!(decorated["dateTaken"].as_f64().unwrap(), 651_234_567.25);

    // Nil optionals are OMITTED, not null.
    let bare = photos
        .iter()
        .find(|p| p["filename"] == "IMG_0002")
        .expect("IMG_0002");
    let bare_keys: std::collections::BTreeSet<&str> =
        bare.as_object().unwrap().keys().map(|s| s.as_str()).collect();
    assert_eq!(
        bare_keys,
        [
            "dateFromMetadata",
            "faceRegions",
            "fileSize",
            "filename",
            "hierarchicalTags",
            "id",
            "isVideo",
            "url",
        ]
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>(),
        "an all-nil photo carries only the non-optional keys"
    );
    for key in ["dateTaken", "countryCode", "gpsLatitude", "livePhotoVideoURL"] {
        assert!(bare.get(key).is_none(), "{key} must be omitted, not null");
    }
    // Nested optionals behave the same way.
    let tags = decorated["hierarchicalTags"].as_array().unwrap();
    let flat = tags.iter().find(|t| t["fullPath"] == "flat-tag").unwrap();
    assert!(flat.get("namespace").is_none());
    let regions = decorated["faceRegions"].as_array().unwrap();
    assert!(regions[1].get("name").is_none());

    // The URL for the non-ASCII name is DECOMPOSED: Foundation's
    // URL(fileURLWithPath:) normalizes to NFD, so "Ü" is written as
    // "U" + U+0308 = "U%CC%88", never "%C3%9C".
    let unicode = photos
        .iter()
        .map(|p| p["url"].as_str().unwrap())
        .find(|u| u.contains("U%CC%88"))
        .expect("the decomposed Ü URL");
    assert!(!unicode.contains("%C3%9C"));
    assert!(unicode.contains("%20"));
}
