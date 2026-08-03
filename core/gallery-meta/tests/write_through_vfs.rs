//! `write_tags` end to end: sidecar naming, creation, and the no-op skip.

mod common;

use common::fixture;
use gallery_meta::{read_view, write_tags, TagWriteRequest};
use gallery_vfs::{MemVfs, StdVfs, Vfs};

fn request(tags: &[&str]) -> TagWriteRequest {
    TagWriteRequest::new(
        tags.iter().map(|s| s.to_string()),
        "mobileclip-s2-2026.1",
        "2026-08-03T10:00:00Z",
    )
}

#[test]
fn a_missing_sidecar_is_created_next_to_the_image() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/IMG_1234.jpg", b"jpeg bytes".to_vec());

    let outcome = write_tags(&vfs, "/lib/IMG_1234.jpg", &request(&["Objects/Animal/Dog"])).unwrap();
    assert_eq!(outcome.sidecar_path, "/lib/IMG_1234.jpg.xmp");
    assert!(outcome.created);
    assert!(outcome.written);
    assert_eq!(outcome.added, vec!["Objects/Animal/Dog"]);

    let view = read_view(&vfs.read("/lib/IMG_1234.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.tags_list, vec!["Objects/Animal/Dog"]);
    // The image itself is never touched (overview standing decision 4).
    assert_eq!(vfs.read("/lib/IMG_1234.jpg").unwrap(), b"jpeg bytes");
}

#[test]
fn the_suffix_is_preserved_so_siblings_do_not_collide() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/IMG_1234.jpg", b"a".to_vec());
    vfs.insert("/lib/IMG_1234.heic", b"b".to_vec());

    write_tags(&vfs, "/lib/IMG_1234.jpg", &request(&["Objects/Animal/Dog"])).unwrap();
    write_tags(
        &vfs,
        "/lib/IMG_1234.heic",
        &request(&["Objects/Animal/Cat"]),
    )
    .unwrap();

    assert_eq!(
        read_view(&vfs.read("/lib/IMG_1234.jpg.xmp").unwrap())
            .unwrap()
            .tags_list,
        vec!["Objects/Animal/Dog"]
    );
    assert_eq!(
        read_view(&vfs.read("/lib/IMG_1234.heic.xmp").unwrap())
            .unwrap()
            .tags_list,
        vec!["Objects/Animal/Cat"]
    );
}

#[test]
fn an_existing_sidecar_is_updated_in_place() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());
    vfs.insert("/lib/a.jpg.xmp", fixture("digikam.jpg.xmp"));

    let outcome = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(!outcome.created);
    assert!(outcome.written);

    let view = read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.people_tags(), vec!["People/Alice", "People/Bob"]);
    assert_eq!(view.regions.len(), 2);
    assert!(view.tags_list.contains(&"Objects/Animal/Dog".to_string()));
    assert_eq!(vfs.paths().len(), 2, "no stray files: {:?}", vfs.paths());
}

#[test]
fn a_lightroom_style_sidecar_seeds_the_canonical_one() {
    // photo-tools reads `IMG_1234.xmp` but always writes `IMG_1234.jpg.xmp`
    // (§1.4). We match that, carrying the alt file's contents across so its
    // People/* entries and regions are not lost — and leaving the alt file
    // alone, because deleting somebody else's file is not our call.
    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());
    vfs.insert("/lib/a.xmp", fixture("digikam.jpg.xmp"));

    let outcome = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap();
    assert_eq!(outcome.sidecar_path, "/lib/a.jpg.xmp");
    assert!(outcome.created);

    let view = read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.regions.len(), 2);
    assert!(view.tags_list.contains(&"People/Alice".to_string()));
    assert_eq!(vfs.read("/lib/a.xmp").unwrap(), fixture("digikam.jpg.xmp"));
}

#[test]
fn the_canonical_sidecar_is_created_even_when_the_alt_already_matches() {
    // The no-op skip is about not churning an *existing* file. When the
    // canonical sidecar is absent, seeding it from a matching alt still has to
    // produce the file — otherwise the app, which only reads the canonical
    // name, sees nothing.
    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());
    let already_tagged = gallery_meta::apply_tags(None, &request(&["Objects/Animal/Dog"]))
        .unwrap()
        .bytes;
    vfs.insert("/lib/a.xmp", already_tagged.clone());

    let outcome = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(outcome.created);
    assert!(outcome.written);
    assert_eq!(vfs.read("/lib/a.jpg.xmp").unwrap(), already_tagged);
}

#[test]
fn an_unchanged_re_run_writes_nothing_at_all() {
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("IMG_1.jpg");
    std::fs::write(&image, b"jpeg").unwrap();
    let image = image.to_str().unwrap();

    let first = write_tags(&StdVfs, image, &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(first.written);
    let sidecar = dir.path().join("IMG_1.jpg.xmp");
    let mtime_before = std::fs::metadata(&sidecar).unwrap().modified().unwrap();
    let bytes_before = std::fs::read(&sidecar).unwrap();

    let second = write_tags(&StdVfs, image, &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(!second.written, "a no-op run must not touch the file");
    assert!(!second.created);
    assert_eq!(
        std::fs::metadata(&sidecar).unwrap().modified().unwrap(),
        mtime_before,
        "mtime changed; SidecarSyncService would re-fetch every sidecar"
    );
    assert_eq!(std::fs::read(&sidecar).unwrap(), bytes_before);
}

#[test]
fn writing_leaves_no_temporary_files_in_the_photo_directory() {
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("IMG_1.jpg");
    std::fs::write(&image, b"jpeg").unwrap();
    write_tags(
        &StdVfs,
        image.to_str().unwrap(),
        &request(&["Objects/Animal/Dog"]),
    )
    .unwrap();

    let mut names: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    names.sort();
    assert_eq!(names, vec!["IMG_1.jpg", "IMG_1.jpg.xmp"]);
}

#[test]
fn a_retraction_run_rewrites_and_reports_what_it_removed() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());

    write_tags(
        &vfs,
        "/lib/a.jpg",
        &request(&["Objects/Animal/Dog", "Scenes/Nature/Forest"]),
    )
    .unwrap();
    let outcome = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap();

    assert!(outcome.written);
    assert_eq!(outcome.removed, vec!["Scenes/Nature/Forest"]);
    assert_eq!(outcome.owned, vec!["Objects/Animal/Dog"]);
    assert!(outcome.added.is_empty());
}

#[test]
fn a_corrupt_sidecar_is_reported_rather_than_overwritten() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());
    vfs.insert("/lib/a.jpg.xmp", b"<html>not xmp</html>".to_vec());

    let err = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap_err();
    assert!(
        matches!(err, gallery_meta::MetaError::NotAnXmpPacket { .. }),
        "{err:?}"
    );
    assert_eq!(vfs.read("/lib/a.jpg.xmp").unwrap(), b"<html>not xmp</html>");
}
