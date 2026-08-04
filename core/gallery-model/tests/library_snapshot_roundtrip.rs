//! `library_snapshot_v20.json`, decoded and re-encoded by the Rust port.
//!
//! The fixture is not a hand-written example — it came off the app's real save
//! path (`JSONDiskCache<LibrarySnapshot>.save`, a stock `JSONEncoder` over
//! `{version, value}`), with the temp-dir paths rebased and a few photos
//! decorated so both encoder branches (optional present / absent) appear.
//!
//! Two directions are checked, because only one of them fails loudly:
//!
//! 1. **decode → re-encode → compare** proves nothing is dropped in transit.
//!    A field the Rust decoder does not know would silently vanish from the
//!    re-encoded copy.
//! 2. **encode from scratch** proves the shape is right for a Swift *decoder*
//!    — key names, value representations, and which keys exist at all.
//!
//! Key *order* is explicitly not part of the contract: `JSONEncoder` emits a
//! keyed container's members in an order that is not stable even within one
//! process, which is why comparisons here are on the parsed JSON object.

use std::path::PathBuf;

use gallery_model::date::AppleDate;
use gallery_model::photo::{
    FaceRegion, FileUrl, HierarchicalTag, PhotoFile, PhotoFolder, StableId,
};
use gallery_model::snapshot::{self, DownloadStatus, LibrarySnapshot, LIBRARY_SNAPSHOT_VERSION};

fn fixture_bytes() -> Vec<u8> {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "scan-conformance",
        "library_snapshot_v20.json",
    ]
    .iter()
    .collect();
    std::fs::read(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn json(bytes: &[u8]) -> serde_json::Value {
    serde_json::from_slice(bytes).expect("fixture is valid JSON")
}

#[test]
fn the_committed_snapshot_decodes() {
    assert_eq!(snapshot::probe_version(&fixture_bytes()), Ok(20));
    let library = snapshot::load(&fixture_bytes()).expect("the shipped wire format must decode");

    assert_eq!(library.all_photos.len(), 5);
    assert_eq!(library.root_folder.name, "PhotoLibrary");
    assert_eq!(library.root_folder.total_photo_count, 5);
    // `_plans/06` Finding 2's field, added to v20 *without* a version bump.
    let manifest = library
        .sidecar_manifest
        .as_ref()
        .expect("the fixture carries a manifest since Finding 2 landed");
    assert_eq!(manifest.len(), 1);
    assert_eq!(
        manifest[0].sidecar_url.path(),
        "/fixtures/PhotoLibrary/2021/IMG_0001.jpg.xmp"
    );
    assert_eq!(
        manifest[0].photo_id,
        StableId::for_photo("/fixtures/PhotoLibrary/2021/IMG_0001.jpg")
    );
    assert_eq!(
        manifest[0].current_version.content_identifier.as_deref(),
        Some("1234567"),
        "the identifier is a JSON string on both sides of the boundary"
    );
    assert_eq!(manifest[0].download_status, DownloadStatus::Local);

    // …and the other half of the no-bump decision: a v20 file written *before*
    // the field existed still decodes, at the same version, with `None`. That
    // is what stops the upgrade costing every installed library a full rescan.
    let mut legacy = json(&fixture_bytes());
    legacy["value"]
        .as_object_mut()
        .expect("value is an object")
        .remove("sidecarManifest");
    let legacy_bytes = serde_json::to_vec(&legacy).unwrap();
    assert_eq!(snapshot::probe_version(&legacy_bytes), Ok(20));
    assert_eq!(
        snapshot::load(&legacy_bytes).unwrap().sidecar_manifest,
        None,
        "absent must stay distinguishable from an empty manifest"
    );

    // Paths come back as paths, not URL strings — that is what the VFS and
    // `stable_uuid` take.
    let decorated = library
        .all_photos
        .iter()
        .find(|p| p.filename == "IMG_0001")
        .expect("IMG_0001");
    assert_eq!(decorated.path(), "/fixtures/PhotoLibrary/2021/IMG_0001.jpg");
    assert_eq!(decorated.date_taken, Some(AppleDate(651_234_567.25)));
    assert_eq!(decorated.country_code.as_deref(), Some("IT"));
    assert_eq!(decorated.gps_latitude, Some(41.9028));
    assert_eq!(decorated.face_regions.len(), 2);
    assert_eq!(decorated.face_regions[1].name, None);
    assert_eq!(
        decorated
            .live_photo_video_url
            .as_ref()
            .map(|u| u.path().to_string()),
        Some("/fixtures/PhotoLibrary/2021/IMG_0001.mov".to_string())
    );

    // The decomposed name survives byte-for-byte. Rust's `==` is byte
    // equality, so unlike Swift this assertion can actually see the
    // difference between the two spellings.
    let unicode = library
        .all_photos
        .iter()
        .find(|p| p.path().contains("nicode"))
        .expect("the decomposed entry");
    assert_eq!(
        unicode.path(),
        "/fixtures/PhotoLibrary/2021/Trip/U\u{308}nicode cafe\u{301}.jpg"
    );
    assert!(
        !unicode.path().contains('\u{dc}'),
        "the precomposed U-umlaut would derive a different stable id"
    );
}

#[test]
fn decoding_and_re_encoding_loses_nothing() {
    let original = json(&fixture_bytes());
    let library = snapshot::load(&fixture_bytes()).unwrap();
    let re_encoded = json(&snapshot::save(&library).unwrap());
    assert_eq!(
        re_encoded, original,
        "a round trip through the Rust types changed the wire format"
    );
}

#[test]
fn ids_in_the_fixture_are_the_ids_the_paths_derive() {
    // The fixture cannot commit an absolute path, so it commits the ids and
    // the URLs and lets this re-derive the link between them — the same trick
    // `ScannerConformanceTests` uses with `idMatchesStableUUIDOfPath`.
    let library = snapshot::load(&fixture_bytes()).unwrap();
    for photo in &library.all_photos {
        assert_eq!(
            photo.id,
            StableId::for_photo(photo.path()),
            "{} carries an id its path does not derive",
            photo.path()
        );
    }
    fn check(folder: &PhotoFolder) {
        assert_eq!(
            folder.id,
            StableId::for_folder(folder.url.path()),
            "{}",
            folder.url.path()
        );
        folder.subfolders.iter().for_each(check);
    }
    check(&library.root_folder);
}

#[test]
fn an_encode_from_scratch_has_the_shape_swift_decodes() {
    let mut photo = PhotoFile::new("/fixtures/PhotoLibrary/2021/IMG_9999.jpg", "IMG_9999", 4096);
    photo.date_taken = Some(AppleDate(651_234_567.25));
    photo.date_from_metadata = true;
    photo.hierarchical_tags = vec![
        HierarchicalTag::new("People/Alice"),
        HierarchicalTag::new("flat-tag"),
    ];
    photo.face_regions = vec![FaceRegion {
        name: None,
        center_x: 0.6,
        center_y: 0.4,
        width: 0.05,
        height: 0.05,
    }];

    let folder = PhotoFolder {
        id: StableId::for_folder("/fixtures/PhotoLibrary"),
        url: FileUrl::new("/fixtures/PhotoLibrary"),
        name: "PhotoLibrary".into(),
        subfolders: vec![],
        photos: vec![photo.clone()],
        cover_photo_url: Some(FileUrl::new(photo.path())),
        total_photo_count: 1,
        date_modified: Some(AppleDate(700_000_000.0)),
        date_created: None,
    };
    let bytes = snapshot::save(&LibrarySnapshot {
        root_folder: folder,
        all_photos: vec![photo],
        sidecar_manifest: None,
    })
    .unwrap();
    let value = json(&bytes);

    assert_eq!(value["version"], LIBRARY_SNAPSHOT_VERSION);
    let library = &value["value"];
    let mut library_keys: Vec<&str> = library
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    library_keys.sort_unstable();
    assert_eq!(library_keys, vec!["allPhotos", "rootFolder"]);

    let encoded = &library["allPhotos"][0];
    // Dates are NUMBERS on Apple's 2001 epoch, never strings.
    assert_eq!(encoded["dateTaken"].as_f64(), Some(651_234_567.25));
    // URLs are percent-encoded absoluteStrings.
    assert_eq!(
        encoded["url"].as_str(),
        Some("file:///fixtures/PhotoLibrary/2021/IMG_9999.jpg")
    );
    // UUIDs are uppercase hyphenated.
    let id = encoded["id"].as_str().unwrap();
    assert_eq!(id, id.to_uppercase());
    assert_eq!(id.len(), 36);
    // Nil optionals are omitted at every level.
    assert!(encoded.get("countryCode").is_none());
    assert!(encoded["hierarchicalTags"][1].get("namespace").is_none());
    assert!(encoded["faceRegions"][0].get("name").is_none());
    // Runtime-only state never appears.
    for key in ["locality", "sidecarStatus", "dimensions", "exif"] {
        assert!(encoded.get(key).is_none(), "{key} must not be persisted");
    }
    // A folder with no dateCreated omits it, but keeps dateModified.
    assert!(library["rootFolder"].get("dateCreated").is_none());
    assert_eq!(library["rootFolder"]["dateModified"].as_f64(), Some(7e8));
}

#[test]
fn a_version_bump_evicts_rather_than_guessing() {
    let mut value = json(&fixture_bytes());
    value["version"] = serde_json::json!(19);
    let bytes = serde_json::to_vec(&value).unwrap();
    assert!(matches!(
        snapshot::load(&bytes),
        Err(gallery_model::SnapshotError::VersionMismatch { found: 19, .. })
    ));
}
