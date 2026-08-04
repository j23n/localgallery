//! A 10k-file walk, for a number rather than a feeling.
//!
//! `#[ignore]` on purpose: it writes ~10,000 files, and nothing here is a
//! gate. The gate that matters is end-to-end — `_plans/06` asks for ≤ 60 s on
//! a cold 20k provider-backed scan — and it cannot be measured from this side
//! of the FFI, because the cost there is provider round-trips inside the VFS,
//! not the walk.
//!
//! What this *does* establish is that the walk itself is not the problem:
//! whatever the platform VFS costs, the traversal, the pairing and the diff
//! are noise next to it.
//!
//!     cargo test -p gallery-scan --test scan_bench -- --ignored --nocapture

use std::time::Instant;

use gallery_scan::{scan, ScanInput, ScanOutcome};
use gallery_vfs::StdVfs;

/// 40 folders × 250 files. Deep enough that the folder ordering and the
/// per-directory `stat_entry` both count, wide enough that per-file work
/// dominates — roughly the shape of a real year-foldered library.
const FOLDERS: usize = 40;
const FILES_PER_FOLDER: usize = 250;

fn build(root: &std::path::Path) {
    for folder in 0..FOLDERS {
        let dir = root.join(format!("{:04}-Album", folder));
        std::fs::create_dir_all(&dir).unwrap();
        for file in 0..FILES_PER_FOLDER {
            let stem = format!("IMG_{folder:03}{file:04}");
            std::fs::write(dir.join(format!("{stem}.jpg")), b"x").unwrap();
            // Every third photo carries a sidecar, which is roughly the
            // digiKam ratio (~85% in the 20k fixture library, but the manifest
            // cost is what is being sampled, not the ratio).
            if file % 3 == 0 {
                std::fs::write(dir.join(format!("{stem}.jpg.xmp")), b"<x/>").unwrap();
            }
        }
    }
}

fn cache_of(outcome: &ScanOutcome, reuse_cached: bool) -> ScanInput {
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
            .collect(),
    }
}

#[test]
#[ignore = "writes ~13k files; run explicitly with --ignored"]
fn walking_ten_thousand_files() {
    let temp = tempfile::tempdir().unwrap();
    let build_start = Instant::now();
    build(temp.path());
    let built = build_start.elapsed();
    let root = temp.path().to_str().unwrap();

    let start = Instant::now();
    let cold = scan(&StdVfs, root, &ScanInput::default());
    let full_ms = start.elapsed().as_secs_f64() * 1000.0;

    let start = Instant::now();
    let light = scan(&StdVfs, root, &cache_of(&cold, true));
    let light_ms = start.elapsed().as_secs_f64() * 1000.0;

    let start = Instant::now();
    let warm_full = scan(&StdVfs, root, &cache_of(&cold, false));
    let warm_full_ms = start.elapsed().as_secs_f64() * 1000.0;

    assert_eq!(cold.flat_photos.len(), FOLDERS * FILES_PER_FOLDER);
    assert_eq!(light.flat_photos.len(), cold.flat_photos.len());
    assert!(light.modified_paths.is_empty() && light.removed_paths.is_empty());
    assert_eq!(warm_full.flat_photos.len(), cold.flat_photos.len());

    println!(
        "\n{} photos + {} sidecars in {} folders (tree built in {:.0} ms)\n\
         cold full : {full_ms:7.1} ms\n\
         warm full : {warm_full_ms:7.1} ms\n\
         light     : {light_ms:7.1} ms\n",
        cold.flat_photos.len(),
        cold.sidecar_manifest.len(),
        FOLDERS,
        built.as_secs_f64() * 1000.0,
    );
}
