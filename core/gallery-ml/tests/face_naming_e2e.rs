//! Naming a cluster all the way to bytes on disk.
//!
//! The other face suite stops at the cache DB. This one is about the half that
//! leaves it: `People/<Name>` keywords and MWG-RS regions in real `.xmp` files
//! next to real fixture photos, written by the real `gallery-meta` writer.
//!
//! The synthetic detector in `tests/facepack` makes the inputs a property of
//! the fixtures rather than of a model nobody can read — `face_dark.png` has no
//! faces, `face_mid.png` has one, `face_bright.png` has several — so "which
//! photos should have gained a sidecar" is something a test can state.

mod common;

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use common::{face_pack_dir, fixture};
use gallery_meta::read_view;
use gallery_ml::cache::ClusterState;
use gallery_ml::face::{
    FaceEngine, FaceProgress, FaceRunOptions, FaceRunSummary, NoFaceProgress, SyncScope,
};
use gallery_ml::{CacheDb, MlError, ModelPack};
use gallery_vfs::StdVfs;

const DARK: &str = "face_dark.png";
const MID: &str = "face_mid.png";
const BRIGHT: &str = "face_bright.png";
const PHOTOS: &[&str] = &[DARK, MID, BRIGHT];

/// Fixed so a sidecar's bytes are a function of the library, not of the clock.
const STAMP: &str = "2026-08-03T10:00:00Z";

struct Fixture {
    dir: tempfile::TempDir,
    engine: FaceEngine,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture::with_files(PHOTOS)
    }

    /// `(fixture name, file name)` pairs, so the same bytes can be placed twice.
    fn with_copies(files: &[(&str, &str)]) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        for (source, name) in files {
            let target = dir.path().join(name);
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::write(target, fixture(source)).unwrap();
        }
        let engine = FaceEngine::open(
            dir.path().join("gallery-cache.sqlite"),
            face_pack_dir(),
            Arc::new(StdVfs),
        )
        .expect("face pack must load");
        Fixture { dir, engine }
    }

    fn with_files(names: &[&str]) -> Fixture {
        let pairs: Vec<(&str, &str)> = names.iter().map(|n| (*n, *n)).collect();
        Fixture::with_copies(&pairs)
    }

    /// A fixture whose pack carries different clustering thresholds.
    fn with_clustering(mutate: impl FnOnce(&mut gallery_ml::ClusteringConfig)) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        for name in PHOTOS {
            std::fs::write(dir.path().join(name), fixture(name)).unwrap();
        }
        let mut pack = ModelPack::load(face_pack_dir()).unwrap();
        mutate(&mut pack.manifest.faces.as_mut().unwrap().clustering);
        let cache = CacheDb::open(dir.path().join("gallery-cache.sqlite")).unwrap();
        let engine = FaceEngine::open_with_pack(cache, pack, Arc::new(StdVfs)).unwrap();
        Fixture { dir, engine }
    }

    fn path(&self, name: &str) -> String {
        self.dir.path().join(name).to_string_lossy().into_owned()
    }

    fn sidecar(&self, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.dir.path().join(format!("{name}.xmp"))).ok()
    }

    fn enqueue(&self, names: &[&str]) {
        let paths: Vec<String> = names.iter().map(|n| self.path(n)).collect();
        self.engine.enqueue(&paths).unwrap();
    }

    fn run(&self) -> FaceRunSummary {
        self.run_with(&NoFaceProgress)
    }

    fn run_with(&self, progress: &dyn FaceProgress) -> FaceRunSummary {
        self.engine
            .run_with_options(progress, &AtomicBool::new(false), &options())
            .unwrap()
    }

    fn raw(&self) -> rusqlite::Connection {
        rusqlite::Connection::open(self.dir.path().join("gallery-cache.sqlite")).unwrap()
    }

    /// The id of the largest cluster, which for these fixtures is the one with
    /// faces from more than one photo.
    fn biggest_cluster(&self) -> i64 {
        let mut clusters = self.engine.clusters().unwrap();
        clusters.sort_by_key(|c| (std::cmp::Reverse(c.size), c.id));
        clusters.first().expect("a cluster").id
    }

    /// Photo file names (not paths) the given cluster reaches.
    fn photos_of(&self, cluster_id: i64) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        for hash in self.engine.cache().cluster_hashes(cluster_id).unwrap() {
            for path in self.engine.cache().face_paths_for_hash(&hash).unwrap() {
                let name = path.rsplit('/').next().unwrap().to_string();
                if !names.contains(&name) {
                    names.push(name);
                }
            }
        }
        names.sort();
        names
    }
}

fn options() -> FaceRunOptions {
    FaceRunOptions {
        workers: Some(1),
        limit: None,
        root_prefix: None,
        full_recluster: false,
        tagged_at: Some(STAMP.to_string()),
        skip_auto_tagging: false,
    }
}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

#[test]
fn naming_a_cluster_writes_people_and_regions_to_every_photo_it_reaches() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();

    let id = f.biggest_cluster();
    let expected = f.photos_of(id);
    assert!(!expected.is_empty(), "the cluster reaches no photo");

    let plan = f
        .engine
        .name_cluster(id, "Ada Lovelace", Some(STAMP), None)
        .unwrap();
    assert_eq!(plan.written.len(), expected.len(), "{plan:?}");
    assert!(plan.failed.is_empty(), "{:?}", plan.failed);

    for name in &expected {
        let bytes = f
            .sidecar(name)
            .unwrap_or_else(|| panic!("no sidecar for {name}"));
        let view = read_view(&bytes).unwrap();
        assert_eq!(view.people_tags(), vec!["People/Ada Lovelace"]);
        assert_eq!(view.subject, vec!["Ada Lovelace"]);
        assert_eq!(view.hierarchical_subject, vec!["People|Ada Lovelace"]);
        assert_eq!(view.person_in_image, vec!["Ada Lovelace"]);
        assert!(!view.regions.is_empty(), "{name}: no region written");
        for region in &view.regions {
            assert_eq!(region.name.as_deref(), Some("Ada Lovelace"));
            assert_eq!(region.kind.as_deref(), Some("Face"));
            assert!((0.0..=1.0).contains(&region.center_x));
            assert!(region.width > 0.0 && region.height > 0.0);
        }
        assert_eq!(view.core.people, vec!["People/Ada Lovelace"]);
        assert_eq!(view.core.regions.len(), view.regions.len());
        assert_eq!(
            view.core.face_pack.as_deref(),
            Some(f.engine.face_pack_key())
        );
    }

    // The cluster row now says so too.
    let cluster = f.engine.cache().cluster(id).unwrap().unwrap();
    assert_eq!(cluster.state, ClusterState::Named);
    assert_eq!(cluster.person_name.as_deref(), Some("Ada Lovelace"));

    // A photo the cluster does not reach has no sidecar at all.
    for name in PHOTOS {
        if !expected.contains(&name.to_string()) {
            assert!(
                f.sidecar(name).is_none(),
                "{name} got a sidecar it should not"
            );
        }
    }
}

#[test]
fn naming_the_same_cluster_again_writes_nothing() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();

    let first = f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    assert!(first.touched_disk());
    let snapshot: Vec<Option<Vec<u8>>> = PHOTOS.iter().map(|n| f.sidecar(n)).collect();

    let second = f
        .engine
        .name_cluster(id, "Ada", Some("2026-09-09T09:09:09Z"), None)
        .unwrap();
    assert!(!second.touched_disk(), "{second:?}");
    assert_eq!(second.unchanged.len(), first.written.len());
    assert_eq!(
        PHOTOS.iter().map(|n| f.sidecar(n)).collect::<Vec<_>>(),
        snapshot,
        "a no-op re-name rewrote a sidecar"
    );
}

#[test]
fn an_unusable_name_is_refused_before_anything_is_written() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();

    for bad in ["", "   ", "People/Ada"] {
        let err = f
            .engine
            .name_cluster(id, bad, Some(STAMP), None)
            .unwrap_err();
        assert!(
            matches!(
                err,
                MlError::Meta(gallery_meta::MetaError::InvalidTag { .. })
            ),
            "{bad:?}: {err:?}"
        );
    }
    assert_eq!(
        f.engine.cache().cluster(id).unwrap().unwrap().state,
        ClusterState::Unlabeled,
        "a rejected name must not have changed the cluster"
    );
    for name in PHOTOS {
        assert!(f.sidecar(name).is_none());
    }
}

#[test]
fn naming_a_cluster_that_is_gone_is_an_error_not_a_silent_no_op() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let err = f
        .engine
        .name_cluster(9_999, "Ada", Some(STAMP), None)
        .unwrap_err();
    assert!(
        matches!(err, MlError::ClusterNotFound { id: 9_999 }),
        "{err:?}"
    );
}

// ---------------------------------------------------------------------------
// Rename and un-name
// ---------------------------------------------------------------------------

#[test]
fn renaming_swaps_the_name_in_every_sidecar_without_duplicating_a_region() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    let before_counts: Vec<usize> = photos
        .iter()
        .map(|n| read_view(&f.sidecar(n).unwrap()).unwrap().regions.len())
        .collect();

    let plan = f
        .engine
        .rename_person("Ada", "Grace", Some(STAMP), None)
        .unwrap();
    assert_eq!(plan.written.len(), photos.len(), "{plan:?}");

    for (name, count) in photos.iter().zip(&before_counts) {
        let view = read_view(&f.sidecar(name).unwrap()).unwrap();
        assert_eq!(view.people_tags(), vec!["People/Grace"]);
        assert_eq!(view.subject, vec!["Grace"]);
        assert_eq!(view.person_in_image, vec!["Grace"]);
        assert_eq!(view.regions.len(), *count, "region count changed");
        assert!(view
            .regions
            .iter()
            .all(|r| r.name.as_deref() == Some("Grace")));
    }
    assert_eq!(
        f.engine
            .cache()
            .cluster(id)
            .unwrap()
            .unwrap()
            .person_name
            .as_deref(),
        Some("Grace")
    );
    assert!(f.engine.cache().clusters_named("Ada").unwrap().is_empty());
}

#[test]
fn renaming_a_person_nobody_carries_is_an_empty_plan_not_an_error() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let plan = f
        .engine
        .rename_person("Nobody", "Somebody", Some(STAMP), None)
        .unwrap();
    assert_eq!(plan.total(), 0);
    assert!(!plan.touched_disk());
}

#[test]
fn un_naming_takes_the_person_and_their_regions_back_out() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    let plan = f.engine.unname_cluster(id, Some(STAMP), None).unwrap();
    assert_eq!(plan.written.len(), photos.len());

    for name in &photos {
        let view = read_view(&f.sidecar(name).unwrap()).unwrap();
        assert!(view.tags_list.is_empty(), "{name}: {:?}", view.tags_list);
        assert!(view.subject.is_empty());
        assert!(view.hierarchical_subject.is_empty());
        assert!(view.person_in_image.is_empty());
        assert!(view.regions.is_empty(), "{name}: a region survived");
        assert!(view.core.people.is_empty());
        assert!(view.core.regions.is_empty());
    }
    let cluster = f.engine.cache().cluster(id).unwrap().unwrap();
    assert_eq!(cluster.state, ClusterState::Unlabeled);
    assert!(cluster.person_name.is_none());
}

#[test]
fn ignoring_a_named_cluster_retracts_it_and_keeps_it_out_of_the_way() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    f.engine.ignore_cluster(id, Some(STAMP), None).unwrap();

    for name in f.photos_of(id) {
        let view = read_view(&f.sidecar(&name).unwrap()).unwrap();
        assert!(view.people_tags().is_empty());
        assert!(view.regions.is_empty());
    }
    assert_eq!(
        f.engine.cache().cluster(id).unwrap().unwrap().state,
        ClusterState::Ignored
    );
}

/// Somebody else's sidecar content has to come through naming, renaming *and*
/// un-naming untouched — that is the whole preservation contract, exercised
/// through the orchestration rather than through `gallery-meta` alone.
#[test]
fn a_foreign_sidecar_survives_the_whole_name_rename_unname_cycle() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);
    let target = photos.first().unwrap().clone();

    // Drop a hand-written sidecar with a human keyword, a foreign person and a
    // photo-tools sentinel next to one of the photos.
    let foreign = "<?xpacket begin='' id='W5M0Mp'?>\n\
<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n\
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n\
 <rdf:Description rdf:about=''\n\
  xmlns:digiKam='http://www.digikam.org/ns/1.0/'\n\
  xmlns:dc='http://purl.org/dc/elements/1.1/'\n\
  xmlns:phototools='https://github.com/j23n/photo-tools/ns/1.0/'>\n\
  <digiKam:TagsList><rdf:Seq><rdf:li>People/Zoe</rdf:li>\
<rdf:li>Places/Italy/Rome</rdf:li></rdf:Seq></digiKam:TagsList>\n\
  <dc:subject><rdf:Bag><rdf:li>Zoe</rdf:li><rdf:li>Rome</rdf:li></rdf:Bag></dc:subject>\n\
  <phototools:TaggerVersion>2026.4</phototools:TaggerVersion>\n\
  <phototools:CountryCode>IT</phototools:CountryCode>\n\
 </rdf:Description>\n\
</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>\n";
    let sidecar_path = f.dir.path().join(format!("{target}.xmp"));
    std::fs::write(&sidecar_path, foreign).unwrap();

    let expect_foreign_intact = |stage: &str| {
        let view = read_view(&std::fs::read(&sidecar_path).unwrap()).unwrap();
        assert!(
            view.tags_list.contains(&"People/Zoe".to_string()),
            "{stage}: lost People/Zoe"
        );
        assert!(
            view.tags_list.contains(&"Places/Italy/Rome".to_string()),
            "{stage}: lost a place"
        );
        assert!(view.subject.contains(&"Zoe".to_string()), "{stage}");
        assert!(view.subject.contains(&"Rome".to_string()), "{stage}");
        assert_eq!(
            view.photo_tools.tagger_version.as_deref(),
            Some("2026.4"),
            "{stage}: photo-tools sentinel"
        );
        assert_eq!(
            view.photo_tools.country_code.as_deref(),
            Some("IT"),
            "{stage}"
        );
        view
    };

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    let named = expect_foreign_intact("named");
    assert!(named.tags_list.contains(&"People/Ada".to_string()));
    assert_eq!(named.person_in_image, vec!["Zoe", "Ada"]);

    f.engine
        .rename_person("Ada", "Grace", Some(STAMP), None)
        .unwrap();
    let renamed = expect_foreign_intact("renamed");
    assert!(renamed.tags_list.contains(&"People/Grace".to_string()));
    assert!(!renamed.tags_list.contains(&"People/Ada".to_string()));

    f.engine.unname_cluster(id, Some(STAMP), None).unwrap();
    let cleared = expect_foreign_intact("un-named");
    assert!(!cleared.tags_list.contains(&"People/Grace".to_string()));
    assert!(cleared.regions.is_empty());
    assert_eq!(cleared.person_in_image, vec!["Zoe"]);
}

// ---------------------------------------------------------------------------
// Two paths, one photo
// ---------------------------------------------------------------------------

#[test]
fn both_copies_of_a_photo_get_their_own_sidecar() {
    // One content hash, two `face_work` rows: the detection is shared, the
    // files are not, and a naming that wrote only one would leave the library
    // half-labelled.
    let f = Fixture::with_copies(&[(BRIGHT, "album-a/photo.png"), (BRIGHT, "album-b/photo.png")]);
    f.enqueue(&["album-a/photo.png", "album-b/photo.png"]);
    let summary = f.run();
    assert_eq!(summary.processed, 2);
    assert_eq!(summary.cache_hits, 1, "the second copy must hit the cache");

    let id = f.biggest_cluster();
    let plan = f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    assert_eq!(plan.written.len(), 2, "{plan:?}");

    let a = f.sidecar("album-a/photo.png").unwrap();
    let b = f.sidecar("album-b/photo.png").unwrap();
    assert_eq!(a, b, "one photo, two files, identical bytes");
    assert_eq!(read_view(&a).unwrap().people_tags(), vec!["People/Ada"]);
}

// ---------------------------------------------------------------------------
// Determinism
// ---------------------------------------------------------------------------

#[test]
fn two_independent_libraries_produce_byte_identical_sidecars() {
    let build = || {
        let f = Fixture::new();
        f.enqueue(PHOTOS);
        f.run();
        let id = f.biggest_cluster();
        f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
        let mut out: Vec<(String, Option<Vec<u8>>)> = PHOTOS
            .iter()
            .map(|n| ((*n).to_string(), f.sidecar(n)))
            .collect();
        out.sort();
        out
    };
    assert_eq!(build(), build());
}

// ---------------------------------------------------------------------------
// Auto-tagging
// ---------------------------------------------------------------------------

/// Detach a photo's faces from their clusters so the next run has to re-place
/// them. The face rows — and so the embeddings — are untouched, which is what
/// makes the re-join land in the same (now named) cluster.
fn detach(f: &Fixture, photo: &str) {
    let hash = gallery_ml::hash::hash_bytes(&fixture(photo));
    f.raw()
        .execute(
            "DELETE FROM cluster_members WHERE content_hash = ?1",
            rusqlite::params![hash.as_slice()],
        )
        .unwrap();
}

#[derive(Default)]
struct RecordingProgress {
    sidecars: Mutex<Vec<String>>,
}

impl FaceProgress for RecordingProgress {
    fn on_progress(&self, _done: usize, _total: usize) {}
    fn on_photos_with_faces(&self, _paths: &[String]) {}
    fn on_sidecars_written(&self, paths: &[String]) {
        self.sidecars.lock().unwrap().extend_from_slice(paths);
    }
    fn on_finished(&self, _summary: &FaceRunSummary) {}
}

#[test]
fn a_face_rejoining_a_named_cluster_is_written_out_without_being_asked() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);
    let target = photos.first().unwrap().clone();

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    // Wipe the sidecar and the membership: the next run must put both back.
    std::fs::remove_file(f.dir.path().join(format!("{target}.xmp"))).unwrap();
    detach(&f, &target);

    let progress = RecordingProgress::default();
    let summary = f.run_with(&progress);
    assert!(summary.faces_auto_tagged > 0, "{summary:?}");
    assert_eq!(summary.sidecars_written, 1, "{summary:?}");
    assert_eq!(summary.sidecars_failed, 0);
    assert_eq!(progress.sidecars.lock().unwrap().len(), 1);

    let view = read_view(&f.sidecar(&target).unwrap()).unwrap();
    assert_eq!(view.people_tags(), vec!["People/Ada"]);
    assert!(!view.regions.is_empty());
}

#[test]
fn the_auto_path_writes_nothing_when_the_library_has_not_moved() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();

    let snapshot: Vec<Option<Vec<u8>>> = PHOTOS.iter().map(|n| f.sidecar(n)).collect();
    let summary = f.run();
    assert_eq!(summary.faces_auto_tagged, 0, "{summary:?}");
    assert_eq!(summary.sidecars_written, 0);
    assert_eq!(
        PHOTOS.iter().map(|n| f.sidecar(n)).collect::<Vec<_>>(),
        snapshot
    );
}

#[test]
fn a_face_below_the_quality_floor_stays_in_the_cache_and_off_the_disk() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);
    let target = photos.first().unwrap().clone();

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    std::fs::remove_file(f.dir.path().join(format!("{target}.xmp"))).unwrap();
    detach(&f, &target);

    // Force every face of that photo below `min_quality` (0.25 by default).
    let hash = gallery_ml::hash::hash_bytes(&fixture(&target));
    f.raw()
        .execute(
            "UPDATE faces SET quality = 0.01 WHERE content_hash = ?1",
            rusqlite::params![hash.as_slice()],
        )
        .unwrap();

    let summary = f.run();
    assert!(summary.faces_assigned > 0, "the faces still cluster");
    assert_eq!(summary.faces_auto_tagged, 0, "{summary:?}");
    assert_eq!(summary.sidecars_written, 0);
    assert!(
        f.sidecar(&target).is_none(),
        "a low-quality match must not edit a file"
    );
}

#[test]
fn a_match_that_misses_the_auto_threshold_does_not_reach_the_disk() {
    // `auto` above 1.0 is unreachable for any cosine, so no face can join a
    // named cluster — the exact condition the threshold exists to express.
    let f = Fixture::with_clustering(|c| c.auto = 1.1);
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);
    let target = photos.first().unwrap().clone();

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    std::fs::remove_file(f.dir.path().join(format!("{target}.xmp"))).unwrap();
    detach(&f, &target);

    let summary = f.run();
    assert_eq!(summary.faces_auto_tagged, 0, "{summary:?}");
    assert_eq!(summary.sidecars_written, 0);
    assert!(f.sidecar(&target).is_none());
}

#[test]
fn the_auto_pass_can_be_turned_off_entirely() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let photos = f.photos_of(id);
    let target = photos.first().unwrap().clone();

    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();
    std::fs::remove_file(f.dir.path().join(format!("{target}.xmp"))).unwrap();
    detach(&f, &target);

    let summary = f
        .engine
        .run_with_options(
            &NoFaceProgress,
            &AtomicBool::new(false),
            &FaceRunOptions {
                skip_auto_tagging: true,
                ..options()
            },
        )
        .unwrap();
    assert!(summary.faces_auto_tagged > 0, "the gate still says yes");
    assert_eq!(summary.sidecars_written, 0, "but nothing was written");
    assert!(f.sidecar(&target).is_none());
}

#[test]
fn a_face_joining_an_unlabeled_cluster_is_never_auto_tagged() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    let first = f.run();
    assert_eq!(first.faces_auto_tagged, 0, "nothing is named yet");

    detach(&f, BRIGHT);
    let second = f.run();
    assert!(second.faces_assigned > 0);
    assert_eq!(second.faces_auto_tagged, 0);
    assert_eq!(second.sidecars_written, 0);
    for name in PHOTOS {
        assert!(f.sidecar(name).is_none());
    }
}

// ---------------------------------------------------------------------------
// The quality floor is a property of writing, not of the auto pass
// ---------------------------------------------------------------------------

/// A below-floor face used to reach disk whenever *any* face in the same photo
/// triggered a write: the floor gated the auto-tag counter, not the content of
/// the request. Now it gates the request, on every path.
#[test]
fn a_below_floor_face_is_left_out_of_a_user_naming_too() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();

    // Name every cluster, so every face in the crowded fixture carries a name
    // and the region count is exactly the face count.
    let clusters = f.engine.clusters().unwrap();
    for (i, c) in clusters.iter().enumerate() {
        f.engine
            .name_cluster(c.id, &format!("Person {i}"), Some(STAMP), None)
            .unwrap();
    }

    let hash = gallery_ml::hash::hash_bytes(&fixture(BRIGHT));
    let faces = f.engine.cache().faces_for_hash(&hash).unwrap();
    assert!(faces.len() >= 2, "the fixture must be a group shot");
    let before = read_view(&f.sidecar(BRIGHT).unwrap()).unwrap();
    assert_eq!(before.regions.len(), faces.len(), "{before:?}");

    // Exactly one of them drops below `min_quality` (0.25 by default).
    let victim = i64::from(faces[0].face_idx);
    f.raw()
        .execute(
            "UPDATE faces SET quality = 0.01 WHERE content_hash = ?1 AND face_idx = ?2",
            rusqlite::params![hash.as_slice(), victim],
        )
        .unwrap();

    // Any naming re-derives the whole photo, which is how the below-floor face
    // used to get in.
    let last = clusters.last().unwrap();
    f.engine
        .name_cluster(
            last.id,
            &format!("Person {}", clusters.len() - 1),
            Some(STAMP),
            None,
        )
        .unwrap();

    let after = read_view(&f.sidecar(BRIGHT).unwrap()).unwrap();
    assert_eq!(
        after.regions.len(),
        faces.len() - 1,
        "the below-floor face still reached disk: {after:?}"
    );
}

// ---------------------------------------------------------------------------
// A sync never retracts a name it simply cannot see
// ---------------------------------------------------------------------------

/// A re-detection that loses a face must not un-name the person it belonged to.
///
/// `put_faces` clears the photo's `cluster_members`, so the very next sync sees
/// a photo with fewer named faces than the sidecar claims. Reading that as "the
/// others are not here" deletes a human decision because a model changed its
/// mind.
#[test]
fn a_sync_keeps_a_claim_the_cache_can_no_longer_explain() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let target = f.photos_of(id).first().unwrap().clone();
    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();

    let before = f.sidecar(&target).unwrap();
    assert_eq!(
        read_view(&before).unwrap().people_tags(),
        vec!["People/Ada"]
    );

    // The cache forgets who is in this photo.
    detach(&f, &target);
    let hash = gallery_ml::hash::hash_bytes(&fixture(&target));
    let plan = f
        .engine
        .sync_sidecars(&[hash], Some(STAMP), &SyncScope::default())
        .unwrap();
    assert!(plan.failed.is_empty(), "{:?}", plan.failed);
    assert!(
        plan.written.is_empty(),
        "a keep-everything sync rewrote a file"
    );

    let after = f.sidecar(&target).unwrap();
    assert_eq!(after, before, "the sidecar changed");
    let view = read_view(&after).unwrap();
    assert_eq!(view.people_tags(), vec!["People/Ada"]);
    assert!(!view.regions.is_empty(), "Ada's region was retracted");
}

/// The pack-swap case: `reset_face_results` empties the cluster table, so the
/// first naming afterwards knows about exactly one person. The people the
/// sidecars already carry are not that person's to retract.
#[test]
fn naming_after_a_pack_swap_preserves_the_names_already_on_disk() {
    let f = Fixture::new();
    f.enqueue(PHOTOS);
    f.run();
    let id = f.biggest_cluster();
    let target = f.photos_of(id).first().unwrap().clone();
    f.engine.name_cluster(id, "Ada", Some(STAMP), None).unwrap();

    // A face-pack swap: every detection, cluster and membership goes.
    f.engine.cache().reset_face_results().unwrap();
    f.engine.reset_queue().unwrap();
    f.enqueue(PHOTOS);
    f.run();

    let fresh = f.biggest_cluster();
    assert!(
        f.engine.cache().cluster(id).unwrap().is_none(),
        "the old id must not have been handed out again"
    );
    f.engine
        .name_cluster(fresh, "Zoe", Some(STAMP), None)
        .unwrap();

    let view = read_view(&f.sidecar(&target).unwrap()).unwrap();
    assert!(
        view.people_tags().contains(&"People/Ada"),
        "the pre-swap name was retracted: {:?}",
        view.people_tags()
    );
    assert!(view.people_tags().contains(&"People/Zoe"));
}

// ---------------------------------------------------------------------------
// Root scoping
// ---------------------------------------------------------------------------

/// The cache DB outlives any one library root, so a naming can reach rows under
/// a folder the app is no longer inside — outside its security scope, where the
/// write fails and burns a retry. Those paths are skipped instead.
#[test]
fn naming_scoped_to_one_root_skips_the_other_roots_copies() {
    let f = Fixture::with_copies(&[(BRIGHT, "root-a/photo.png"), (BRIGHT, "root-b/photo.png")]);
    f.enqueue(&["root-a/photo.png", "root-b/photo.png"]);
    f.run();

    let root_a = f.dir.path().join("root-a").to_string_lossy().into_owned();
    let id = f.biggest_cluster();
    let plan = f
        .engine
        .name_cluster(id, "Ada", Some(STAMP), Some(&root_a))
        .unwrap();

    assert!(plan.failed.is_empty(), "{:?}", plan.failed);
    assert_eq!(plan.written.len(), 1, "{plan:?}");
    assert!(plan.written[0].contains("root-a"));
    assert_eq!(plan.skipped.len(), 1, "{plan:?}");
    assert!(plan.skipped[0].contains("root-b"));

    assert!(f.sidecar("root-a/photo.png").is_some());
    assert!(
        f.sidecar("root-b/photo.png").is_none(),
        "a sidecar was written outside the root in scope"
    );
}

/// A trailing separator on the root must not change the answer, and a root that
/// is a *string* prefix of a sibling directory must not swallow it.
#[test]
fn root_scoping_matches_directories_not_string_prefixes() {
    let f = Fixture::with_copies(&[(BRIGHT, "photos/a.png"), (BRIGHT, "photos-old/a.png")]);
    f.enqueue(&["photos/a.png", "photos-old/a.png"]);
    f.run();

    let root = f.dir.path().join("photos").to_string_lossy().into_owned();
    let id = f.biggest_cluster();
    let plan = f
        .engine
        .name_cluster(id, "Ada", Some(STAMP), Some(&format!("{root}/")))
        .unwrap();
    assert_eq!(plan.written.len(), 1, "{plan:?}");
    assert!(plan.written[0].contains("/photos/"));
    assert!(f.sidecar("photos-old/a.png").is_none());
}
