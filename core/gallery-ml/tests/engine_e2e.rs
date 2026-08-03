//! End-to-end: fixture photos in a temp directory → real ONNX inference →
//! real `.xmp` sidecars, read back through gallery-meta.
//!
//! This is the test that would catch an integration mistake nothing else can:
//! a wrong ONNX input name, an NCHW/NHWC mix-up, a sidecar written to the
//! wrong path, an embedding cached under a key that never hits, a re-run that
//! churns mtimes. It uses the committed test pack (`tests/testpack`), which is
//! a genuine ONNX model — see `tests/make_test_pack.py`.

mod common;

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use common::{fixture, test_pack_dir};
use gallery_ml::cache::WorkState;
use gallery_ml::{
    CacheDb, ModelPack, NoProgress, RunOptions, RunSummary, TaggingEngine, TaggingProgress,
};
use gallery_vfs::{StdVfs, Vfs};

/// Fixed so sidecar bytes are reproducible across runs — `gallery-meta` writes
/// this string verbatim into the sentinel.
const TAGGED_AT: &str = "2026-08-03T10:00:00Z";

const PHOTOS: &[&str] = &["gradient.jpg", "stripes.jpg", "meadow.png"];

struct Fixture {
    dir: tempfile::TempDir,
    engine: TaggingEngine,
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
        let engine = TaggingEngine::open(
            dir.path().join("gallery-cache.sqlite"),
            test_pack_dir(),
            Arc::new(StdVfs),
        )
        .expect("test pack must load");
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

    fn run(&self) -> RunSummary {
        self.run_with(&NoProgress, &AtomicBool::new(false))
    }

    fn run_with(&self, progress: &dyn TaggingProgress, cancel: &AtomicBool) -> RunSummary {
        self.engine
            .run_with_options(
                progress,
                cancel,
                &RunOptions {
                    // One worker: the assertions are about *what* happened, and
                    // a single worker makes counts like "cancelled after 1
                    // item" exact rather than racy.
                    workers: Some(1),
                    limit: None,
                    tagged_at: Some(TAGGED_AT.to_string()),
                },
            )
            .unwrap()
    }

    fn sidecar_bytes(&self, name: &str) -> Vec<u8> {
        std::fs::read(self.dir.path().join(format!("{name}.xmp"))).unwrap()
    }

    fn tags(&self, name: &str) -> Vec<String> {
        let view = gallery_meta::read_view(&self.sidecar_bytes(name)).unwrap();
        view.tags_list
    }

    fn all_tags(&self) -> BTreeMap<&'static str, Vec<String>> {
        PHOTOS.iter().map(|n| (*n, self.tags(n))).collect()
    }
}

/// The tags the committed pack produces for the committed fixtures.
///
/// These are as much a property of the pack as the golden tensor hashes are of
/// the preprocessor: thresholds in `labels.json` were chosen so the fixtures
/// land on *these* sets and not on "everything" or "nothing", which are the
/// two ways a threshold test passes without testing anything.
fn expected_tags() -> BTreeMap<&'static str, Vec<String>> {
    BTreeMap::from([
        // Three Objects labels clear their bars; the root's `max_tags: 2`
        // drops the weakest (Cat).
        (
            "gradient.jpg",
            vec![
                "Objects/Animal/Dog".to_string(),
                "Objects/Vehicle/Car".to_string(),
                "Scenes/Nature/Forest".to_string(),
            ],
        ),
        // Clears nothing under Objects at all — sparse output is a valid
        // result, and the writer must not invent one.
        ("stripes.jpg", vec!["Scenes/Urban/Street".to_string()]),
        (
            "meadow.png",
            vec![
                "Objects/Animal/Dog".to_string(),
                "Objects/Vehicle/Car".to_string(),
                "Scenes/Nature/Forest".to_string(),
            ],
        ),
    ])
}

#[test]
fn a_run_writes_the_expected_tags_into_real_sidecars() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let summary = f.run();

    assert_eq!(summary.processed, PHOTOS.len());
    assert_eq!(summary.failed, 0);
    assert_eq!(summary.skipped, 0);
    assert_eq!(summary.cache_hits, 0);
    assert!(!summary.cancelled);
    assert_eq!(summary.sidecars_written, PHOTOS.len());
    assert_eq!(f.all_tags(), expected_tags());
}

#[test]
fn sidecars_land_next_to_the_photo_with_the_suffix_preserved() {
    let f = Fixture::new();
    f.enqueue_all(&["gradient.jpg"]);
    f.run();
    assert!(f.dir.path().join("gradient.jpg.xmp").exists());
    assert!(!f.dir.path().join("gradient.xmp").exists());
}

#[test]
fn the_sentinel_records_this_agent_and_pack() {
    let f = Fixture::new();
    f.enqueue_all(&["gradient.jpg"]);
    f.run();
    let view = gallery_meta::read_view(&f.sidecar_bytes("gradient.jpg")).unwrap();
    assert_eq!(view.core.agent.as_deref(), Some(gallery_meta::CORE_AGENT));
    assert_eq!(
        view.core.model_pack.as_deref(),
        Some("gallery-ml-testpack-1")
    );
    assert_eq!(view.core.tagged_at.as_deref(), Some(TAGGED_AT));
    assert_eq!(view.core.tags, expected_tags()["gradient.jpg"]);
    // dc:subject carries the leaves, not the paths.
    assert!(
        view.subject.contains(&"Car".to_string()),
        "{:?}",
        view.subject
    );
    assert!(!view.subject.contains(&"Objects/Vehicle/Car".to_string()));
}

#[test]
fn a_second_run_is_a_no_op_and_hits_the_embedding_cache() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    f.run();
    let before: Vec<Vec<u8>> = PHOTOS.iter().map(|n| f.sidecar_bytes(n)).collect();

    // `done` rows are not claimable, so re-tagging needs the queue reset. The
    // embeddings survive it — that is the point of splitting the two tables.
    f.engine.reset_queue().unwrap();
    f.enqueue_all(PHOTOS);
    let summary = f.run();

    assert_eq!(summary.processed, PHOTOS.len());
    assert_eq!(
        summary.cache_hits,
        PHOTOS.len(),
        "second run re-ran inference instead of reading the embedding cache"
    );
    assert_eq!(
        summary.sidecars_written, 0,
        "second run rewrote sidecars — mtimes churn and the app's sidecar sync storms"
    );
    let after: Vec<Vec<u8>> = PHOTOS.iter().map(|n| f.sidecar_bytes(n)).collect();
    assert_eq!(before, after);
}

#[test]
fn two_independent_runs_produce_byte_identical_sidecars() {
    let a = Fixture::new();
    a.enqueue_all(PHOTOS);
    a.run();

    let b = Fixture::new();
    b.enqueue_all(PHOTOS);
    b.run();

    for name in PHOTOS {
        assert_eq!(
            a.sidecar_bytes(name),
            b.sidecar_bytes(name),
            "{name}: two runs disagreed byte-for-byte"
        );
    }
}

#[test]
fn an_unsupported_extension_is_skipped_not_failed() {
    let f = Fixture::with_files(&["gradient.jpg", "notes.txt"]);
    f.enqueue_all(&["gradient.jpg", "notes.txt"]);
    let summary = f.run();

    assert_eq!(summary.skipped, 1);
    assert_eq!(summary.failed, 0);
    assert!(!f.dir.path().join("notes.txt.xmp").exists());
    let item = f.engine.stats().unwrap();
    assert_eq!(item.skipped, 1);
}

#[test]
fn a_corrupt_image_fails_without_taking_the_run_down() {
    let f = Fixture::with_files(&["gradient.jpg", "broken.jpg"]);
    f.enqueue_all(&["gradient.jpg", "broken.jpg"]);
    let summary = f.run();

    assert_eq!(summary.failed, 1);
    assert_eq!(summary.sidecars_written, 1);
    assert_eq!(f.tags("gradient.jpg"), expected_tags()["gradient.jpg"]);
}

#[test]
fn a_file_that_vanished_between_enqueue_and_run_fails_cleanly() {
    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    std::fs::remove_file(f.dir.path().join("stripes.jpg")).unwrap();
    let summary = f.run();
    assert_eq!(summary.failed, 1);
    assert_eq!(summary.processed, PHOTOS.len());
}

#[test]
fn cancellation_stops_promptly_and_releases_the_in_flight_row() {
    /// Sets the cancel flag as soon as the first item completes.
    struct CancelAfterFirst {
        cancel: Arc<AtomicBool>,
        seen: AtomicUsize,
    }
    impl TaggingProgress for CancelAfterFirst {
        fn on_progress(&self, _done: usize, _total: usize) {
            if self.seen.fetch_add(1, Ordering::SeqCst) == 0 {
                self.cancel.store(true, Ordering::SeqCst);
            }
        }
        fn on_photos_tagged(&self, _paths: &[String]) {}
        fn on_finished(&self, _summary: &RunSummary) {}
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
    assert!(
        summary.processed < PHOTOS.len(),
        "cancellation did not stop the run: processed {} of {}",
        summary.processed,
        PHOTOS.len()
    );
    // Nothing is stuck in `hashing`, and nothing burned a retry.
    let db = CacheDb::open(f.dir.path().join("gallery-cache.sqlite")).unwrap();
    for path in f.paths(PHOTOS) {
        let item = db.item(&path).unwrap().unwrap();
        assert_ne!(item.state, WorkState::Hashing, "{path} left claimed");
        assert_ne!(item.state, WorkState::Failed, "{path} counted as a failure");
    }

    // And the run resumes: a fresh engine over the same cache finishes it.
    let resumed = f.run();
    assert!(!resumed.cancelled);
    assert_eq!(f.all_tags(), expected_tags());
}

#[test]
fn hysteresis_retains_a_tag_that_drifts_just_below_its_threshold() {
    // Raise every threshold by a hair less than epsilon, so each tag now
    // *fails* its bar but is still inside the retention band. A first run
    // under the shipped pack claims the tags; a second run under the tightened
    // pack must keep them.
    let f = Fixture::new();
    f.enqueue_all(&["gradient.jpg"]);
    f.run();
    let claimed = f.tags("gradient.jpg");
    assert!(!claimed.is_empty());

    let tightened = tightened_pack(0.04);
    let engine = TaggingEngine::open(
        f.dir.path().join("cache2.sqlite"),
        tightened.path(),
        Arc::new(StdVfs),
    )
    .unwrap();
    engine.enqueue(&f.paths(&["gradient.jpg"])).unwrap();
    engine
        .run_with_options(
            &NoProgress,
            &AtomicBool::new(false),
            &RunOptions {
                workers: Some(1),
                limit: None,
                tagged_at: Some(TAGGED_AT.to_string()),
            },
        )
        .unwrap();
    assert_eq!(
        f.tags("gradient.jpg"),
        claimed,
        "hysteresis failed to retain tags inside the epsilon band"
    );

    // Push past the band and the same tags are retracted.
    let far = tightened_pack(0.30);
    let engine = TaggingEngine::open(
        f.dir.path().join("cache3.sqlite"),
        far.path(),
        Arc::new(StdVfs),
    )
    .unwrap();
    engine.enqueue(&f.paths(&["gradient.jpg"])).unwrap();
    engine
        .run_with_options(
            &NoProgress,
            &AtomicBool::new(false),
            &RunOptions {
                workers: Some(1),
                limit: None,
                tagged_at: Some(TAGGED_AT.to_string()),
            },
        )
        .unwrap();
    assert!(
        f.tags("gradient.jpg").is_empty(),
        "tags below the band survived: {:?}",
        f.tags("gradient.jpg")
    );
}

/// A copy of the test pack with every label threshold raised by `bump`.
fn tightened_pack(bump: f32) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let src = test_pack_dir();
    for name in ["manifest.json", "encoder.onnx", "label_embeddings.f32"] {
        std::fs::copy(src.join(name), dir.path().join(name)).unwrap();
    }

    let mut manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(src.join("manifest.json")).unwrap()).unwrap();

    let mut labels: serde_json::Value =
        serde_json::from_slice(&std::fs::read(src.join("labels.json")).unwrap()).unwrap();
    for label in labels["labels"].as_array_mut().unwrap() {
        // A label with no explicit threshold inherits its root's; bump the
        // root instead of materialising an override, so the inheritance path
        // stays exercised.
        if let Some(t) = label["threshold"].as_f64() {
            label["threshold"] = serde_json::json!(t + f64::from(bump));
        }
    }
    let labels_bytes = serde_json::to_vec_pretty(&labels).unwrap();
    std::fs::write(dir.path().join("labels.json"), &labels_bytes).unwrap();

    for (_, cfg) in manifest["roots"].as_object_mut().unwrap().iter_mut() {
        let t = cfg["threshold"].as_f64().unwrap();
        cfg["threshold"] = serde_json::json!(t + f64::from(bump));
    }
    // The manifest declares the hash of what it points at; editing labels.json
    // without fixing it would (correctly) fail the load.
    manifest["labels"]["sha256"] = serde_json::json!(common::sha256_hex(&labels_bytes));
    // A distinct pack version, or the engine would treat the rows as current.
    manifest["pack_version"] = serde_json::json!(format!("tightened-{bump}"));
    std::fs::write(
        dir.path().join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();
    dir
}

#[test]
fn a_photo_with_no_tags_gets_no_sidecar() {
    // With every threshold pushed out of reach, nothing scores. The run must
    // still succeed — and must not litter the library with sentinel-only
    // sidecars, one per untagged photo.
    let f = Fixture::new();
    let unreachable = tightened_pack(2.0);
    let engine = TaggingEngine::open(
        f.dir.path().join("c.sqlite"),
        unreachable.path(),
        Arc::new(StdVfs),
    )
    .unwrap();
    engine.enqueue(&f.paths(PHOTOS)).unwrap();
    let summary = engine
        .run_with_options(
            &NoProgress,
            &AtomicBool::new(false),
            &RunOptions {
                workers: Some(1),
                limit: None,
                tagged_at: Some(TAGGED_AT.to_string()),
            },
        )
        .unwrap();

    assert_eq!(summary.processed, PHOTOS.len());
    assert_eq!(summary.failed, 0);
    assert_eq!(summary.tagged, 0);
    assert_eq!(summary.sidecars_written, 0);
    for name in PHOTOS {
        assert!(
            !f.dir.path().join(format!("{name}.xmp")).exists(),
            "{name} got an empty sidecar"
        );
    }
}

#[test]
fn an_empty_result_still_retracts_tags_from_an_existing_sidecar() {
    let f = Fixture::new();
    f.enqueue_all(&["gradient.jpg"]);
    f.run();
    assert!(!f.tags("gradient.jpg").is_empty());

    let unreachable = tightened_pack(2.0);
    let engine = TaggingEngine::open(
        f.dir.path().join("c2.sqlite"),
        unreachable.path(),
        Arc::new(StdVfs),
    )
    .unwrap();
    engine.enqueue(&f.paths(&["gradient.jpg"])).unwrap();
    engine
        .run_with_options(
            &NoProgress,
            &AtomicBool::new(false),
            &RunOptions {
                workers: Some(1),
                limit: None,
                tagged_at: Some(TAGGED_AT.to_string()),
            },
        )
        .unwrap();

    assert!(
        f.tags("gradient.jpg").is_empty(),
        "tags survived a run that scored nothing: {:?}",
        f.tags("gradient.jpg")
    );
}

#[test]
fn a_tampered_pack_file_is_refused() {
    let dir = tightened_pack(0.0);
    // Corrupt the ONNX without touching the manifest.
    let mut bytes = std::fs::read(dir.path().join("encoder.onnx")).unwrap();
    bytes[64] ^= 0xFF;
    std::fs::write(dir.path().join("encoder.onnx"), bytes).unwrap();

    let cache = tempfile::tempdir().unwrap();
    let err = TaggingEngine::open(cache.path().join("c.sqlite"), dir.path(), Arc::new(StdVfs))
        .unwrap_err();
    assert!(
        matches!(err, gallery_ml::MlError::PackHashMismatch { .. }),
        "{err:?}"
    );
}

#[test]
fn progress_reports_every_item_and_finishes_once() {
    #[derive(Default)]
    struct Recorder {
        progress: Mutex<Vec<(usize, usize)>>,
        tagged: Mutex<Vec<String>>,
        finished: AtomicUsize,
    }
    impl TaggingProgress for Recorder {
        fn on_progress(&self, done: usize, total: usize) {
            self.progress.lock().unwrap().push((done, total));
        }
        fn on_photos_tagged(&self, paths: &[String]) {
            self.tagged.lock().unwrap().extend_from_slice(paths);
        }
        fn on_finished(&self, _summary: &RunSummary) {
            self.finished.fetch_add(1, Ordering::SeqCst);
        }
    }

    let f = Fixture::new();
    f.enqueue_all(PHOTOS);
    let recorder = Recorder::default();
    let summary = f.run_with(&recorder, &AtomicBool::new(false));

    assert_eq!(recorder.finished.load(Ordering::SeqCst), 1);
    let progress = recorder.progress.lock().unwrap().clone();
    assert!(!progress.is_empty());
    assert!(progress.iter().all(|(_, total)| *total == PHOTOS.len()));
    // The throttle may swallow intermediate calls, but the final flush must
    // report the true count.
    assert_eq!(progress.last().unwrap().0, PHOTOS.len());

    let mut tagged = recorder.tagged.lock().unwrap().clone();
    tagged.sort();
    let mut expected = f.paths(PHOTOS);
    expected.sort();
    assert_eq!(tagged, expected);
    assert_eq!(summary.sidecars_written, PHOTOS.len());
}

#[test]
fn an_existing_sidecar_keeps_the_fields_the_core_does_not_own() {
    let f = Fixture::with_files(&["gradient.jpg"]);
    // A sidecar as photo-tools would leave it: a person tag, a country code
    // and a human keyword. None of it is ours; all of it must survive.
    let existing = br#"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:digiKam="http://www.digikam.org/ns/1.0/"
    xmlns:phototools="https://github.com/j23n/photo-tools/ns/1.0/"
    phototools:CountryCode="IT">
   <dc:subject><rdf:Bag><rdf:li>Holiday</rdf:li></rdf:Bag></dc:subject>
   <digiKam:TagsList><rdf:Seq>
     <rdf:li>People/Alice</rdf:li>
     <rdf:li>Places/Italy/Rome</rdf:li>
   </rdf:Seq></digiKam:TagsList>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#;
    std::fs::write(f.dir.path().join("gradient.jpg.xmp"), existing).unwrap();

    f.enqueue_all(&["gradient.jpg"]);
    f.run();

    let view = gallery_meta::read_view(&f.sidecar_bytes("gradient.jpg")).unwrap();
    assert!(view.tags_list.contains(&"People/Alice".to_string()));
    assert!(view.tags_list.contains(&"Places/Italy/Rome".to_string()));
    assert!(view.subject.contains(&"Holiday".to_string()));
    assert_eq!(view.photo_tools.country_code.as_deref(), Some("IT"));
    for tag in &expected_tags()["gradient.jpg"] {
        assert!(view.tags_list.contains(tag), "{tag} missing");
    }
    // And the sentinel claims only what we added.
    assert_eq!(view.core.tags, expected_tags()["gradient.jpg"]);
}

#[test]
fn two_copies_of_one_photo_each_get_a_sidecar_from_one_inference() {
    let f = Fixture::with_files(&["gradient.jpg"]);
    std::fs::write(f.dir.path().join("copy.jpg"), fixture("gradient.jpg")).unwrap();
    f.enqueue_all(&["gradient.jpg", "copy.jpg"]);
    let summary = f.run();

    assert_eq!(summary.processed, 2);
    assert_eq!(
        summary.cache_hits, 1,
        "the duplicate should have hit the content-hash-keyed embedding cache"
    );
    assert_eq!(f.tags("gradient.jpg"), f.tags("copy.jpg"));
}

#[test]
fn parallel_workers_produce_the_same_sidecars_as_one() {
    let serial = Fixture::new();
    serial.enqueue_all(PHOTOS);
    serial.run();

    let parallel = Fixture::new();
    parallel.enqueue_all(PHOTOS);
    parallel
        .engine
        .run_with_options(
            &NoProgress,
            &AtomicBool::new(false),
            &RunOptions {
                workers: Some(gallery_ml::MAX_WORKERS),
                limit: None,
                tagged_at: Some(TAGGED_AT.to_string()),
            },
        )
        .unwrap();

    for name in PHOTOS {
        assert_eq!(serial.sidecar_bytes(name), parallel.sidecar_bytes(name));
    }
}

#[test]
fn stats_track_the_queue_through_a_run() {
    let f = Fixture::with_files(&["gradient.jpg", "notes.txt", "broken.jpg"]);
    f.enqueue_all(&["gradient.jpg", "notes.txt", "broken.jpg"]);

    let before = f.engine.stats().unwrap();
    assert_eq!(before.pending, 3);
    assert_eq!(before.done, 0);

    f.run();
    let after = f.engine.stats().unwrap();
    assert_eq!(after.done, 1);
    assert_eq!(after.tagged, 1);
    assert_eq!(after.skipped, 1);
    // The broken JPEG has retries left, so it is still pending work, not a
    // permanent failure.
    assert_eq!(after.pending, 1);
    assert_eq!(after.failed, 0);
}

#[test]
fn enqueue_is_idempotent_across_calls() {
    let f = Fixture::new();
    assert_eq!(f.engine.enqueue(&f.paths(PHOTOS)).unwrap(), PHOTOS.len());
    assert_eq!(f.engine.enqueue(&f.paths(PHOTOS)).unwrap(), 0);
    assert_eq!(f.engine.stats().unwrap().pending as usize, PHOTOS.len());
}

#[test]
fn the_pack_loads_with_the_shape_the_manifest_advertises() {
    let pack = ModelPack::load(test_pack_dir()).unwrap();
    assert_eq!(pack.version(), "gallery-ml-testpack-1");
    assert_eq!(pack.manifest.model.embedding_dim, 64);
    assert_eq!(pack.manifest.model.input_size, 64);
    assert_eq!(pack.labels.len(), 6);
    assert!(pack.labels.iter().all(|l| l.embedding.len() == 64));
    // Rows arrive already unit-length; the loader normalizing them again must
    // be a no-op.
    for label in &pack.labels {
        let norm: f32 = label.embedding.iter().map(|v| v * v).sum();
        assert!((norm - 1.0).abs() < 1e-5, "{}: |v|^2 = {norm}", label.path);
    }
    assert_eq!(
        pack.embedding_model_key(),
        format!("gallery-ml-testpack-1#p{}", gallery_ml::PREPROCESS_VERSION)
    );
}

/// Prints every label's score on every fixture.
///
/// Not an assertion — this is the tool `make_test_pack.py` documents for
/// choosing `LABEL_THRESHOLDS`. Run it with
/// `cargo test -p gallery-ml --test engine_e2e -- --ignored --nocapture`.
#[test]
#[ignore = "diagnostic: prints scores used to choose the test pack's thresholds"]
fn print_fixture_scores() {
    use gallery_ml::encoder::{ImageEncoder, OrtEncoder};
    use gallery_ml::pack::normalize;
    use gallery_ml::preprocess::preprocess;

    let pack = ModelPack::load(test_pack_dir()).unwrap();
    let encoder = OrtEncoder::new(
        &pack.model_bytes,
        &pack.manifest.model.input_name,
        &pack.manifest.model.output_name,
        pack.manifest.model.input_size,
        pack.manifest.model.embedding_dim,
        1,
    )
    .unwrap();
    let cfg = pack.preprocess_config();

    for name in PHOTOS {
        let tensor = preprocess(name, &fixture(name), &cfg).unwrap();
        let embedding = normalize(&encoder.embed(&tensor).unwrap()).unwrap();
        println!("\n{name}");
        let mut scored: Vec<(f32, &str)> = pack
            .labels
            .iter()
            .map(|l| {
                let s: f32 = l.embedding.iter().zip(&embedding).map(|(a, b)| a * b).sum();
                (s, l.path.as_str())
            })
            .collect();
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        for (score, path) in scored {
            println!("  {score:+.4}  {path}");
        }
    }
}

#[test]
fn the_whole_pipeline_runs_against_an_in_memory_filesystem() {
    // Nothing in the engine may assume a real filesystem — Android SAF is the
    // reason the `Vfs` trait exists. `MemVfs` is the cheapest proof: if any
    // path in the pipeline reached for `std::fs`, the sidecars would land on
    // disk instead of in the map and this would fail.
    let vfs = Arc::new(gallery_vfs::MemVfs::new());
    for name in PHOTOS {
        vfs.write_atomic(&format!("/lib/{name}"), &fixture(name))
            .unwrap();
    }
    // The cache DB is SQLite and needs a real file; only *photo* IO goes
    // through the Vfs.
    let cache_dir = tempfile::tempdir().unwrap();
    let engine = TaggingEngine::open(
        cache_dir.path().join("c.sqlite"),
        test_pack_dir(),
        Arc::clone(&vfs) as Arc<dyn Vfs>,
    )
    .unwrap();

    let paths: Vec<String> = PHOTOS.iter().map(|n| format!("/lib/{n}")).collect();
    engine.enqueue(&paths).unwrap();
    let summary = engine
        .run_with_options(
            &NoProgress,
            &AtomicBool::new(false),
            &RunOptions {
                workers: Some(2),
                limit: None,
                tagged_at: Some(TAGGED_AT.to_string()),
            },
        )
        .unwrap();

    assert_eq!(summary.failed, 0);
    assert_eq!(summary.sidecars_written, PHOTOS.len());
    for name in PHOTOS {
        let bytes = vfs.read(&format!("/lib/{name}.xmp")).unwrap();
        let view = gallery_meta::read_view(&bytes).unwrap();
        assert_eq!(view.core.tags, expected_tags()[name], "{name}");
    }
}

/// Rough throughput on camera-sized JPEGs.
///
/// Ignored because it takes seconds and its numbers are machine-specific. Run
/// with `cargo test --release -p gallery-ml --test engine_e2e -- --ignored
/// --nocapture perf`. The test pack's encoder is trivial, so what this
/// actually measures is decode + resize + hash + SQLite + sidecar write —
/// which is the part a real pack does *not* change, and the part that decides
/// whether "Tag now" over 20k photos is tolerable.
#[test]
#[ignore = "perf probe: slow, machine-specific"]
fn perf_probe_on_camera_sized_jpegs() {
    use std::time::Instant;

    const N: usize = 12;
    const W: u32 = 4032;
    const H: u32 = 3024;

    let dir = tempfile::tempdir().unwrap();
    for i in 0..N {
        // Detail matters: a smooth synthetic gradient compresses to ~200 KB
        // and decodes far faster than a real 12 MP photo. The hashed noise
        // term pushes the entropy (and the file size) into the multi-megabyte
        // range a camera actually produces, so the decode cost is honest.
        let img = image::RgbImage::from_fn(W, H, |x, y| {
            let n = (x.wrapping_mul(2_654_435_761) ^ y.wrapping_mul(2_246_822_519) ^ i as u32)
                .rotate_left(7);
            image::Rgb([
                (((x / 8 + i as u32) % 256) as u8).wrapping_add((n & 0x3F) as u8),
                (((y / 8) % 256) as u8).wrapping_add(((n >> 8) & 0x3F) as u8),
                ((((x + y) / 16) % 256) as u8).wrapping_add(((n >> 16) & 0x3F) as u8),
            ])
        });
        image::DynamicImage::ImageRgb8(img)
            .save_with_format(
                dir.path().join(format!("p{i}.jpg")),
                image::ImageFormat::Jpeg,
            )
            .unwrap();
    }
    let bytes: u64 = (0..N)
        .map(|i| {
            std::fs::metadata(dir.path().join(format!("p{i}.jpg")))
                .unwrap()
                .len()
        })
        .sum();
    let paths: Vec<String> = (0..N)
        .map(|i| {
            dir.path()
                .join(format!("p{i}.jpg"))
                .to_string_lossy()
                .into_owned()
        })
        .collect();

    let engine = TaggingEngine::open(
        dir.path().join("c.sqlite"),
        test_pack_dir(),
        Arc::new(StdVfs),
    )
    .unwrap();
    engine.enqueue(&paths).unwrap();

    let t0 = Instant::now();
    let cold = engine.run(&NoProgress, &AtomicBool::new(false)).unwrap();
    let cold_secs = t0.elapsed().as_secs_f64();

    engine.reset_queue().unwrap();
    engine.enqueue(&paths).unwrap();
    let t1 = Instant::now();
    let warm = engine.run(&NoProgress, &AtomicBool::new(false)).unwrap();
    let warm_secs = t1.elapsed().as_secs_f64();

    println!(
        "\n{W}x{H} JPEG x{N} ({:.1} MB avg), {} workers\n  cold: {:.2}s  {:.1} photos/s  (cache_hits {})\n  warm: {:.2}s  {:.1} photos/s  (cache_hits {}, sidecars_written {})",
        bytes as f64 / N as f64 / 1_048_576.0,
        gallery_ml::engine::default_workers(None),
        cold_secs,
        N as f64 / cold_secs,
        cold.cache_hits,
        warm_secs,
        N as f64 / warm_secs,
        warm.cache_hits,
        warm.sidecars_written,
    );
    assert_eq!(cold.failed, 0);
    assert_eq!(warm.cache_hits, N);
}

/// The `Vfs` seam is honoured: no `std::fs` in the engine's own paths.
#[test]
fn the_engine_reads_and_writes_only_through_the_vfs() {
    /// Counts calls, then delegates.
    struct CountingVfs {
        inner: StdVfs,
        writes: AtomicUsize,
        reads: AtomicUsize,
    }
    impl Vfs for CountingVfs {
        fn open(
            &self,
            path: &str,
        ) -> gallery_vfs::VfsResult<Box<dyn gallery_vfs::ReadSeek + Send>> {
            self.reads.fetch_add(1, Ordering::SeqCst);
            self.inner.open(path)
        }
        fn stat(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Stat> {
            self.inner.stat(path)
        }
        fn write_atomic(&self, path: &str, bytes: &[u8]) -> gallery_vfs::VfsResult<()> {
            self.writes.fetch_add(1, Ordering::SeqCst);
            self.inner.write_atomic(path, bytes)
        }
        fn exists(&self, path: &str) -> bool {
            self.inner.exists(path)
        }
    }

    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("gradient.jpg"), fixture("gradient.jpg")).unwrap();
    let vfs = Arc::new(CountingVfs {
        inner: StdVfs,
        writes: AtomicUsize::new(0),
        reads: AtomicUsize::new(0),
    });
    let engine = TaggingEngine::open(
        dir.path().join("c.sqlite"),
        test_pack_dir(),
        Arc::clone(&vfs) as Arc<dyn Vfs>,
    )
    .unwrap();
    engine
        .enqueue(&[dir
            .path()
            .join("gradient.jpg")
            .to_string_lossy()
            .into_owned()])
        .unwrap();
    engine.run(&NoProgress, &AtomicBool::new(false)).unwrap();

    assert_eq!(
        vfs.writes.load(Ordering::SeqCst),
        1,
        "the sidecar write did not go through the Vfs"
    );
    assert!(vfs.reads.load(Ordering::SeqCst) >= 1);
    assert!(dir.path().join("gradient.jpg.xmp").exists());
}
