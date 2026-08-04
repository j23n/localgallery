//! `write_tags` / `write_faces` end to end: sidecar naming, creation, and the
//! no-op skip.

mod common;

use common::fixture;
use gallery_meta::{
    read_view, write_faces, write_tags, Area, FaceRegionWrite, FaceWriteRequest, TagWriteRequest,
};
use gallery_vfs::{MemVfs, StdVfs, Vfs};

fn request(tags: &[&str]) -> TagWriteRequest {
    TagWriteRequest::new(
        tags.iter().map(|s| s.to_string()),
        "mobileclip-s2-2026.1",
        "2026-08-03T10:00:00Z",
    )
}

fn face_request(people: &[(&str, f64, f64)]) -> FaceWriteRequest {
    FaceWriteRequest::new(
        people.iter().map(|(name, x, y)| FaceRegionWrite {
            name: (*name).to_string(),
            area: Area::new(*x, *y, 0.1, 0.12),
        }),
        "buffalo_sc-2026.1",
        "2026-08-03T10:00:00Z",
    )
    .with_image_size(4032, 3024)
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

#[test]
fn a_truncated_sidecar_is_refused_and_left_exactly_as_it_was() {
    // A file cut short mid-document must not be "repaired" by closing the open
    // elements: the rewrite would discard everything past the cut, permanently,
    // while looking pristine. Fail the row instead.
    let whole = fixture("phototools.jpg.xmp");
    let cut = whole[..whole.len() / 2].to_vec();

    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());
    vfs.insert("/lib/a.jpg.xmp", cut.clone());

    let err = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap_err();
    assert!(
        matches!(err, gallery_meta::MetaError::MalformedXml { .. }),
        "{err:?}"
    );
    assert_eq!(
        vfs.read("/lib/a.jpg.xmp").unwrap(),
        cut,
        "the file was touched"
    );
}

/// A `MemVfs` with a third-party writer wired to fire the instant after our
/// read returns — exactly the window a read-modify-write cannot see.
struct RacyVfs {
    inner: MemVfs,
    /// Bytes to slip into `path` after the first `read`.
    intruder: std::sync::Mutex<Option<(String, Vec<u8>)>>,
}

impl RacyVfs {
    fn new(path: &str, bytes: Vec<u8>) -> Self {
        RacyVfs {
            inner: MemVfs::new(),
            intruder: std::sync::Mutex::new(Some((path.to_string(), bytes))),
        }
    }
}

impl Vfs for RacyVfs {
    fn open(&self, path: &str) -> gallery_vfs::VfsResult<Box<dyn gallery_vfs::ReadSeek + Send>> {
        self.inner.open(path)
    }
    fn stat(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Stat> {
        self.inner.stat(path)
    }
    fn list(&self, dir: &str) -> gallery_vfs::VfsResult<Vec<gallery_vfs::Entry>> {
        self.inner.list(dir)
    }
    fn stat_entry(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Entry> {
        self.inner.stat_entry(path)
    }
    fn write_atomic(&self, path: &str, bytes: &[u8]) -> gallery_vfs::VfsResult<()> {
        self.inner.write_atomic(path, bytes)
    }
    fn exists(&self, path: &str) -> bool {
        self.inner.exists(path)
    }
    fn read(&self, path: &str) -> gallery_vfs::VfsResult<Vec<u8>> {
        let bytes = self.inner.read(path)?;
        if let Some((p, b)) = self.intruder.lock().unwrap().take() {
            self.inner.insert(&p, b);
        }
        Ok(bytes)
    }
}

#[test]
fn a_write_that_lands_between_our_read_and_our_rename_is_not_discarded() {
    // digiKam adds a face tag while a tagging run is mid-flight. Renaming our
    // merged-from-stale-bytes result over it would delete that tag with no
    // trace, so the write is refused and the caller retries instead.
    let theirs = fixture("digikam.jpg.xmp");
    let vfs = RacyVfs::new("/lib/a.jpg.xmp", theirs.clone());
    vfs.inner.insert("/lib/a.jpg", b"a".to_vec());
    vfs.inner
        .insert("/lib/a.jpg.xmp", fixture("minimal.jpg.xmp"));

    let err = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap_err();
    assert!(
        matches!(err, gallery_meta::MetaError::ConcurrentModification { .. }),
        "{err:?}"
    );
    assert!(err.is_retryable());
    assert_eq!(
        vfs.inner.read("/lib/a.jpg.xmp").unwrap(),
        theirs,
        "the other writer's bytes were clobbered"
    );

    // The retry sees the new bytes and merges into them.
    let outcome = write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(outcome.written);
    let view = read_view(&vfs.inner.read("/lib/a.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.people_tags(), vec!["People/Alice", "People/Bob"]);
    assert!(view.tags_list.contains(&"Objects/Animal/Dog".to_string()));
}

// ---------------------------------------------------------------------------
// Faces
// ---------------------------------------------------------------------------

#[test]
fn naming_a_person_creates_the_sidecar_and_leaves_the_image_alone() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/IMG_1234.jpg", b"jpeg bytes".to_vec());

    let outcome = write_faces(
        &vfs,
        "/lib/IMG_1234.jpg",
        &face_request(&[("Alice", 0.4, 0.35)]),
    )
    .unwrap();
    assert_eq!(outcome.sidecar_path, "/lib/IMG_1234.jpg.xmp");
    assert!(outcome.created && outcome.written);
    assert_eq!(outcome.added, vec!["People/Alice"]);

    let view = read_view(&vfs.read("/lib/IMG_1234.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.people_tags(), vec!["People/Alice"]);
    assert_eq!(view.regions.len(), 1);
    assert_eq!(vfs.read("/lib/IMG_1234.jpg").unwrap(), b"jpeg bytes");
}

#[test]
fn an_unchanged_face_re_run_writes_nothing_at_all() {
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("a.jpg");
    std::fs::write(&image, b"a").unwrap();
    let image = image.to_string_lossy().into_owned();
    let sidecar = format!("{image}.xmp");

    let first = write_faces(&StdVfs, &image, &face_request(&[("Alice", 0.4, 0.35)])).unwrap();
    assert!(first.written);
    let before = std::fs::read(&sidecar).unwrap();
    let stamp = std::fs::metadata(&sidecar).unwrap().modified().unwrap();

    let second = write_faces(&StdVfs, &image, &face_request(&[("Alice", 0.4, 0.35)])).unwrap();
    assert!(!second.written, "a no-op re-run must not touch the file");
    assert_eq!(std::fs::read(&sidecar).unwrap(), before);
    assert_eq!(
        std::fs::metadata(&sidecar).unwrap().modified().unwrap(),
        stamp
    );
}

#[test]
fn a_face_write_that_lands_mid_flight_is_refused_and_retryable() {
    let theirs = fixture("digikam.jpg.xmp");
    let vfs = RacyVfs::new("/lib/a.jpg.xmp", theirs.clone());
    vfs.inner.insert("/lib/a.jpg", b"a".to_vec());
    vfs.inner
        .insert("/lib/a.jpg.xmp", fixture("minimal.jpg.xmp"));

    let err = write_faces(&vfs, "/lib/a.jpg", &face_request(&[("Carol", 0.2, 0.82)])).unwrap_err();
    assert!(
        matches!(err, gallery_meta::MetaError::ConcurrentModification { .. }),
        "{err:?}"
    );
    assert!(err.is_retryable());
    assert_eq!(vfs.inner.read("/lib/a.jpg.xmp").unwrap(), theirs);

    // The retry merges into the bytes that landed, keeping their regions.
    let outcome = write_faces(&vfs, "/lib/a.jpg", &face_request(&[("Carol", 0.2, 0.82)])).unwrap();
    assert!(outcome.written);
    let view = read_view(&vfs.inner.read("/lib/a.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.regions.len(), 3);
    assert_eq!(
        view.people_tags(),
        vec!["People/Alice", "People/Bob", "People/Carol"]
    );
}

#[test]
fn the_two_halves_of_the_core_write_the_same_sidecar_without_fighting() {
    let vfs = MemVfs::new();
    vfs.insert("/lib/a.jpg", b"a".to_vec());

    assert!(
        write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"]))
            .unwrap()
            .written
    );
    assert!(
        write_faces(&vfs, "/lib/a.jpg", &face_request(&[("Alice", 0.4, 0.35)]))
            .unwrap()
            .written
    );

    // Both now find the file already says what they say.
    assert!(
        !write_tags(&vfs, "/lib/a.jpg", &request(&["Objects/Animal/Dog"]))
            .unwrap()
            .written
    );
    assert!(
        !write_faces(&vfs, "/lib/a.jpg", &face_request(&[("Alice", 0.4, 0.35)]))
            .unwrap()
            .written
    );

    let view = read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
    assert_eq!(view.core.tags, vec!["Objects/Animal/Dog"]);
    assert_eq!(view.core.people, vec!["People/Alice"]);
    assert_eq!(view.tags_list, vec!["Objects/Animal/Dog", "People/Alice"]);
    assert_eq!(view.subject, vec!["Dog", "Alice"]);
}
