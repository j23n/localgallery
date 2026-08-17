//! [`FaceEngine`] — the face pipeline's orchestrator.
//!
//! A sibling of [`crate::TaggingEngine`], not an extension of it. The two share
//! a cache file, a `Vfs`, a model pack and every convention below; they do not
//! share a queue, a lifecycle or a run. Three reasons, in decreasing order of
//! how much they would have hurt:
//!
//! 1. **Independent resumability.** A user who imports 5 000 photos wants
//!    tagging to finish and faces to keep going, or the reverse. One queue
//!    would make "done" mean "both done", and a face-model swap would re-tag
//!    the library.
//! 2. **A tagging-only pack must keep working.** Faces are optional in the
//!    manifest; a single engine would have to carry an `Option` through every
//!    method and answer "what does `run` do when half the models are absent".
//! 3. **Different shape.** Tagging is one embedding per photo; faces are *n*
//!    detections per photo, each with its own alignment, embedding and cluster
//!    membership, plus a serial pass afterwards that tagging has no analogue
//!    for.
//!
//! # Per-photo pipeline
//!
//! ```text
//! extension check ──unsupported──▶ skipped
//!        │
//!  content hash (streamed)
//!        │
//!  face_scans[(hash, face pack key)] ──hit──▶ reuse, no decode, no inference
//!        │ miss
//!  read bytes → decode → orient  (once)
//!        │
//!  detector (letterbox 640) ──▶ boxes + landmarks + scores
//!        │
//!  for each face: quality → align 112×112 → embed → L2-normalize
//!        │
//!  put_faces (one transaction)
//!        │
//!  face_work → done
//! ```
//!
//! Clustering is deliberately **not** in that loop. It runs once, serially,
//! after every worker has finished — see [`FaceEngine::assign_new_faces`].
//!
//! # Parallelism and cancellation
//!
//! Identical to the tagging engine: a scoped pool over an atomic cursor,
//! `available_parallelism().min(4)`, panics caught so a bad model cannot unwind
//! through the FFI's run thread, cancellation checked between photos and inside
//! the streamed hash, in-flight rows released rather than failed, and
//! [`FaceProgress::on_finished`] fired exactly once on every path including the
//! ones that return `Err` before a worker starts.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use gallery_vfs::Vfs;

use crate::cache::{CacheDb, ClusterRow, ClusterState, Stats, StoredFace, WorkItem};
use crate::encoder::ImageEncoder;
use crate::engine::{default_workers, PROGRESS_INTERVAL, TAGGED_BATCH};
use crate::error::{MlError, MlResult};
use crate::hash::content_hash;
use crate::pack::{ClusteringConfig, ModelPack};
use crate::preprocess::{decode_oriented, extension_supported};

use super::align::align_tensor;
use super::cluster::{self, Assignment, FaceVec};
use super::detect::FaceDetector;
use super::quality::quality;

/// Callbacks into the host app.
///
/// `Send + Sync` because workers call it directly. Implementations must be
/// cheap and must not block.
pub trait FaceProgress: Send + Sync {
    /// Throttled to at most one call per [`crate::engine::PROGRESS_INTERVAL`],
    /// plus one final call at the end of the run.
    fn on_progress(&self, done: usize, total: usize);

    /// Paths that turned out to contain at least one face, batched.
    ///
    /// Only photos whose detections *changed* appear: a cache hit re-reports
    /// nothing, so the app's downstream refresh is not woken for a no-op.
    fn on_photos_with_faces(&self, paths: &[String]);

    /// Photos whose sidecar the auto-tag pass rewrote, once, at the end of the
    /// run.
    ///
    /// Separate from [`FaceProgress::on_photos_with_faces`] because they answer
    /// different questions: that one means "the cache changed", this one means
    /// "a file on disk changed", and only the second obliges the app to re-read
    /// sidecars. Defaulted to nothing so a listener that does not care about
    /// disk writes need not implement it.
    fn on_sidecars_written(&self, _paths: &[String]) {}

    /// Called exactly once, whether the run finished or was cancelled.
    fn on_finished(&self, summary: &FaceRunSummary);
}

/// A [`FaceProgress`] that does nothing.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoFaceProgress;

impl FaceProgress for NoFaceProgress {
    fn on_progress(&self, _done: usize, _total: usize) {}
    fn on_photos_with_faces(&self, _paths: &[String]) {}
    fn on_finished(&self, _summary: &FaceRunSummary) {}
}

/// What one [`FaceEngine::run`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FaceRunSummary {
    /// Photos taken off the queue and carried to a terminal state.
    pub processed: usize,
    /// Photos that contain at least one face.
    pub photos_with_faces: usize,
    /// Faces detected and embedded across the run.
    pub faces_found: usize,
    /// Photos whose detections came from the cache — no decode, no inference.
    pub cache_hits: usize,
    /// Photos skipped as an unsupported format.
    pub skipped: usize,
    /// Photos that failed.
    pub failed: usize,
    /// Faces the post-run pass placed into a cluster.
    pub faces_assigned: usize,
    /// Clusters that pass created.
    pub clusters_created: usize,
    /// Faces that joined an already-**named** cluster and cleared the quality
    /// floor, so their photo's sidecar was written without anybody asking.
    pub faces_auto_tagged: usize,
    /// Sidecars the auto-tag pass actually rewrote. Lower than
    /// [`Self::faces_auto_tagged`] whenever a photo already said the right
    /// thing, or held several newly-matched faces.
    pub sidecars_written: usize,
    /// Sidecars the auto-tag pass could not write.
    pub sidecars_failed: usize,
    /// Whether the run stopped early because `cancel` was set.
    pub cancelled: bool,
}

/// What one [`FaceEngine::recluster`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ReclusterSummary {
    /// Unlabeled clusters that existed before the pass.
    pub clusters_before: usize,
    /// Unlabeled clusters after it.
    pub clusters_after: usize,
    /// Faces the pass re-partitioned.
    pub faces: usize,
    /// Merge proposals standing afterwards.
    pub proposals: usize,
}

/// Knobs for one run.
#[derive(Debug, Clone, Default)]
pub struct FaceRunOptions {
    /// Worker threads; clamped to `1..=`[`crate::MAX_WORKERS`]. `None` uses
    /// `available_parallelism()`.
    pub workers: Option<usize>,
    /// Process at most this many photos. `None` means everything claimable.
    pub limit: Option<usize>,
    /// Only process queue rows under this directory. See
    /// [`crate::RunOptions::root_prefix`] — same rule, same reason.
    pub root_prefix: Option<String>,
    /// Run the full re-cluster pass at the end of the run.
    ///
    /// Off by default: it is *O(n²)* in the unlabeled face count, and the
    /// incremental pass already produced a usable partition. The app is
    /// expected to trigger it after a large ingest, which is exactly when
    /// arrival-order artefacts have had a chance to accumulate.
    pub full_recluster: bool,
    /// ISO 8601 UTC stamp for any sidecar the auto-tag pass writes. `None`
    /// reads the system clock.
    ///
    /// Caller-supplied for the same reason
    /// [`gallery_meta::FaceWriteRequest::tagged_at`] is: a test that wants
    /// byte-reproducible sidecars cannot have a clock in the middle of the
    /// pipeline.
    pub tagged_at: Option<String>,
    /// Skip the auto-tag pass entirely.
    ///
    /// It writes to files nobody asked about in this run, so there has to be a
    /// way to turn it off — a caller running faces purely to populate the
    /// review UI may not want disk writes at all.
    pub skip_auto_tagging: bool,
}

/// The face orchestrator.
pub struct FaceEngine {
    cache: Arc<CacheDb>,
    pack: Arc<ModelPack>,
    detector: Arc<FaceDetector>,
    embedder: Arc<dyn ImageEncoder>,
    vfs: Arc<dyn Vfs>,
    face_key: String,
    clustering: ClusteringConfig,
}

impl std::fmt::Debug for FaceEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FaceEngine")
            .field("pack", &self.pack.manifest.pack_version)
            .field("face_key", &self.face_key)
            .field("backend", &self.embedder.backend_name())
            .finish()
    }
}

impl FaceEngine {
    /// Open the cache, load and verify the pack's face models, and build both
    /// inference sessions.
    ///
    /// Returns [`MlError::FaceModelsUnavailable`] for a pack that ships no face
    /// models — which is a supported pack, not a broken one.
    #[cfg(feature = "ort-backend")]
    pub fn open(
        cache_db_path: impl AsRef<std::path::Path>,
        model_pack_dir: impl AsRef<std::path::Path>,
        vfs: Arc<dyn Vfs>,
    ) -> MlResult<FaceEngine> {
        let pack = ModelPack::load(model_pack_dir)?;
        FaceEngine::open_with_pack(CacheDb::open(cache_db_path)?, pack, vfs)
    }

    /// [`FaceEngine::open`] against an already-loaded pack and cache.
    #[cfg(feature = "ort-backend")]
    pub fn open_with_pack(
        cache: CacheDb,
        pack: ModelPack,
        vfs: Arc<dyn Vfs>,
    ) -> MlResult<FaceEngine> {
        let faces = pack.faces().ok_or(MlError::FaceModelsUnavailable)?.clone();
        let bytes = pack.load_face_models()?;
        let slots = default_workers(None);
        let detector = crate::encoder::OrtModel::new(&bytes.detector, slots)?;
        let embedder = crate::encoder::OrtEncoder::new(
            &bytes.embedder,
            &faces.embedder.input_name,
            &faces.embedder.output_name,
            faces.embedder.input_size,
            faces.embedder.embedding_dim,
            slots,
        )?;
        FaceEngine::with_models(cache, pack, Arc::new(detector), Arc::new(embedder), vfs)
    }

    /// Assemble an engine from parts.
    ///
    /// Stales every `done` face row produced under different face models, and
    /// — if the models changed since the cache was last written — throws away
    /// the faces and clusters themselves, because they live in an embedding
    /// space that no longer exists.
    pub fn with_models(
        cache: CacheDb,
        pack: ModelPack,
        detector_model: Arc<dyn crate::encoder::MultiOutputModel>,
        embedder: Arc<dyn ImageEncoder>,
        vfs: Arc<dyn Vfs>,
    ) -> MlResult<FaceEngine> {
        let faces = pack.faces().ok_or(MlError::FaceModelsUnavailable)?.clone();
        if embedder.input_size() != faces.embedder.input_size {
            return Err(MlError::PackInvalid {
                detail: format!(
                    "face embedder input size {} != manifest {}",
                    embedder.input_size(),
                    faces.embedder.input_size
                ),
            });
        }
        if embedder.embedding_dim() != faces.embedder.embedding_dim {
            return Err(MlError::PackInvalid {
                detail: format!(
                    "face embedder dim {} != manifest {}",
                    embedder.embedding_dim(),
                    faces.embedder.embedding_dim
                ),
            });
        }
        let face_key = pack.face_pack_key().ok_or(MlError::FaceModelsUnavailable)?;

        if cache.meta(crate::cache::META_FACE_PACK)?.as_deref() != Some(face_key.as_str()) {
            // A first open records the key and finds nothing to clear; a model
            // swap clears everything derived from the old one.
            cache.reset_face_results()?;
            cache.set_meta(crate::cache::META_FACE_PACK, &face_key)?;
        }
        cache.face_mark_stale_for_pack(&face_key)?;

        Ok(FaceEngine {
            cache: Arc::new(cache),
            pack: Arc::new(pack),
            detector: Arc::new(FaceDetector::new(detector_model, faces.detector)),
            embedder,
            vfs,
            face_key,
            clustering: faces.clustering,
        })
    }

    /// The loaded pack.
    pub fn pack(&self) -> &ModelPack {
        &self.pack
    }

    /// The identity face results are recorded under.
    pub fn face_pack_key(&self) -> &str {
        &self.face_key
    }

    /// The clustering thresholds in force.
    pub fn clustering(&self) -> &ClusteringConfig {
        &self.clustering
    }

    /// Face queue counts.
    pub fn stats(&self) -> MlResult<Stats> {
        self.cache.face_stats()
    }

    /// Face table counts.
    pub fn library_stats(&self) -> MlResult<crate::cache::FaceLibraryStats> {
        self.cache.face_library_stats()
    }

    /// Add paths to the face queue. Idempotent.
    pub fn enqueue(&self, paths: &[String]) -> MlResult<usize> {
        self.cache.face_enqueue(paths)
    }

    /// Forget every face queue row, keeping detections and clusters.
    pub fn reset_queue(&self) -> MlResult<()> {
        self.cache.face_reset_queue()
    }

    /// Throw away every detection, cluster and proposal. The queue survives, so
    /// the next run rebuilds them.
    pub fn reset_results(&self) -> MlResult<()> {
        self.cache.reset_face_results()
    }

    /// Every cluster, in id order.
    pub fn clusters(&self) -> MlResult<Vec<ClusterRow>> {
        self.cache.clusters()
    }

    /// The faces of one cluster.
    pub fn cluster_faces(&self, id: i64) -> MlResult<Vec<StoredFace>> {
        let mut out = Vec::new();
        for (hash, idx) in self.cache.cluster_members(id)? {
            if let Some(face) = self
                .cache
                .faces_for_hash(&hash)?
                .into_iter()
                .find(|f| f.face_idx == idx)
            {
                out.push(face);
            }
        }
        Ok(out)
    }

    /// Outstanding merge proposals, strongest first.
    pub fn merge_proposals(&self) -> MlResult<Vec<(i64, i64, f32)>> {
        self.cache.merge_proposals()
    }

    /// The cache this engine writes to. The FFI layer needs it to answer
    /// cluster queries without going through a run.
    pub fn cache(&self) -> &CacheDb {
        &self.cache
    }

    /// The filesystem this engine reads photos and writes sidecars through.
    pub fn vfs(&self) -> &dyn Vfs {
        self.vfs.as_ref()
    }

    /// Process the queue with default options.
    pub fn run(
        &self,
        progress: &dyn FaceProgress,
        cancel: &AtomicBool,
    ) -> MlResult<FaceRunSummary> {
        self.run_with_options(progress, cancel, &FaceRunOptions::default())
    }

    /// [`FaceEngine::run`] with explicit knobs.
    ///
    /// [`FaceProgress::on_finished`] fires exactly once on every path.
    pub fn run_with_options(
        &self,
        progress: &dyn FaceProgress,
        cancel: &AtomicBool,
        opts: &FaceRunOptions,
    ) -> MlResult<FaceRunSummary> {
        let mut partial = FaceRunSummary::default();
        let result = self.run_inner(progress, cancel, opts, &mut partial);
        let summary = match &result {
            Ok(s) => *s,
            Err(_) => partial,
        };
        progress.on_finished(&summary);
        result
    }

    fn run_inner(
        &self,
        progress: &dyn FaceProgress,
        cancel: &AtomicBool,
        opts: &FaceRunOptions,
        partial: &mut FaceRunSummary,
    ) -> MlResult<FaceRunSummary> {
        // Between-runs housekeeping, mirroring the tagging engine's.
        self.cache.face_reclaim_abandoned()?;
        self.cache
            .face_reopen_skipped_for_decoder(crate::preprocess::DECODER_VERSION)?;
        self.restat_done_rows()?;

        let root_prefix = opts.root_prefix.as_deref().map(normalize_root_prefix);
        let items = self
            .cache
            .face_claimable(opts.limit.unwrap_or(0), root_prefix.as_deref())?;
        let total = items.len();
        let workers = default_workers(opts.workers).min(total.max(1));

        let cursor = AtomicUsize::new(0);
        let shared = Shared {
            done: AtomicUsize::new(0),
            totals: Mutex::new(FaceRunSummary::default()),
            reporter: Mutex::new(Reporter::new()),
        };

        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            std::thread::scope(|scope| {
                for _ in 0..workers {
                    scope.spawn(|| loop {
                        if cancel.load(Ordering::Relaxed) {
                            break;
                        }
                        let i = cursor.fetch_add(1, Ordering::Relaxed);
                        let Some(item) = items.get(i) else { break };

                        let outcome = self.process(item, cancel);
                        if !shared.absorb(item, outcome) {
                            continue;
                        }
                        let done = shared.done.fetch_add(1, Ordering::Relaxed) + 1;
                        shared.report(progress, done, total, false);
                    });
                }
            });
        }))
        .is_err();

        let mut summary = shared.take_totals();
        summary.cancelled = cancel.load(Ordering::Relaxed);
        shared.flush(progress, shared.done.load(Ordering::Relaxed), total);

        if panicked {
            *partial = summary;
            return Err(MlError::Inference {
                detail: "a face worker panicked".into(),
            });
        }

        // Clustering is single-threaded and runs after the workers, never
        // inside them. Two reasons, both load-bearing: an incremental
        // assignment reads the cluster set it is also mutating, and its result
        // depends on the order faces arrive in — which under four workers is
        // whatever the scheduler felt like. Doing it here, over
        // `unassigned_faces()`'s fixed `(content_hash, face_idx)` order, makes
        // a run's partition a function of its inputs.
        //
        // A cancelled run still assigns what it detected: those faces are in
        // the database either way, and leaving them unclustered would show the
        // user a library with faces and no people in it.
        let assignment = self.assign_new_faces()?;
        let (created, assigned) = (assignment.created, assignment.assigned);
        summary.clusters_created = created;
        summary.faces_assigned = assigned;
        summary.faces_auto_tagged = assignment.faces_auto_tagged;

        // Auto-tagging comes before the (expensive, advisory) proposal refresh
        // so that a cancelled-at-the-last-moment run has still published what
        // it recognised. It runs even for a cancelled run for the same reason
        // the assignment does: the faces are in the database either way, and
        // the sidecar is the only place a match becomes visible to the app.
        if !opts.skip_auto_tagging && !assignment.auto_hashes.is_empty() {
            // The run's own root scope carries into the writes it triggers:
            // the queue can hold rows from a root the app has left, and an
            // auto-tag must not reach outside the folder the run stayed inside.
            // Nothing is retracted — this pass names people, it does not know
            // that anybody has stopped being in a photo.
            let scope = super::naming::SyncScope {
                root_prefix: root_prefix.clone(),
                retracting: Vec::new(),
            };
            let plan =
                self.sync_sidecars(&assignment.auto_hashes, opts.tagged_at.as_deref(), &scope)?;
            summary.sidecars_written = plan.written.len();
            summary.sidecars_failed = plan.failed.len();
            if !plan.written.is_empty() {
                progress.on_sidecars_written(&plan.written);
            }
        }

        if opts.full_recluster && !summary.cancelled {
            self.recluster()?;
        } else if created > 0 || assigned > 0 {
            // Only when the centroids actually moved. Proposals are an
            // all-pairs cosine over the cluster set, which is the one thing in
            // this function that is quadratic in the size of the library — a
            // run that found nothing new must not pay for it.
            self.refresh_merge_proposals()?;
        }

        *partial = summary;
        Ok(summary)
    }

    /// Demote `done` rows whose file no longer matches the stat they were
    /// detected against. See [`crate::TaggingEngine`]'s equivalent.
    fn restat_done_rows(&self) -> MlResult<()> {
        for row in self.cache.face_done_rows_with_stat()? {
            let Ok(stat) = self.vfs.stat(&row.path) else {
                continue;
            };
            if stat.size != row.size || stat.modified_unix != row.modified_unix {
                self.cache.face_mark_stale(&row.path)?;
            }
        }
        Ok(())
    }

    /// One photo, start to finish. Never panics; every failure becomes an
    /// [`Outcome`].
    fn process(&self, item: &WorkItem, cancel: &AtomicBool) -> Outcome {
        match self.cache.face_begin(&item.path) {
            Ok(true) => {}
            Ok(false) => return Outcome::Lost,
            Err(_) => return Outcome::Failed,
        }
        if !extension_supported(&item.path) {
            let _ = self
                .cache
                .face_finish_skipped(&item.path, crate::preprocess::DECODER_VERSION);
            return Outcome::Skipped;
        }
        match self.process_inner(item, cancel) {
            Ok(Some(result)) => {
                let stat = self
                    .vfs
                    .stat(&item.path)
                    .ok()
                    .map(|s| (s.size, s.modified_unix));
                match self.cache.face_finish_done(
                    &item.path,
                    &self.face_key,
                    result.face_count,
                    stat,
                ) {
                    Ok(true) => Outcome::Done(result),
                    Ok(false) => Outcome::Lost,
                    Err(_) => Outcome::Failed,
                }
            }
            Ok(None) => {
                let _ = self.cache.face_release(&item.path);
                Outcome::Cancelled
            }
            Err(e) => {
                let _ = self.cache.face_finish_failed(&item.path, e.error_code());
                Outcome::Failed
            }
        }
    }

    /// `Ok(None)` means "cancelled mid-photo".
    fn process_inner(&self, item: &WorkItem, cancel: &AtomicBool) -> MlResult<Option<PhotoFaces>> {
        let cancelled = || cancel.load(Ordering::Relaxed);
        let path = item.path.as_str();

        // Same two-hash discipline as the tagging engine: the streamed hash is
        // a probe key only, and the embedding is filed under the hash of the
        // buffer that was actually decoded.
        let Some(probe) = content_hash(self.vfs.as_ref(), path, &cancelled)? else {
            return Ok(None);
        };

        let (face_count, hash, cache_hit) = match self.cache.face_scan(&probe, &self.face_key)? {
            Some((count, _, _)) => (count, probe, true),
            None => {
                if cancelled() {
                    return Ok(None);
                }
                let bytes = self.vfs.read(path)?;
                let hash = crate::hash::hash_bytes(&bytes);
                let rgb = decode_oriented(path, &bytes)?;
                // The encoded bytes are dead once the pixels exist, and at
                // four workers a 30 MB JPEG held across inference is
                // 120 MB of avoidable resident memory.
                drop(bytes);
                if cancelled() {
                    return Ok(None);
                }
                let faces = self.detect_and_embed(path, &rgb, &hash, cancel)?;
                let Some(faces) = faces else {
                    return Ok(None);
                };
                self.cache
                    .put_faces(&hash, &self.face_key, rgb.width(), rgb.height(), &faces)?;
                (faces.len(), hash, false)
            }
        };

        if !self.cache.face_set_content_hash(path, &hash)? {
            return Ok(None);
        }
        Ok(Some(PhotoFaces {
            face_count,
            cache_hit,
        }))
    }

    /// Detect, align and embed every face in one decoded image.
    fn detect_and_embed(
        &self,
        path: &str,
        rgb: &image::RgbImage,
        hash: &[u8; 32],
        cancel: &AtomicBool,
    ) -> MlResult<Option<Vec<StoredFace>>> {
        let detections = self.detector.detect(path, rgb)?;
        let embedder_spec = &self
            .pack
            .faces()
            .ok_or(MlError::FaceModelsUnavailable)?
            .embedder;

        let mut out = Vec::with_capacity(detections.len());
        for (idx, detection) in detections.iter().enumerate() {
            // A group photo can hold dozens of faces and each one is a full
            // inference, so cancellation is checked per face, not per photo.
            if cancel.load(Ordering::Relaxed) {
                return Ok(None);
            }
            let tensor = align_tensor(
                rgb,
                &detection.landmarks,
                embedder_spec.input_size,
                &embedder_spec.mean,
                &embedder_spec.std,
            )?;
            let raw = self.embedder.embed(&tensor)?;
            // A face whose embedding has no direction cannot be compared with
            // anything; dropping it beats storing a vector that every cosine
            // reads as -1.
            let Some(embedding) = crate::pack::normalize(&raw) else {
                continue;
            };
            out.push(StoredFace {
                content_hash: *hash,
                face_idx: idx as u32,
                bbox: detection.bbox,
                landmarks: detection.landmarks,
                score: detection.score,
                quality: quality(detection, rgb.width(), rgb.height()),
                embedding,
                image_w: rgb.width(),
                image_h: rgb.height(),
            });
        }
        Ok(Some(out))
    }

    /// Place every face that no cluster claims, in a fixed order.
    fn assign_new_faces(&self) -> MlResult<AssignOutcome> {
        let mut outcome = AssignOutcome::default();
        let pending = self.cache.unassigned_faces()?;
        if pending.is_empty() {
            return Ok(outcome);
        }
        let mut clusters = self.cache.clusters()?;
        let mut sums: std::collections::BTreeMap<i64, RunningSum> =
            std::collections::BTreeMap::new();

        for face in pending {
            match cluster::assign(&face.embedding, &clusters, &self.clustering) {
                Assignment::Join(id) => {
                    // A join into a *named* cluster is an auto-tag candidate:
                    // `assign` already held it to `ClusteringConfig::auto`, the
                    // higher of the two bars, precisely because this branch
                    // ends in a write to somebody's photo. The quality floor is
                    // the second gate — a blurry profile that happens to land
                    // near a centroid stays in the cache, where a wrong guess
                    // costs a click rather than a file.
                    if clusters
                        .iter()
                        .any(|c| c.id == id && c.state == ClusterState::Named)
                        && face.quality >= self.clustering.min_quality
                    {
                        outcome.auto_hashes.push(face.content_hash);
                        outcome.faces_auto_tagged += 1;
                    }
                    // Seed the running sum from what is on disk **before** this
                    // face joins. Reading it afterwards would count the new face
                    // once from the database and once from `add`, and pull every
                    // cluster's centroid toward whichever face happened to join
                    // it first in a run.
                    // `Entry::Vacant` rather than `or_insert_with`: loading the
                    // members is fallible, and a closure cannot carry the `?`.
                    if let std::collections::btree_map::Entry::Vacant(slot) = sums.entry(id) {
                        let members = self.cache.cluster_member_embeddings(id)?;
                        slot.insert(RunningSum::from_members(&members, face.embedding.len()));
                    }
                    self.cache
                        .set_cluster_member(id, &face.content_hash, face.face_idx)?;
                    let entry = sums.get_mut(&id).expect("inserted above");
                    entry.add(&face.embedding);
                    if let Some(centroid) = entry.centroid() {
                        let size = entry.count as u32;
                        self.cache.set_cluster_centroid(id, &centroid, size)?;
                        if let Some(row) = clusters.iter_mut().find(|c| c.id == id) {
                            row.centroid = centroid;
                            row.size = size;
                        }
                    }
                    outcome.assigned += 1;
                }
                Assignment::Seed => {
                    let id = self.cache.create_cluster(&face.embedding)?;
                    self.cache
                        .set_cluster_member(id, &face.content_hash, face.face_idx)?;
                    self.cache.set_cluster_centroid(id, &face.embedding, 1)?;
                    let mut sum = RunningSum::new(face.embedding.len());
                    sum.add(&face.embedding);
                    sums.insert(id, sum);
                    clusters.push(ClusterRow {
                        id,
                        centroid: face.embedding.clone(),
                        size: 1,
                        state: ClusterState::Unlabeled,
                        person_name: None,
                        pinned: false,
                    });
                    outcome.created += 1;
                    outcome.assigned += 1;
                }
            }
        }
        outcome.auto_hashes.sort_unstable();
        outcome.auto_hashes.dedup();
        Ok(outcome)
    }

    /// Rebuild the partition of every unlabeled face from scratch.
    ///
    /// Named, ignored and **pinned** clusters are untouched — their members are
    /// not even in the input. Pinned means the user merged or split it by hand,
    /// and a pass that re-partitioned those faces would silently undo work
    /// somebody did deliberately. Other unlabeled cluster **ids are not stable
    /// across this call**: the pass produces a partition, not a diff, and there
    /// is no meaningful identity to carry over for a group nobody has named.
    /// Named cluster ids are stable forever, which is the only stability the UI
    /// actually needs.
    pub fn recluster(&self) -> MlResult<ReclusterSummary> {
        let faces = self.cache.unlabeled_faces()?;
        let before = self
            .cache
            .clusters()?
            .into_iter()
            .filter(|c| c.state == ClusterState::Unlabeled && !c.pinned)
            .map(|c| c.id)
            .collect::<Vec<_>>();

        let input: Vec<FaceVec> = faces
            .iter()
            .map(|f| FaceVec {
                content_hash: f.content_hash,
                face_idx: f.face_idx,
                embedding: f.embedding.clone(),
            })
            .collect();
        let groups = cluster::chinese_whispers(&input, &self.clustering);

        self.cache.delete_clusters(&before)?;
        let by_key: std::collections::BTreeMap<([u8; 32], u32), &StoredFace> = faces
            .iter()
            .map(|f| ((f.content_hash, f.face_idx), f))
            .collect();
        for group in &groups {
            let vectors: Vec<&[f32]> = group
                .iter()
                .filter_map(|k| by_key.get(k).map(|f| f.embedding.as_slice()))
                .collect();
            let Some(centroid) = cluster::centroid(vectors) else {
                continue;
            };
            let id = self.cache.create_cluster(&centroid)?;
            for (hash, idx) in group {
                self.cache.set_cluster_member(id, hash, *idx)?;
            }
            self.cache
                .set_cluster_centroid(id, &centroid, group.len() as u32)?;
        }

        let proposals = self.refresh_merge_proposals()?;
        Ok(ReclusterSummary {
            clusters_before: before.len(),
            clusters_after: groups.len(),
            faces: faces.len(),
            proposals,
        })
    }

    /// Recompute the merge proposals from the current centroids.
    ///
    /// Proposals are advisory and cheap to regenerate, so they are rebuilt
    /// wholesale rather than diffed: a stale proposal naming a cluster that
    /// changed shape is worse than no proposal.
    fn refresh_merge_proposals(&self) -> MlResult<usize> {
        let clusters = self.cache.clusters()?;
        let proposals = cluster::merge_proposals(&clusters, &self.clustering);
        self.cache.clear_merge_proposals()?;
        for (a, b, sim) in &proposals {
            self.cache.put_merge_proposal(*a, *b, *sim)?;
        }
        Ok(proposals.len())
    }
}

/// What [`FaceEngine::assign_new_faces`] did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct AssignOutcome {
    created: usize,
    assigned: usize,
    faces_auto_tagged: usize,
    /// Content hashes whose photos the auto-tag pass should write, sorted and
    /// deduplicated so a photo with three newly-matched faces is one write.
    auto_hashes: Vec<[u8; 32]>,
}

/// A cluster's unnormalized member sum plus its member count.
///
/// The incremental pass needs the *mean* of a cluster's embeddings, and a
/// stored centroid cannot supply it: the centroid is unit length, so the
/// magnitude that would let a new member be folded in with the right weight has
/// already been thrown away. Adding a face to a normalized centroid would give
/// it the weight of the entire cluster.
#[derive(Debug, Clone, PartialEq)]
struct RunningSum {
    sum: Vec<f64>,
    count: usize,
}

impl RunningSum {
    fn new(dim: usize) -> RunningSum {
        RunningSum {
            sum: vec![0.0; dim],
            count: 0,
        }
    }

    /// Sum `members`, ignoring any whose dimension disagrees — a corrupt or
    /// stale row must not poison a centroid.
    fn from_members(members: &[Vec<f32>], dim: usize) -> RunningSum {
        let mut out = RunningSum::new(dim);
        for m in members {
            out.add(m);
        }
        out
    }

    fn add(&mut self, v: &[f32]) {
        if v.len() != self.sum.len() {
            return;
        }
        for (acc, x) in self.sum.iter_mut().zip(v) {
            *acc += f64::from(*x);
        }
        self.count += 1;
    }

    /// The L2-normalized mean, or `None` when the members cancel out.
    fn centroid(&self) -> Option<Vec<f32>> {
        normalize_sum(&self.sum)
    }
}

fn normalize_sum(sum: &[f64]) -> Option<Vec<f32>> {
    let norm = sum.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm.is_nan() || norm <= f64::EPSILON {
        return None;
    }
    Some(sum.iter().map(|x| (x / norm) as f32).collect())
}

struct PhotoFaces {
    face_count: usize,
    cache_hit: bool,
}

enum Outcome {
    Done(PhotoFaces),
    Skipped,
    Failed,
    Cancelled,
    /// The row was taken from under this worker (a queue reset mid-run).
    Lost,
}

/// Cross-worker accumulators.
struct Shared {
    done: AtomicUsize,
    totals: Mutex<FaceRunSummary>,
    reporter: Mutex<Reporter>,
}

impl Shared {
    fn absorb(&self, item: &WorkItem, outcome: Outcome) -> bool {
        let mut totals = lock(&self.totals);
        match outcome {
            Outcome::Done(result) => {
                totals.processed += 1;
                totals.faces_found += result.face_count;
                if result.face_count > 0 {
                    totals.photos_with_faces += 1;
                    if !result.cache_hit {
                        lock(&self.reporter).with_faces.push(item.path.clone());
                    }
                }
                if result.cache_hit {
                    totals.cache_hits += 1;
                }
                true
            }
            Outcome::Skipped => {
                totals.processed += 1;
                totals.skipped += 1;
                true
            }
            Outcome::Failed => {
                totals.processed += 1;
                totals.failed += 1;
                true
            }
            Outcome::Cancelled | Outcome::Lost => false,
        }
    }

    fn report(&self, progress: &dyn FaceProgress, done: usize, total: usize, force: bool) {
        let batch = {
            let mut reporter = lock(&self.reporter);
            let due = force || reporter.last.elapsed() >= PROGRESS_INTERVAL;
            if !due && reporter.with_faces.len() < TAGGED_BATCH {
                return;
            }
            if due {
                reporter.last = Instant::now();
            }
            std::mem::take(&mut reporter.with_faces)
        };
        if !batch.is_empty() {
            progress.on_photos_with_faces(&batch);
        }
        progress.on_progress(done, total);
    }

    fn flush(&self, progress: &dyn FaceProgress, done: usize, total: usize) {
        self.report(progress, done, total, true);
    }

    fn take_totals(&self) -> FaceRunSummary {
        *lock(&self.totals)
    }
}

struct Reporter {
    last: Instant,
    with_faces: Vec<String>,
}

impl Reporter {
    fn new() -> Reporter {
        Reporter {
            last: Instant::now()
                .checked_sub(PROGRESS_INTERVAL)
                .unwrap_or_else(Instant::now),
            with_faces: Vec::new(),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// A library root as a path *prefix*: exactly one trailing separator.
///
/// `pub(crate)` because [`super::naming`] confines a sidecar sync with the same
/// rule the run uses to confine its queue — two spellings of "under this root"
/// would be a very quiet way for a naming to reach outside the security scope
/// a run stayed inside.
pub(crate) fn normalize_root_prefix(root: &str) -> String {
    let trimmed = root.trim_end_matches('/');
    format!("{trimmed}/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_root_prefix_always_ends_in_exactly_one_separator() {
        assert_eq!(normalize_root_prefix("/lib"), "/lib/");
        assert_eq!(normalize_root_prefix("/lib///"), "/lib/");
    }

    #[test]
    fn normalizing_a_sum_produces_a_unit_vector() {
        let v = normalize_sum(&[3.0, 4.0]).unwrap();
        assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
        assert!(normalize_sum(&[0.0, 0.0]).is_none());
    }

    /// A cluster's centroid is the mean of its members, and a face joining it
    /// counts exactly once.
    ///
    /// The bug this pins: seeding the running sum from the database *after*
    /// inserting the membership row counts the joining face twice, which drags
    /// every cluster's centroid toward whichever face happened to arrive first
    /// in a run — and does it silently, because the centroid is still a unit
    /// vector and still roughly in the right place.
    #[test]
    fn a_joining_face_moves_the_centroid_to_the_true_mean() {
        let existing = vec![vec![1.0f32, 0.0]];
        let mut sum = RunningSum::from_members(&existing, 2);
        assert_eq!(sum.count, 1);
        sum.add(&[0.0, 1.0]);
        assert_eq!(sum.count, 2);

        // mean of (1,0) and (0,1), normalized, is (√½, √½) — equidistant. A
        // double-counted joiner would land at (0.447, 0.894) instead.
        let c = sum.centroid().unwrap();
        let root_half = std::f32::consts::FRAC_1_SQRT_2;
        assert!(
            (c[0] - root_half).abs() < 1e-6 && (c[1] - root_half).abs() < 1e-6,
            "{c:?}"
        );
    }

    #[test]
    fn a_member_of_the_wrong_dimension_is_ignored_rather_than_counted() {
        let mut sum = RunningSum::from_members(&[vec![1.0, 0.0], vec![1.0, 0.0, 0.0]], 2);
        assert_eq!(sum.count, 1);
        sum.add(&[9.0]);
        assert_eq!(sum.count, 1);
        assert_eq!(sum.centroid().unwrap(), vec![1.0, 0.0]);
    }

    #[test]
    fn a_cluster_whose_members_cancel_has_no_centroid() {
        let sum = RunningSum::from_members(&[vec![1.0, 0.0], vec![-1.0, 0.0]], 2);
        assert_eq!(sum.count, 2);
        assert!(sum.centroid().is_none());
    }
}
