//! The Rust scanner, run over the same tree the Swift harness ran over.
//!
//! `ScannerConformanceTests` built the library described by
//! `scanner_tree.json`, ran four `FolderScanner.scan` passes over it, and
//! recorded everything in `scanner_conformance.json`:
//!
//! | pass | kind | cache | tree |
//! |---|---|---|---|
//! | `1-full-cold` | full | empty | initial |
//! | `2-light-after-mutations` | light | pass 1 | mutated, `Locked/` chmod 000 |
//! | `3-full-after-mutations` | full | pass 1 | mutated, `Locked/` chmod 000 |
//! | `4-light-after-unlock` | light | pass 1 | mutated, `Locked/` readable |
//!
//! Passes 2 and 3 differ in `reuse_cached` and in nothing else, which is what
//! makes the light-scan blind spot legible: `a.jpg` is rewritten bigger and
//! newer and only the full pass reports it.
//!
//! Nothing here compares an absolute path or a UUID. Paths are relative to the
//! library root; ids are re-derived from the real absolute path and only the
//! *match* is asserted, exactly as the Swift side does.

mod support;

use std::collections::HashMap;
use std::path::Path;

use gallery_model::photo::{PhotoFile, PhotoFolder, StableId};
use gallery_model::snapshot::SidecarCandidate;
use gallery_scan::{scan, ScanInput, ScanOutcome};
use serde::Deserialize;
use support::{chmod_is_effective, fixtures_dir, unlock, ApfsLikeVfs, ScannerTree};
use unicode_normalization::UnicodeNormalization;

// ---------------------------------------------------------------------------
// Fixture shape
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct Dump {
    schema: u32,
    passes: Vec<Pass>,
}

#[derive(Deserialize)]
struct Pass {
    name: String,
    #[serde(rename = "reuseCached")]
    reuse_cached: bool,
    #[serde(rename = "needsEnrichment")]
    needs_enrichment: bool,
    #[serde(rename = "rootFolder")]
    root_folder: Option<Folder>,
    #[serde(rename = "flatPhotos")]
    flat_photos: Vec<Photo>,
    #[serde(rename = "addedPaths")]
    added_paths: Vec<String>,
    #[serde(rename = "removedPaths")]
    removed_paths: Vec<String>,
    #[serde(rename = "modifiedPaths")]
    modified_paths: Vec<String>,
    #[serde(rename = "failedDirectoryPaths")]
    failed_directory_paths: Vec<String>,
    #[serde(rename = "sidecarManifest")]
    sidecar_manifest: Vec<SidecarRow>,
    notes: Vec<String>,
}

#[derive(Deserialize, PartialEq, Debug)]
struct Folder {
    path: String,
    name: String,
    #[serde(rename = "photoCount")]
    photo_count: usize,
    #[serde(rename = "photoPaths")]
    photo_paths: Vec<String>,
    #[serde(rename = "totalPhotoCount")]
    total_photo_count: i64,
    #[serde(rename = "coverPhotoSource")]
    cover_photo_source: String,
    #[serde(rename = "hasDateModified")]
    has_date_modified: bool,
    #[serde(rename = "hasDateCreated")]
    has_date_created: bool,
    subfolders: Vec<Folder>,
}

#[derive(Deserialize, PartialEq, Debug)]
struct Photo {
    path: String,
    #[serde(rename = "pathNormalization")]
    path_normalization: String,
    filename: String,
    #[serde(rename = "filenameNormalization")]
    filename_normalization: String,
    #[serde(rename = "fileSize")]
    file_size: i64,
    #[serde(rename = "isVideo")]
    is_video: bool,
    #[serde(rename = "livePhotoVideoPath")]
    live_photo_video_path: Option<String>,
    #[serde(rename = "dateTaken")]
    date_taken: Option<ConformanceDate>,
    #[serde(rename = "dateFromMetadata")]
    date_from_metadata: bool,
    #[serde(rename = "fileModificationDate")]
    file_modification_date: Option<ConformanceDate>,
    #[serde(rename = "enrichedFileDate")]
    enriched_file_date: Option<ConformanceDate>,
    locality: String,
    #[serde(rename = "sidecarStatus")]
    sidecar_status: String,
    #[serde(rename = "countryCode")]
    country_code: Option<String>,
    #[serde(rename = "hierarchicalTagCount")]
    hierarchical_tag_count: usize,
    #[serde(rename = "faceRegionCount")]
    face_region_count: usize,
    #[serde(rename = "idMatchesStableUUIDOfPath")]
    id_matches_stable_uuid_of_path: bool,
}

#[derive(Deserialize, PartialEq, Debug)]
struct SidecarRow {
    #[serde(rename = "photoPath")]
    photo_path: String,
    #[serde(rename = "sidecarPath")]
    sidecar_path: String,
    #[serde(rename = "downloadStatus")]
    download_status: String,
    #[serde(rename = "versionHasContentIdentifier")]
    version_has_content_identifier: bool,
    #[serde(rename = "versionModificationDate")]
    version_modification_date: Option<ConformanceDate>,
    #[serde(rename = "versionSize")]
    version_size: Option<i64>,
}

#[derive(Deserialize, PartialEq, Debug)]
struct ConformanceDate {
    basis: String,
    value: String,
}

impl ConformanceDate {
    fn utc(date: Option<gallery_model::AppleDate>) -> Option<ConformanceDate> {
        date.map(|d| ConformanceDate {
            basis: "utc".into(),
            value: d.to_utc_string(),
        })
    }
}

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

/// Scalar-exact normalization form.
///
/// The Swift harness needs this token because `String ==` compares under
/// canonical equivalence and can never see a normalization change. Rust's `==`
/// can — but the token stays in the output, because the *fixture* is shared
/// and dropping a field would be a shape change.
fn normalization_form(s: &str) -> String {
    let is_nfd = s.nfd().eq(s.chars());
    let is_nfc = s.nfc().eq(s.chars());
    match (is_nfc, is_nfd) {
        (true, true) => "ascii",
        (true, false) => "NFC",
        (false, true) => "NFD",
        (false, false) => "mixed",
    }
    .to_string()
}

/// Path relative to the library root, `/`-separated; `""` for the root itself.
fn relativize(path: &str, root: &str) -> String {
    if path == root {
        return String::new();
    }
    path.strip_prefix(&format!("{root}/"))
        .unwrap_or(path)
        .to_string()
}

fn record_photo(photo: &PhotoFile, root: &str) -> Photo {
    let path = relativize(photo.path(), root);
    Photo {
        path_normalization: normalization_form(&path),
        path,
        filename_normalization: normalization_form(&photo.filename),
        filename: photo.filename.clone(),
        file_size: photo.file_size,
        is_video: photo.is_video,
        live_photo_video_path: photo
            .live_photo_video_url
            .as_ref()
            .map(|u| relativize(u.path(), root)),
        date_taken: ConformanceDate::utc(photo.date_taken),
        date_from_metadata: photo.date_from_metadata,
        file_modification_date: ConformanceDate::utc(photo.file_modification_date),
        enriched_file_date: ConformanceDate::utc(photo.enriched_file_date),
        locality: photo.locality.describe(),
        sidecar_status: match photo.sidecar_status {
            gallery_model::SidecarStatus::Absent => "absent".into(),
            gallery_model::SidecarStatus::Cached => "cached".into(),
        },
        country_code: photo.country_code.clone(),
        hierarchical_tag_count: photo.hierarchical_tags.len(),
        face_region_count: photo.face_regions.len(),
        id_matches_stable_uuid_of_path: photo.id == StableId::for_photo(photo.path()),
    }
}

fn record_folder(folder: &PhotoFolder, root: &str) -> Folder {
    let cover_photo_source = match &folder.cover_photo_url {
        None => "none".to_string(),
        Some(cover) => {
            if folder.photos.iter().any(|p| &p.url == cover) {
                "ownPhotos".to_string()
            } else if let Some(sub) = folder
                .subfolders
                .iter()
                .find(|s| s.cover_photo_url.as_ref() == Some(cover))
            {
                format!("subfolder:{}", sub.name)
            } else {
                "unexpected".to_string()
            }
        }
    };
    let mut photo_paths: Vec<String> = folder
        .photos
        .iter()
        .map(|p| relativize(p.path(), root))
        .collect();
    photo_paths.sort();
    Folder {
        path: relativize(folder.url.path(), root),
        name: folder.name.clone(),
        photo_count: folder.photos.len(),
        photo_paths,
        total_photo_count: folder.total_photo_count,
        cover_photo_source,
        has_date_modified: folder.date_modified.is_some(),
        has_date_created: folder.date_created.is_some(),
        subfolders: folder
            .subfolders
            .iter()
            .map(|f| record_folder(f, root))
            .collect(),
    }
}

fn record_row(row: &SidecarCandidate, root: &str) -> SidecarRow {
    // The manifest carries the photo id, not its URL; the sidecar is always
    // `<photo basename>.xmp`, so stripping the extension recovers the photo
    // path without a lookup table.
    let sidecar_path = relativize(row.sidecar_url.path(), root);
    SidecarRow {
        photo_path: sidecar_path
            .strip_suffix(".xmp")
            .unwrap_or(&sidecar_path)
            .to_string(),
        sidecar_path,
        download_status: row.download_status.describe().to_string(),
        version_has_content_identifier: row.current_version.content_identifier.is_some(),
        version_modification_date: ConformanceDate::utc(row.current_version.modification_date),
        version_size: row.current_version.size,
    }
}

/// Record one outcome in the fixture's shape. `flatPhotos`, the path lists and
/// the manifest are sorted: within-folder listing order is explicitly *not*
/// part of the contract, only the folder order is.
fn record(
    outcome: &ScanOutcome,
    root: &str,
    name: &str,
    reuse_cached: bool,
    notes: Vec<String>,
) -> Pass {
    let mut flat_photos: Vec<Photo> = outcome
        .flat_photos
        .iter()
        .map(|p| record_photo(p, root))
        .collect();
    flat_photos.sort_by(|a, b| a.path.cmp(&b.path));

    let sorted = |paths: &[String]| {
        let mut out: Vec<String> = paths.iter().map(|p| relativize(p, root)).collect();
        out.sort();
        out
    };
    let mut sidecar_manifest: Vec<SidecarRow> = outcome
        .sidecar_manifest
        .iter()
        .map(|r| record_row(r, root))
        .collect();
    sidecar_manifest.sort_by(|a, b| a.photo_path.cmp(&b.photo_path));

    Pass {
        name: name.to_string(),
        reuse_cached,
        needs_enrichment: outcome.needs_enrichment,
        root_folder: outcome.root_folder.as_ref().map(|f| record_folder(f, root)),
        flat_photos,
        added_paths: sorted(&outcome.added_paths),
        removed_paths: sorted(&outcome.removed_paths),
        modified_paths: sorted(&outcome.modified_paths),
        // `failed_directory_paths` are decomposed, so the root has to be tried
        // in both spellings — the Swift recorder does exactly this.
        failed_directory_paths: {
            let nfd_root: String = root.nfd().collect();
            let mut out: Vec<String> = outcome
                .failed_directory_paths
                .iter()
                .map(|p| {
                    let rel = relativize(p, root);
                    if rel == *p {
                        relativize(p, &nfd_root)
                    } else {
                        rel
                    }
                })
                .collect();
            out.sort();
            out
        },
        sidecar_manifest,
        notes,
    }
}

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

fn cache_from(outcome: &ScanOutcome, reuse_cached: bool) -> ScanInput {
    ScanInput {
        reuse_cached,
        cached_photos: outcome
            .flat_photos
            .iter()
            .map(|p| (p.path().to_string(), p.clone()))
            .collect(),
        cached_sidecar_manifest: outcome
            .sidecar_manifest
            .iter()
            .map(|r| (r.photo_id, r.clone()))
            .collect::<HashMap<_, _>>(),
    }
}

fn dump() -> Dump {
    let path = fixtures_dir().join("scanner_conformance.json");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_slice(&bytes).expect("scanner_conformance.json does not match its shape")
}

/// Restores chmod-000'd directories even when an assertion panics — a leaked
/// unreadable directory defeats the temp dir's own cleanup.
struct Unlocker(Vec<std::path::PathBuf>);

impl Drop for Unlocker {
    fn drop(&mut self) {
        unlock(&self.0);
    }
}

#[test]
fn four_passes_over_the_fixture_tree_match_the_swift_baseline() {
    let expected = dump();
    assert_eq!(expected.schema, 1);
    assert_eq!(expected.passes.len(), 4);

    let temp = tempfile::tempdir().unwrap();
    let tree = ScannerTree::load();
    let root_path = tree.materialize(temp.path());
    let root = root_path.to_str().expect("temp paths are UTF-8");
    let vfs = ApfsLikeVfs::new();

    // Pass 1 — cold full scan over the pristine tree.
    let pass1 = scan(&vfs, root, &ScanInput::default());

    let locked = Unlocker(tree.mutate(&root_path));
    let chmod_works = locked.0.iter().all(|p| chmod_is_effective(p));
    assert!(
        chmod_works,
        "chmod 000 did not make {:?} unreadable — running as root defeats the \
         unreadable-directory case, and it would pass for the wrong reason",
        locked.0
    );

    let pass2 = scan(&vfs, root, &cache_from(&pass1, true));
    let pass3 = scan(&vfs, root, &cache_from(&pass1, false));

    unlock(&locked.0);

    let pass4 = scan(&vfs, root, &cache_from(&pass1, true));

    let observed = [
        record(&pass1, root, "1-full-cold", false, notes(&expected, 0)),
        record(
            &pass2,
            root,
            "2-light-after-mutations",
            true,
            notes(&expected, 1),
        ),
        record(
            &pass3,
            root,
            "3-full-after-mutations",
            false,
            notes(&expected, 2),
        ),
        record(
            &pass4,
            root,
            "4-light-after-unlock",
            true,
            notes(&expected, 3),
        ),
    ];

    let mut failures: Vec<String> = Vec::new();
    for (want, got) in expected.passes.iter().zip(&observed) {
        compare(want, got, &mut failures);
    }
    assert!(
        failures.is_empty(),
        "the Rust scanner diverged from the pinned Swift behaviour:\n\n{}\n",
        failures.join("\n")
    );
}

/// The notes live in the Swift test source and travel with the fixture; the
/// Rust runner carries them through unchanged so a comparison of whole passes
/// stays possible without duplicating them here.
fn notes(dump: &Dump, index: usize) -> Vec<String> {
    dump.passes[index].notes.clone()
}

fn compare(want: &Pass, got: &Pass, failures: &mut Vec<String>) {
    let mut check = |field: &str, ok: bool, detail: String| {
        if !ok {
            failures.push(format!("{}: {field}\n{detail}", want.name));
        }
    };
    check(
        "reuseCached",
        want.reuse_cached == got.reuse_cached,
        format!(
            "    expected {} got {}",
            want.reuse_cached, got.reuse_cached
        ),
    );
    check(
        "needsEnrichment",
        want.needs_enrichment == got.needs_enrichment,
        format!(
            "    expected {} got {}",
            want.needs_enrichment, got.needs_enrichment
        ),
    );
    for (field, want_list, got_list) in [
        ("addedPaths", &want.added_paths, &got.added_paths),
        ("removedPaths", &want.removed_paths, &got.removed_paths),
        ("modifiedPaths", &want.modified_paths, &got.modified_paths),
        (
            "failedDirectoryPaths",
            &want.failed_directory_paths,
            &got.failed_directory_paths,
        ),
    ] {
        check(
            field,
            want_list == got_list,
            format!("    expected {want_list:?}\n    got      {got_list:?}"),
        );
    }
    check(
        "flatPhotos",
        want.flat_photos == got.flat_photos,
        diff_lists(&want.flat_photos, &got.flat_photos),
    );
    check(
        "sidecarManifest",
        want.sidecar_manifest == got.sidecar_manifest,
        diff_lists(&want.sidecar_manifest, &got.sidecar_manifest),
    );
    check(
        "rootFolder",
        want.root_folder == got.root_folder,
        format!(
            "    expected {:#?}\n    got      {:#?}",
            want.root_folder, got.root_folder
        ),
    );
    check(
        "notes",
        want.notes == got.notes,
        "    the fixture's notes are part of it; deleting one is a failure".into(),
    );
}

/// Element-wise diff, so a 15-photo list does not print twice in full for one
/// wrong field.
fn diff_lists<T: PartialEq + std::fmt::Debug>(want: &[T], got: &[T]) -> String {
    let mut out = Vec::new();
    if want.len() != got.len() {
        out.push(format!("    length {} vs {}", want.len(), got.len()));
    }
    for (i, (w, g)) in want.iter().zip(got).enumerate() {
        if w != g {
            out.push(format!(
                "    [{i}] expected {w:#?}\n    [{i}] got      {g:#?}"
            ));
        }
    }
    out.join("\n")
}

/// The fixture tree has to reach disk with byte-exact names, or the two
/// Unicode cases collapse into one and the normalization contract tests
/// nothing.
#[test]
fn the_materialized_tree_keeps_both_normalization_forms() {
    let temp = tempfile::tempdir().unwrap();
    let root = ScannerTree::load().materialize(temp.path());
    let names: Vec<String> = std::fs::read_dir(root.join("Unicode"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    assert!(
        names.iter().any(|n| n.contains('\u{301}')),
        "the decomposed name was precomposed on the way to disk: {names:?}"
    );
    assert!(
        names.iter().any(|n| n.contains('\u{e9}')),
        "the precomposed name was decomposed on the way to disk: {names:?}"
    );
}

/// Ids are derived from the absolute path, which cannot be committed. Prove
/// the derivation instead — for folders as well as photos, which the fixture's
/// photo-only `idMatchesStableUUIDOfPath` does not cover.
#[test]
fn every_folder_id_is_the_id_its_path_derives() {
    let temp = tempfile::tempdir().unwrap();
    let root = ScannerTree::load().materialize(temp.path());
    let outcome = scan(
        &ApfsLikeVfs::new(),
        root.to_str().unwrap(),
        &ScanInput::default(),
    );
    fn check(folder: &PhotoFolder) {
        assert_eq!(
            folder.id,
            StableId::for_folder(folder.url.path()),
            "{}",
            folder.url.path()
        );
        folder.subfolders.iter().for_each(check);
    }
    check(outcome.root_folder.as_ref().expect("a root folder"));
}

/// A guard against the whole suite passing because the tree never appeared.
#[test]
fn the_fixture_tree_materializes_where_the_runner_looks() {
    let temp = tempfile::tempdir().unwrap();
    let root = ScannerTree::load().materialize(temp.path());
    assert!(Path::new(&root).join("Media/IMG_0001.jpg").is_file());
    assert!(Path::new(&root).join("Empty").is_dir());
    assert_eq!(
        std::fs::metadata(root.join("a.jpg")).unwrap().len(),
        1000,
        "filler sizes are part of the change signal"
    );
}
