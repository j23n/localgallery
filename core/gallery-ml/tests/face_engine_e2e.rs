//! End-to-end: fixture photos in a temp directory → real ONNX detection and
//! embedding → face rows and clusters in a real SQLite cache.
//!
//! Uses the committed `tests/facepack`, which is a genuine schema-2 model pack
//! with genuine (if trivial) ONNX graphs — see `tests/make_test_pack.py` for
//! what the synthetic detector does and why it is not a mock.
//!
//! The three brightness fixtures are the lever: the detector's score is a
//! function of mean brightness, so `face_dark.png` has no faces, `face_mid.png`
//! has one, and `face_bright.png` has several. That makes "did the pipeline
//! find what it should have" a property of the fixture rather than of a model
//! nobody can read.

mod common;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use common::{face_pack_dir, fixture, test_pack_dir};
use gallery_ml::cache::{ClusterState, WorkState};
use gallery_ml::face::{FaceEngine, FaceProgress, FaceRunOptions, FaceRunSummary, NoFaceProgress};
use gallery_ml::{CacheDb, MlError, ModelPack};
use gallery_vfs::StdVfs;

const DARK: &str = "face_dark.png";
const MID: &str = "face_mid.png";
const BRIGHT: &str = "face_bright.png";
const PHOTOS: &[&str] = &[DARK, MID, BRIGHT];

struct Fixture {
    dir: tempfile::TempDir,
    engine: FaceEngine,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture::with_files(PHOTOS)
    }

    fn with_files(names: &[&str]) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        for name in names {
            std::fs::write(dir.path().join(name), fixture(name)).unwrap();
        }
        let engine = FaceEngine::open(
            dir.path().join("gallery-cache.sqlite"),
            face_pack_dir(),
            Arc::new(StdVfs),
        )
        .expect("face pack must load");
        Fixture { dir, engine }
    }

    fn path(&self, name: &str) -> String {
        self.dir.path().join(name).to_string_lossy().into_owned()
    }

    fn paths(&self, names: &[&str]) -> Vec<String> {
        names.iter().map(|n| self.path(n)).collect()
    }

    fn enqueue_all(&self, names: &[&str]) {
        self.engine.enqueue(&self.paths(names)).unwrap();
    }

    fn run(&self) -> FaceRunSummary {
        self.run_with(&NoFaceProgress, &AtomicBool::new(false))
    }

    fn run_with(&self, progress: &dyn FaceProgress, cancel: &AtomicBool) -> FaceRunSummary {
        self.engine
            .run_with_options(progress, cancel, &options())
            .unwrap()
    }

    fn cache(&self) -> CacheDb {
        CacheDb::open(self.dir.path().join("gallery-cache.sqlite")).unwrap()
    }
}

/// One worker, so counts like "cancelled after one photo" are exact rather
/// than racy.
fn options() -> FaceRunOptions {
    FaceRunOptions {
        workers: Some(1),
        limit: None,
        root_prefix: None,
        full_recluster: false,
    }
}

// ---------------------------------------------------------------------------
// Detection and storage
// ---------------------------------------------------------------------------

#[test]
fn a_run_detects_embeds_and_stores_faces() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let summary = f.run();

    assert_eq!(summary.processed, PHOTOS.len());
    assert_eq!(summary.failed, 0);
    assert_eq!(summary.skipped, 0);
    assert_eq!(summary.cache_hits, 0);
    assert!(!summary.cancelled);

    // The fixture contract: brightness decides how many faces the synthetic
    // detector claims.
    assert!(summary.faces_found > 0);
    assert_eq!(
        summary.photos_with_faces, 2,
        "dark should have found nothing"
    );

    let cache = f.cache();
    let pack = ModelPack::load(face_pack_dir()).unwrap();
    let key = pack.face_pack_key().unwrap();
    let dark = gallery_ml::hash::hash_bytes(&fixture(DARK));
    let bright = gallery_ml::hash::hash_bytes(&fixture(BRIGHT));

    // A photo with no faces is *scanned*, not absent — otherwise every run
    // re-detects every faceless photo in the library.
    assert_eq!(cache.face_scan(&dark, &key).unwrap().map(|s| s.0), Some(0));
    assert!(cache.faces_for_hash(&dark).unwrap().is_empty());

    let faces = cache.faces_for_hash(&bright).unwrap();
    assert!(!faces.is_empty());
    for (i, face) in faces.iter().enumerate() {
        assert_eq!(
            face.face_idx, i as u32,
            "face_idx must be dense and ordered"
        );
        assert_eq!(face.image_w, 64);
        assert_eq!(face.image_h, 64);
        assert_eq!(face.embedding.len(), 64);
        let norm: f32 = face.embedding.iter().map(|v| v * v).sum();
        assert!(
            (norm - 1.0).abs() < 1e-4,
            "embedding is not unit length: {norm}"
        );
        assert!((0.0..=1.0).contains(&face.quality), "{}", face.quality);
        assert!(face.bbox[2] > face.bbox[0] && face.bbox[3] > face.bbox[1]);
    }
    // Detections come back score-descending.
    assert!(faces.windows(2).all(|w| w[0].score >= w[1].score));
}

#[test]
fn every_detected_face_lands_in_a_cluster() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let summary = f.run();

    let stats = f.engine.library_stats().unwrap();
    assert_eq!(stats.faces, summary.faces_found as u64);
    assert_eq!(stats.assigned, stats.faces, "a face was left unclustered");
    assert!(stats.unlabeled_clusters > 0);
    assert_eq!(stats.named_clusters, 0, "nothing is named without a human");
    assert_eq!(summary.faces_assigned, summary.faces_found);

    // Every cluster's centroid is a unit vector of the right dimension.
    for cluster in f.engine.clusters().unwrap() {
        assert_eq!(cluster.state, ClusterState::Unlabeled);
        assert_eq!(cluster.centroid.len(), 64);
        let norm: f32 = cluster.centroid.iter().map(|v| v * v).sum();
        assert!(
            (norm - 1.0).abs() < 1e-4,
            "cluster {} centroid: {norm}",
            cluster.id
        );
        assert_eq!(
            cluster.size as usize,
            f.engine.cluster_faces(cluster.id).unwrap().len()
        );
    }
}

/// Two runs over the same library must produce the same faces *and* the same
/// partition — the property that makes the cache shareable at all.
#[test]
fn two_independent_runs_agree_on_faces_and_clusters() {
    let a = Fixture::new();
    a.enqueue_all(PHOTOS);
    a.run();

    let b = Fixture::new();
    b.enqueue_all(PHOTOS);
    b.run();

    for name in PHOTOS {
        let hash = gallery_ml::hash::hash_bytes(&fixture(name));
        assert_eq!(
            a.cache().faces_for_hash(&hash).unwrap(),
            b.cache().faces_for_hash(&hash).unwrap(),
            "{name}"
        );
    }
    let partition = |f: &Fixture| -> Vec<Vec<([u8; 32], u32)>> {
        let mut groups: Vec<_> = f
            .engine
            .clusters()
            .unwrap()
            .into_iter()
            .map(|c| f.cache().cluster_members(c.id).unwrap())
            .collect();
        groups.sort();
        groups
    };
    assert_eq!(partition(&a), partition(&b));
}

/// Parallel workers must not change the answer. Detection is per-photo, but
/// *clustering* reads a shared table, which is why it runs serially after the
/// pool rather than inside it.
#[test]
fn parallel_workers_produce_the_same_partition_as_one() {
    let serial = Fixture::new();
    serial.enqueue_all(PHOTOS);
    serial.run();

    let parallel = Fixture::new();
    parallel.enqueue_all(PHOTOS);
    parallel
        .engine
        .run_with_options(
            &NoFaceProgress,
            &AtomicBool::new(false),
            &FaceRunOptions {
                workers: Some(gallery_ml::MAX_WORKERS),
                ..options()
            },
        )
        .unwrap();

    for name in PHOTOS {
        let hash = gallery_ml::hash::hash_bytes(&fixture(name));
        assert_eq!(
            serial.cache().faces_for_hash(&hash).unwrap(),
            parallel.cache().faces_for_hash(&hash).unwrap(),
            "{name}"
        );
    }
    assert_eq!(
        serial.engine.library_stats().unwrap(),
        parallel.engine.library_stats().unwrap()
    );
}

// ---------------------------------------------------------------------------
// The cache
// ---------------------------------------------------------------------------

#[test]
fn a_second_run_is_a_no_op_and_hits_the_detection_cache() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let first = f.run();
    let before = f.engine.library_stats().unwrap();

    // `done` rows are not claimable, so re-running needs the queue reset. The
    // faces survive it, which is the point of splitting the tables.
    f.engine.reset_queue().unwrap();
    f.enqueue_all(PHOTOS);
    let second = f.run();

    assert_eq!(second.processed, PHOTOS.len());
    assert_eq!(
        second.cache_hits,
        PHOTOS.len(),
        "the second run re-detected instead of reading the cache"
    );
    assert_eq!(second.faces_found, first.faces_found);
    assert_eq!(second.faces_assigned, 0, "faces were re-clustered");
    assert_eq!(second.clusters_created, 0);
    assert_eq!(f.engine.library_stats().unwrap(), before);
}

/// Two copies of one photo share the detection and the embedding, and cost one
/// inference between them.
#[test]
fn a_duplicate_photo_reuses_the_detection() {
    let f = Fixture::with_files(&[BRIGHT]);
    std::fs::write(f.dir.path().join("copy.png"), fixture(BRIGHT)).unwrap();
    f.enqueue_all(&[BRIGHT, "copy.png"]);
    let summary = f.run();

    assert_eq!(summary.processed, 2);
    assert_eq!(summary.cache_hits, 1);
    // Both rows point at the same content hash, and there is one set of faces.
    let cache = f.cache();
    let hash = gallery_ml::hash::hash_bytes(&fixture(BRIGHT));
    assert_eq!(
        cache
            .face_item(&f.path(BRIGHT))
            .unwrap()
            .unwrap()
            .content_hash,
        Some(hash)
    );
    assert_eq!(
        cache
            .face_item(&f.path("copy.png"))
            .unwrap()
            .unwrap()
            .content_hash,
        Some(hash)
    );
    assert_eq!(
        f.engine.library_stats().unwrap().faces as usize,
        cache.faces_for_hash(&hash).unwrap().len()
    );
}

/// `done` is not claimable, so without the re-stat pass a photo edited in place
/// would keep its old faces forever.
#[test]
fn a_photo_edited_in_place_is_re_detected_without_a_reset() {
    let f = Fixture::with_files(&[DARK]);
    f.enqueue_all(&[DARK]);
    assert_eq!(f.run().faces_found, 0);

    std::fs::write(f.dir.path().join(DARK), fixture(BRIGHT)).unwrap();
    let summary = f.run();
    assert_eq!(summary.processed, 1, "the edit was never noticed");
    assert!(summary.faces_found > 0, "the new content was not detected");

    // And an unchanged file is not re-detected on every run after that.
    assert_eq!(f.run().processed, 0);
}

/// The face models changing invalidates the embedding space, so everything
/// derived from it goes — but the *tagging* rows are none of its business.
#[test]
fn swapping_the_face_models_clears_the_faces_but_not_the_tagging_queue() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    f.run();
    assert!(f.engine.library_stats().unwrap().faces > 0);

    let cache = f.cache();
    cache.enqueue(&f.paths(PHOTOS)).unwrap();
    assert_eq!(cache.stats().unwrap().pending, PHOTOS.len() as u64);
    drop(cache);

    // A pack claiming different face weights.
    let swapped = repacked_faces();
    let engine = FaceEngine::open(
        f.dir.path().join("gallery-cache.sqlite"),
        swapped.path(),
        Arc::new(StdVfs),
    )
    .unwrap();
    assert_eq!(engine.library_stats().unwrap().faces, 0);
    // The face queue survives — it is what refills the tables.
    assert_eq!(engine.stats().unwrap().pending, PHOTOS.len() as u64);
    // And tagging never noticed.
    assert_eq!(f.cache().stats().unwrap().pending, PHOTOS.len() as u64);
}

/// A copy of the face pack with the detector's bytes (and so its hash) changed.
fn repacked_faces() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let src = face_pack_dir();
    for name in [
        "encoder.onnx",
        "labels.json",
        "label_embeddings.f32",
        "face_embedder.onnx",
    ] {
        std::fs::copy(src.join(name), dir.path().join(name)).unwrap();
    }
    // Pad the detector with an ONNX-legal trailing no-op field so the bytes —
    // and therefore the hash — change while the graph still loads.
    let mut bytes = std::fs::read(src.join("face_detector.onnx")).unwrap();
    bytes.extend_from_slice(&[0xC2, 0x02, 0x01, b'x']); // field 40, len-1 string
    std::fs::write(dir.path().join("face_detector.onnx"), &bytes).unwrap();

    let mut manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(src.join("manifest.json")).unwrap()).unwrap();
    manifest["faces"]["detector"]["sha256"] = serde_json::json!(common::sha256_hex(&bytes));
    std::fs::write(
        dir.path().join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();
    dir
}

// ---------------------------------------------------------------------------
// Failure, cancellation, resume
// ---------------------------------------------------------------------------

#[test]
fn an_unsupported_extension_is_skipped_and_a_corrupt_image_fails() {
    let f = Fixture::with_files(&[BRIGHT, "notes.txt", "broken.jpg"]);
    f.enqueue_all(&[BRIGHT, "notes.txt", "broken.jpg"]);
    let summary = f.run();

    assert_eq!(summary.skipped, 1);
    assert_eq!(summary.failed, 1);
    assert!(summary.faces_found > 0, "the good photo still ran");
    let stats = f.engine.stats().unwrap();
    assert_eq!(stats.skipped, 1);
    // The broken JPEG has retries left, so it is pending work, not a permanent
    // failure.
    assert_eq!(stats.failed, 0);
    assert_eq!(stats.pending, 1);
}

#[test]
fn cancellation_stops_promptly_releases_the_row_and_resumes() {
    struct CancelAfterFirst {
        cancel: Arc<AtomicBool>,
        seen: AtomicUsize,
    }
    impl FaceProgress for CancelAfterFirst {
        fn on_progress(&self, _done: usize, _total: usize) {
            if self.seen.fetch_add(1, Ordering::SeqCst) == 0 {
                self.cancel.store(true, Ordering::SeqCst);
            }
        }
        fn on_photos_with_faces(&self, _paths: &[String]) {}
        fn on_finished(&self, _summary: &FaceRunSummary) {}
    }

    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let cancel = Arc::new(AtomicBool::new(false));
    let progress = CancelAfterFirst {
        cancel: Arc::clone(&cancel),
        seen: AtomicUsize::new(0),
    };
    let summary = f.run_with(&progress, &cancel);

    assert!(summary.cancelled);
    assert!(summary.processed < PHOTOS.len());
    // Nothing stuck claimed, nothing charged a retry.
    let cache = f.cache();
    for path in f.paths(PHOTOS) {
        let item = cache.face_item(&path).unwrap().unwrap();
        assert_ne!(item.state, WorkState::Hashing, "{path} left claimed");
        assert_ne!(item.state, WorkState::Failed, "{path} counted as a failure");
    }
    // What it *did* detect is clustered — a half-run library must still show
    // people, not faces in limbo.
    let stats = f.engine.library_stats().unwrap();
    assert_eq!(stats.assigned, stats.faces);

    // And the run resumes to the same end state as an uninterrupted one.
    let resumed = f.run();
    assert!(!resumed.cancelled);

    let reference = Fixture::new();
    reference.enqueue_all(PHOTOS);
    reference.run();
    assert_eq!(
        f.engine.library_stats().unwrap(),
        reference.engine.library_stats().unwrap()
    );
}

#[test]
fn a_row_stranded_mid_flight_is_reclaimed_by_the_next_run() {
    let f = Fixture::with_files(&[BRIGHT]);
    f.enqueue_all(&[BRIGHT]);

    let stranded = f.cache();
    assert!(stranded.face_begin(&f.path(BRIGHT)).unwrap());
    drop(stranded);

    assert_eq!(
        f.run().processed,
        1,
        "the stranded row was never re-claimed"
    );
}

#[test]
fn a_run_scoped_to_a_root_leaves_other_roots_alone() {
    let dir = tempfile::tempdir().unwrap();
    let current = dir.path().join("Current");
    let previous = dir.path().join("Previous");
    std::fs::create_dir_all(&current).unwrap();
    std::fs::create_dir_all(&previous).unwrap();
    std::fs::write(current.join(BRIGHT), fixture(BRIGHT)).unwrap();
    std::fs::write(previous.join(MID), fixture(MID)).unwrap();

    let engine = FaceEngine::open(
        dir.path().join("c.sqlite"),
        face_pack_dir(),
        Arc::new(StdVfs),
    )
    .unwrap();
    let in_scope = current.join(BRIGHT).to_string_lossy().into_owned();
    let out_of_scope = previous.join(MID).to_string_lossy().into_owned();
    engine
        .enqueue(&[in_scope.clone(), out_of_scope.clone()])
        .unwrap();

    let summary = engine
        .run_with_options(
            &NoFaceProgress,
            &AtomicBool::new(false),
            &FaceRunOptions {
                // No trailing separator: the engine adds one, so `CurrentOld`
                // could not be swept in.
                root_prefix: Some(current.to_string_lossy().into_owned()),
                ..options()
            },
        )
        .unwrap();

    assert_eq!(summary.processed, 1);
    let cache = CacheDb::open(dir.path().join("c.sqlite")).unwrap();
    let item = cache.face_item(&out_of_scope).unwrap().unwrap();
    assert_eq!(item.state, WorkState::Pending);
    assert_eq!(item.retry_count, 0);
}

#[test]
fn progress_reports_every_photo_and_finishes_once() {
    #[derive(Default)]
    struct Recorder {
        progress: Mutex<Vec<(usize, usize)>>,
        with_faces: Mutex<Vec<String>>,
        finished: AtomicUsize,
    }
    impl FaceProgress for Recorder {
        fn on_progress(&self, done: usize, total: usize) {
            self.progress.lock().unwrap().push((done, total));
        }
        fn on_photos_with_faces(&self, paths: &[String]) {
            self.with_faces.lock().unwrap().extend_from_slice(paths);
        }
        fn on_finished(&self, _summary: &FaceRunSummary) {
            self.finished.fetch_add(1, Ordering::SeqCst);
        }
    }

    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let recorder = Recorder::default();
    f.run_with(&recorder, &AtomicBool::new(false));

    assert_eq!(recorder.finished.load(Ordering::SeqCst), 1);
    let progress = recorder.progress.lock().unwrap().clone();
    assert_eq!(progress.last().unwrap().0, PHOTOS.len());
    assert!(progress.iter().all(|(_, total)| *total == PHOTOS.len()));

    let mut reported = recorder.with_faces.lock().unwrap().clone();
    reported.sort();
    let mut expected = f.paths(&[BRIGHT, MID]);
    expected.sort();
    assert_eq!(reported, expected, "only photos with faces are reported");
}

/// An error before any worker starts still owes the caller an `on_finished` —
/// the app turns that callback into "the run is over".
#[test]
fn a_run_that_fails_before_it_starts_still_reports_finished() {
    #[derive(Default)]
    struct FinishRecorder {
        calls: Mutex<Vec<FaceRunSummary>>,
    }
    impl FaceProgress for FinishRecorder {
        fn on_progress(&self, _done: usize, _total: usize) {}
        fn on_photos_with_faces(&self, _paths: &[String]) {}
        fn on_finished(&self, summary: &FaceRunSummary) {
            self.calls.lock().unwrap().push(*summary);
        }
    }

    let f = Fixture::new();
    let raw = rusqlite::Connection::open(f.dir.path().join("gallery-cache.sqlite")).unwrap();
    raw.execute_batch("DROP TABLE face_work").unwrap();
    drop(raw);

    let recorder = FinishRecorder::default();
    let result = f
        .engine
        .run_with_options(&recorder, &AtomicBool::new(false), &options());
    assert!(matches!(result, Err(MlError::Cache { .. })), "{result:?}");
    assert_eq!(recorder.calls.lock().unwrap().len(), 1);
    assert_eq!(recorder.calls.lock().unwrap()[0], FaceRunSummary::default());
}

// ---------------------------------------------------------------------------
// Re-clustering
// ---------------------------------------------------------------------------

/// Note what this can and cannot show. The committed pack's embedder is a
/// randomly-initialized conv net, and an untrained network maps everything into
/// a narrow cone — every crop of every fixture ends up in one cluster. So this
/// asserts that the two paths *agree*, and that the full pass conserves faces
/// and leaves the library consistent; it cannot assert that either one splits
/// identities correctly. That property is tested where it can be controlled, in
/// `face::cluster`'s unit tests, over hand-built vectors.
#[test]
fn a_full_recluster_reproduces_the_incremental_partition_on_this_fixture_set() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    f.run();
    let incremental: Vec<usize> = {
        let mut sizes: Vec<usize> = f
            .engine
            .clusters()
            .unwrap()
            .iter()
            .map(|c| c.size as usize)
            .collect();
        sizes.sort_unstable();
        sizes
    };

    let summary = f.engine.recluster().unwrap();
    assert_eq!(
        summary.faces,
        f.engine.library_stats().unwrap().faces as usize
    );
    let mut after: Vec<usize> = f
        .engine
        .clusters()
        .unwrap()
        .iter()
        .map(|c| c.size as usize)
        .collect();
    after.sort_unstable();
    assert_eq!(
        after, incremental,
        "the full pass disagreed with the incremental one on well-separated faces"
    );
    // Every face is still accounted for.
    let stats = f.engine.library_stats().unwrap();
    assert_eq!(stats.assigned, stats.faces);
}

#[test]
fn a_named_cluster_survives_a_full_recluster() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    f.run();

    let cache = f.cache();
    let target = f.engine.clusters().unwrap()[0].clone();
    let members = cache.cluster_members(target.id).unwrap();
    cache
        .set_cluster_state(target.id, ClusterState::Named, Some("Alice"))
        .unwrap();
    drop(cache);

    f.engine.recluster().unwrap();

    let after: Vec<_> = f
        .engine
        .clusters()
        .unwrap()
        .into_iter()
        .filter(|c| c.state == ClusterState::Named)
        .collect();
    assert_eq!(after.len(), 1);
    assert_eq!(
        after[0].id, target.id,
        "a named cluster's id must be stable"
    );
    assert_eq!(after[0].person_name.as_deref(), Some("Alice"));
    assert_eq!(f.cache().cluster_members(target.id).unwrap(), members);
}

#[test]
fn reclustering_is_idempotent() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    f.run();

    let partition = |f: &Fixture| -> Vec<Vec<([u8; 32], u32)>> {
        let cache = f.cache();
        let mut groups: Vec<_> = f
            .engine
            .clusters()
            .unwrap()
            .into_iter()
            .map(|c| cache.cluster_members(c.id).unwrap())
            .collect();
        groups.sort();
        groups
    };

    f.engine.recluster().unwrap();
    let once = partition(&f);
    f.engine.recluster().unwrap();
    assert_eq!(partition(&f), once);
}

// ---------------------------------------------------------------------------
// A pack without face models
// ---------------------------------------------------------------------------

/// The whole reason `faces` is optional in the manifest.
#[test]
fn a_tagging_only_pack_makes_the_face_engine_unavailable() {
    let dir = tempfile::tempdir().unwrap();
    let err = FaceEngine::open(
        dir.path().join("c.sqlite"),
        test_pack_dir(),
        Arc::new(StdVfs),
    )
    .unwrap_err();
    assert!(
        matches!(err, MlError::FaceModelsUnavailable),
        "a tagging-only pack must be reported as unavailable, not broken: {err:?}"
    );

    // …and it is still a perfectly good pack for tagging.
    let pack = ModelPack::load(test_pack_dir()).unwrap();
    assert!(pack.faces().is_none());
    assert!(pack.face_pack_key().is_none());
    assert_eq!(pack.version(), "gallery-ml-testpack-1");
    assert_eq!(pack.labels.len(), 6);

    let engine = gallery_ml::TaggingEngine::open(
        dir.path().join("c.sqlite"),
        test_pack_dir(),
        Arc::new(StdVfs),
    )
    .unwrap();
    let photo = dir.path().join("gradient.jpg");
    std::fs::write(&photo, fixture("gradient.jpg")).unwrap();
    engine
        .enqueue(&[photo.to_string_lossy().into_owned()])
        .unwrap();
    let summary = engine
        .run(&gallery_ml::NoProgress, &AtomicBool::new(false))
        .unwrap();
    assert_eq!(summary.failed, 0);
    assert_eq!(summary.sidecars_written, 1);
}

/// The two pipelines share a cache file and must not disturb each other's rows.
#[test]
fn tagging_and_faces_run_over_the_same_cache_without_interfering() {
    let dir = tempfile::tempdir().unwrap();
    for name in PHOTOS {
        std::fs::write(dir.path().join(name), fixture(name)).unwrap();
    }
    let paths: Vec<String> = PHOTOS
        .iter()
        .map(|n| dir.path().join(n).to_string_lossy().into_owned())
        .collect();
    let cache_path = dir.path().join("c.sqlite");

    let tagging =
        gallery_ml::TaggingEngine::open(&cache_path, face_pack_dir(), Arc::new(StdVfs)).unwrap();
    let faces = FaceEngine::open(&cache_path, face_pack_dir(), Arc::new(StdVfs)).unwrap();

    tagging.enqueue(&paths).unwrap();
    faces.enqueue(&paths).unwrap();

    let tag_summary = tagging
        .run(&gallery_ml::NoProgress, &AtomicBool::new(false))
        .unwrap();
    assert_eq!(tag_summary.processed, PHOTOS.len());
    // Tagging finishing does not finish the face queue.
    assert_eq!(faces.stats().unwrap().pending, PHOTOS.len() as u64);
    assert_eq!(faces.stats().unwrap().done, 0);

    let face_summary = faces.run(&NoFaceProgress, &AtomicBool::new(false)).unwrap();
    assert_eq!(face_summary.processed, PHOTOS.len());
    assert_eq!(face_summary.failed, 0);
    // …and the tagging rows are untouched by the face run.
    assert_eq!(tagging.stats().unwrap().done, PHOTOS.len() as u64);
    assert_eq!(tagging.stats().unwrap().pending, 0);
}
