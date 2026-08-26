//! [`TaggingEngine`] — the orchestrator.
//!
//! Plain Rust: no UniFFI attributes, no `Arc<dyn>` gymnastics for the sake of
//! a binding generator. The FFI crate wraps this; nothing here knows that.
//!
//! # Per-photo pipeline
//!
//! ```text
//! extension check ──unsupported──▶ skipped
//!        │
//!  content hash (streamed)
//!        │
//!  embeddings[(hash, pack#preprocess)] ──hit──▶ reuse, no decode, no inference
//!        │ miss
//!  read bytes → decode → orient → resize → tensor → encode → store
//!        │
//!  skip if sidecar TaggerVersion == pack (unless stale / force)
//!        │
//!  CLIP: sidecar (same model) → sqlite → encode
//!        │
//!  score → gallery_meta::write_tags (always, prefix-replace Objects/Scenes)
//!        │
//!  ml_work → done
//! ```
//!
//! The embedding-cache hit is the whole reason a second "Tag now" over a 20k
//! library finishes in the time it takes to hash: no decode, no inference,
//! and `write_tags` reports `written == false` so not one sidecar mtime moves.
//!
//! # Parallelism
//!
//! A core-owned scoped thread pool, `available_parallelism().min(2)`. Two is
//! the ceiling because this runs on a phone behind a foreground UI: each
//! worker holds a decode buffer, inference is already pinned to one intra-op
//! thread, and the ONNX weights are ~143 MB *per session*. Four workers each
//! with their own session plus a 48 MP RGB buffer is what jetsams an iPhone.
//! No `rayon`: the work is a flat list of independent items and a scoped
//! thread pool over an atomic cursor is ~30 lines and one less dependency in a
//! crate that ships to a phone.
//!
//! # Cancellation
//!
//! Checked before each item, and once per 256 KiB chunk inside the content
//! hash. An in-flight row is released back to `pending`, never marked failed —
//! cancelling a run must not consume a photo's retry budget.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use gallery_meta::{is_content_tag, write_tags, TagWriteRequest};
use gallery_vfs::Vfs;

use crate::cache::{CacheDb, Stats, WorkItem, WorkState};
use crate::encoder::ImageEncoder;
use crate::error::{MlError, MlResult};
use crate::hash::content_hash;
use crate::pack::ModelPack;
use crate::preprocess::{extension_supported, preprocess, PreprocessConfig};
use crate::tagger::ZeroShotTagger;

/// Upper bound on worker threads. See the module docs.
pub const MAX_WORKERS: usize = 2;

/// ONNX sessions held at once, for every model the engines load.
///
/// `ort::Session::run` takes `&mut self`, so a pool of sessions is what lets
/// workers infer concurrently. Each session also owns a copy of the weights.
/// MobileCLIP-S2 is 143 MB on disk and more once Level3 has rewritten the
/// graph; four of those, plus the face models, plus decode buffers, is the
/// jetsam that killed a 12-minute debug scan on iPhone 16. One session
/// serializes inference. Decode still overlaps across [`MAX_WORKERS`].
pub const INFERENCE_SESSIONS: usize = 1;

/// Minimum spacing between [`TaggingProgress::on_progress`] calls.
pub const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

/// How many tagged paths accumulate before
/// [`TaggingProgress::on_photos_tagged`] fires.
pub const TAGGED_BATCH: usize = 32;

/// Callbacks into the host app.
///
/// `Send + Sync` because workers call it directly. Implementations must be
/// cheap and must not block: on the Swift side this hops to the main actor,
/// and a slow callback becomes the pipeline's bottleneck.
pub trait TaggingProgress: Send + Sync {
    /// Throttled to at most one call per [`PROGRESS_INTERVAL`], plus one final
    /// call at the end of the run.
    fn on_progress(&self, done: usize, total: usize);

    /// Paths that gained or changed tags, batched (see [`TAGGED_BATCH`]).
    ///
    /// The app uses this to trigger its existing sidecar refresh — which is
    /// why only *written* sidecars appear here. A no-op rewrite would make the
    /// app re-read a file that did not change.
    fn on_photos_tagged(&self, paths: &[String]);

    /// Called exactly once, whether the run finished or was cancelled.
    fn on_finished(&self, summary: &RunSummary);
}

/// A [`TaggingProgress`] that does nothing.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoProgress;

impl TaggingProgress for NoProgress {
    fn on_progress(&self, _done: usize, _total: usize) {}
    fn on_photos_tagged(&self, _paths: &[String]) {}
    fn on_finished(&self, _summary: &RunSummary) {}
}

/// What one [`TaggingEngine::run`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RunSummary {
    /// Items taken off the queue and carried to a terminal state.
    pub processed: usize,
    /// Items that ended up with at least one tag.
    pub tagged: usize,
    /// Sidecars actually written (a no-op rewrite does not count).
    pub sidecars_written: usize,
    /// Items whose embedding came from the cache — no decode, no inference.
    pub cache_hits: usize,
    /// Items skipped as an unsupported format.
    pub skipped: usize,
    /// Items that failed.
    pub failed: usize,
    /// Whether the run stopped early because `cancel` was set.
    pub cancelled: bool,
}

/// Knobs for one run.
#[derive(Debug, Clone, Default)]
pub struct RunOptions {
    /// Worker threads; clamped to `1..=`[`MAX_WORKERS`]. `None` uses
    /// `available_parallelism()`.
    pub workers: Option<usize>,
    /// Process at most this many items. `None` means everything claimable.
    pub limit: Option<usize>,
    /// The ISO 8601 UTC timestamp stamped into every sidecar sentinel this
    /// run writes.
    ///
    /// One value per run, by construction: gallery-meta writes it verbatim, so
    /// a per-photo clock read would make two identical runs produce different
    /// bytes. `None` reads the clock once, here.
    pub tagged_at: Option<String>,
    /// Only process queue rows under this directory.
    ///
    /// The cache DB outlives any one library root — it is one file per app,
    /// keyed by absolute path — so a user who repoints the app at a different
    /// folder leaves the previous root's rows sitting `pending`. Without this
    /// they would be picked up by the next run and tagged, writing sidecars
    /// outside the library the user is looking at.
    ///
    /// A trailing `/` is added if missing, so `/Photos` cannot match
    /// `/PhotosOld`. `None` means "everything", which is what the crate's own
    /// tests and CLI examples want.
    pub root_prefix: Option<String>,
    /// Re-tag even when the sidecar's `TaggerVersion` already matches.
    /// [`TaggingEngine::reset_queue`] sets this for the next run.
    pub force: bool,
    /// When set, only these absolute paths are taken off the queue.
    pub only_paths: Option<Vec<String>>,
}

/// The tagging orchestrator.
pub struct TaggingEngine {
    cache: Arc<CacheDb>,
    pack: Arc<ModelPack>,
    encoder: Arc<dyn ImageEncoder>,
    vfs: Arc<dyn Vfs>,
    preprocess: PreprocessConfig,
    /// Platform HEIC decode, when the host installed one. `None` in tests and
    /// on the `cargo test` host, where [`crate::heif::HeifDecoder`] runs.
    heic_decoder: Option<Arc<dyn crate::HostHeicDecoder>>,
    /// Set by [`Self::reset_queue`]; consumed by the next [`Self::run`].
    force_next: AtomicBool,
}

impl std::fmt::Debug for TaggingEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TaggingEngine")
            .field("pack", &self.pack.manifest.pack_version)
            .field("backend", &self.encoder.backend_name())
            .field("labels", &self.pack.labels.len())
            .finish()
    }
}

impl TaggingEngine {
    /// Open the cache, load and verify the pack, and build the encoder.
    ///
    /// Available only with the `ort-backend` feature — it is what picks the
    /// backend. [`TaggingEngine::with_encoder`] is the seam for everything
    /// else.
    #[cfg(feature = "ort-backend")]
    pub fn open(
        cache_db_path: impl AsRef<std::path::Path>,
        model_pack_dir: impl AsRef<std::path::Path>,
        vfs: Arc<dyn Vfs>,
    ) -> MlResult<TaggingEngine> {
        let pack = ModelPack::load(model_pack_dir)?;
        let encoder = crate::encoder::OrtEncoder::new(
            &pack.model_bytes,
            &pack.manifest.model.input_name,
            &pack.manifest.model.output_name,
            pack.manifest.model.input_size,
            pack.manifest.model.embedding_dim,
            INFERENCE_SESSIONS,
        )?;
        let cache = CacheDb::open(cache_db_path)?;
        TaggingEngine::with_encoder(cache, pack, Arc::new(encoder), vfs)
    }

    /// Assemble an engine from parts.
    ///
    /// Marks every `done` row from a different pack stale, so a pack upgrade
    /// is picked up by the very next run without the caller having to know.
    pub fn with_encoder(
        cache: CacheDb,
        pack: ModelPack,
        encoder: Arc<dyn ImageEncoder>,
        vfs: Arc<dyn Vfs>,
    ) -> MlResult<TaggingEngine> {
        if encoder.input_size() != pack.manifest.model.input_size {
            return Err(MlError::PackInvalid {
                detail: format!(
                    "encoder input size {} != manifest {}",
                    encoder.input_size(),
                    pack.manifest.model.input_size
                ),
            });
        }
        if encoder.embedding_dim() != pack.manifest.model.embedding_dim {
            return Err(MlError::PackInvalid {
                detail: format!(
                    "encoder embedding dim {} != manifest {}",
                    encoder.embedding_dim(),
                    pack.manifest.model.embedding_dim
                ),
            });
        }
        cache.mark_stale_for_pack(&pack.manifest.pack_version)?;
        cache.set_meta("model_pack", &pack.manifest.pack_version)?;
        let preprocess = pack.preprocess_config();
        Ok(TaggingEngine {
            cache: Arc::new(cache),
            pack: Arc::new(pack),
            encoder,
            vfs,
            preprocess,
            heic_decoder: None,
            force_next: AtomicBool::new(false),
        })
    }

    /// The loaded pack.
    pub fn pack(&self) -> &ModelPack {
        &self.pack
    }

    /// Use `decoder` for HEIC photos. JPEG/PNG stay on the pinned Rust path.
    ///
    /// Builder-style so the FFI can open an engine and then, only on iOS,
    /// install ImageIO without a second constructor on every test.
    pub fn with_heic_decoder(mut self, decoder: Arc<dyn crate::HostHeicDecoder>) -> Self {
        self.heic_decoder = Some(decoder);
        self
    }

    /// Queue counts.
    pub fn stats(&self) -> MlResult<Stats> {
        self.cache.stats()
    }

    /// Add paths to the queue. Idempotent; already-tagged paths keep their
    /// state. Returns the number of newly inserted rows.
    pub fn enqueue(&self, paths: &[String]) -> MlResult<usize> {
        self.cache.enqueue(paths)
    }

    /// Re-open one path so the next forced run will take it, even if it is
    /// already `done`. Inserts the row when the queue has never seen it.
    pub fn reopen(&self, path: &str) -> MlResult<()> {
        self.cache.enqueue(&[path.to_string()])?;
        self.cache.mark_stale(path)?;
        Ok(())
    }

    /// Forget every queue row (keeping cached embeddings), so the next run
    /// re-tags the whole library. This is the "Re-tag everything" button.
    pub fn reset_queue(&self) -> MlResult<()> {
        // Rows come back `Pending` with no pack, which looks like a first-seen
        // photo-tools file. Without this the next run would skip every sidecar
        // already stamped with the current version.
        self.force_next.store(true, Ordering::Relaxed);
        self.cache.reset_queue()
    }

    /// Process the queue.
    ///
    /// Returns `Ok` with `summary.cancelled == true` on cancellation rather
    /// than `Err(Cancelled)`: a cancelled run still did real work and the
    /// caller needs the counts.
    pub fn run(&self, progress: &dyn TaggingProgress, cancel: &AtomicBool) -> MlResult<RunSummary> {
        let opts = RunOptions::default();
        self.run_with_options(progress, cancel, &opts)
    }

    /// [`TaggingEngine::run`] with explicit knobs.
    ///
    /// [`TaggingProgress::on_finished`] fires **exactly once on every path**,
    /// including the ones that return `Err` before a single worker starts. The
    /// FFI layer turns that callback into the app's "run is over" signal, and a
    /// path that skips it leaves the UI spinning forever.
    pub fn run_with_options(
        &self,
        progress: &dyn TaggingProgress,
        cancel: &AtomicBool,
        opts: &RunOptions,
    ) -> MlResult<RunSummary> {
        let mut partial = RunSummary::default();
        let result = self.run_inner(progress, cancel, opts, &mut partial);
        let summary = match &result {
            Ok(s) => *s,
            // A run that failed still did work worth reporting (a panicking
            // worker aborts one item, not the twelve before it), and a run that
            // failed before starting reports the zeroed default.
            Err(_) => partial,
        };
        progress.on_finished(&summary);
        result
    }

    /// The body of a run. `partial` receives the totals so far, so the caller
    /// can report them even when this returns `Err`.
    fn run_inner(
        &self,
        progress: &dyn TaggingProgress,
        cancel: &AtomicBool,
        opts: &RunOptions,
        partial: &mut RunSummary,
    ) -> MlResult<RunSummary> {
        // Between-runs housekeeping. All three used to happen only at
        // `CacheDb::open`, or not at all — which is invisible in a test that
        // opens a fresh engine per run and load-bearing in an app that holds
        // one session for its whole lifetime.
        //
        // 1. Rows a killed process or a panicking worker left claimed.
        self.cache.reclaim_abandoned()?;
        // 2. Rows a *previous build* refused to decode. Keyed on
        //    `DECODER_VERSION`, not on `PREPROCESS_VERSION`: shipping a decoder
        //    for a new format must give those rows another chance without
        //    invalidating a single cached embedding.
        self.cache
            .reopen_skipped_for_decoder(crate::preprocess::DECODER_VERSION)?;
        // 3. Rows whose file changed in place since we tagged it.
        self.restat_done_rows()?;

        let root_prefix = opts.root_prefix.as_deref().map(normalize_root_prefix);
        let mut items = self
            .cache
            .claimable(opts.limit.unwrap_or(0), root_prefix.as_deref())?;
        if let Some(only) = &opts.only_paths {
            items.retain(|item| only.iter().any(|p| p == &item.path));
        }
        let tagged_at = opts.tagged_at.clone().unwrap_or_else(iso8601_utc_now);
        let force = opts.force || self.force_next.swap(false, Ordering::Relaxed);

        let shared = Shared {
            done: AtomicUsize::new(0),
            totals: Mutex::new(RunSummary::default()),
            reporter: Mutex::new(Reporter::new()),
        };

        // Count the photos that still need work *before* the bar starts.
        // A sidecar already stamped with this pack is settled here so it
        // leaves the queue, but it is not "5 / 20,592".
        let (current, work): (Vec<_>, Vec<_>) = items
            .into_iter()
            .partition(|item| self.already_current(item, force));
        for item in &current {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            let outcome = self.process(item, &tagged_at, force, cancel);
            let _ = shared.absorb(item, outcome);
        }

        let total = work.len();
        progress.on_progress(0, total);
        let workers = default_workers(opts.workers).min(total.max(1));

        let cursor = AtomicUsize::new(0);

        // `thread::scope` re-raises a worker panic in *this* thread. Left
        // unguarded that unwinds through the FFI's run thread, so its cleanup
        // never runs, `running` stays true, and every subsequent `start` is
        // `AlreadyRunning` until the app is killed. `process` is written not to
        // panic, but the encoder is third-party code reachable from it, so
        // "cannot panic" is not a property this layer gets to assume.
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            std::thread::scope(|scope| {
                for _ in 0..workers {
                    scope.spawn(|| loop {
                        if cancel.load(Ordering::Relaxed) {
                            break;
                        }
                        let i = cursor.fetch_add(1, Ordering::Relaxed);
                        let Some(item) = work.get(i) else { break };

                        let outcome = self.process(item, &tagged_at, force, cancel);
                        // An item abandoned mid-flight by cancellation is not
                        // "done" — it went back on the queue, and reporting it
                        // as progress would show a finished bar for a run the
                        // user will have to resume.
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
        *partial = summary;

        if panicked {
            // The row the panicking worker held is still `hashing`; the next
            // run's `reclaim_abandoned` puts it back in play.
            return Err(MlError::Inference {
                detail: "a tagging worker panicked".into(),
            });
        }
        Ok(summary)
    }

    /// Demote `done` rows whose file no longer matches the stat we tagged it
    /// against.
    ///
    /// One `stat` per done row per run, no hashing: an in-place edit was
    /// otherwise invisible forever, because `done` is not claimable and nothing
    /// short of a pack change or an explicit reset moves a row off it.
    ///
    /// A row whose file cannot be stat'd is left alone — the photo is gone or
    /// unreadable, and re-queueing it would only produce a failure.
    fn restat_done_rows(&self) -> MlResult<()> {
        for row in self.cache.done_rows_with_stat()? {
            let Ok(stat) = self.vfs.stat(&row.path) else {
                continue;
            };
            if stat.size != row.size || stat.modified_unix != row.modified_unix {
                self.cache.mark_stale(&row.path)?;
            }
        }
        Ok(())
    }

    /// One photo, start to finish. Never panics; every failure mode becomes an
    /// [`Outcome`].
    fn process(&self, item: &WorkItem, tagged_at: &str, force: bool, cancel: &AtomicBool) -> Outcome {
        // Claim first, *then* look at the file. A row this run does not own
        // must not be decoded and must not have a sidecar written for it — the
        // realistic loser is a reset-and-re-enqueue landing between
        // `claimable` and here.
        match self.cache.begin(&item.path) {
            Ok(true) => {}
            Ok(false) => return Outcome::Lost,
            Err(_) => return Outcome::Failed,
        }
        if !extension_supported(&item.path) {
            let _ = self
                .cache
                .finish_skipped(&item.path, crate::preprocess::DECODER_VERSION);
            return Outcome::Skipped;
        }
        match self.process_inner(item, tagged_at, force, cancel) {
            Ok(Some(result)) => {
                // Stamp the stat this decision was made against, so a later run
                // can spot an in-place edit. A file that vanished between the
                // write and here records nothing rather than a wrong baseline.
                let stat = self
                    .vfs
                    .stat(&item.path)
                    .ok()
                    .map(|s| (s.size, s.modified_unix));
                match self.cache.finish_done(
                    &item.path,
                    self.pack.version(),
                    result.tag_count,
                    stat,
                ) {
                    Ok(true) => Outcome::Done(result),
                    Ok(false) => Outcome::Lost,
                    Err(_) => Outcome::Failed,
                }
            }
            Ok(None) => {
                // Cancelled, or the row was taken from under us. `release` only
                // touches rows still in `hashing`, so it is correct for both.
                let _ = self.cache.release(&item.path);
                Outcome::Cancelled
            }
            Err(e) => {
                let _ = self.cache.finish_failed(&item.path, e.error_code());
                Outcome::Failed
            }
        }
    }

    /// `Ok(None)` means "cancelled mid-photo".
    fn process_inner(
        &self,
        item: &WorkItem,
        tagged_at: &str,
        force: bool,
        cancel: &AtomicBool,
    ) -> MlResult<Option<PhotoResult>> {
        let cancelled = || cancel.load(Ordering::Relaxed);
        let path = item.path.as_str();

        // Same pack already stamped, file unchanged, not a forced re-tag.
        if self.already_current(item, force) {
            let tag_count = self
                .sidecar_view(path)
                .map(|view| view.tags_list.iter().filter(|t| is_content_tag(t)).count())
                .unwrap_or(0);
            return Ok(Some(PhotoResult {
                tag_count,
                written: false,
                cache_hit: true,
            }));
        }

        // The streamed hash is a *probe key* only. It describes the bytes as
        // they were during the streaming read, and the file may be rewritten
        // before the decode read below — a cloud provider finishing a
        // materialization is the everyday case, not a contrived one.
        let Some(probe) = content_hash(self.vfs.as_ref(), path, &cancelled)? else {
            return Ok(None);
        };

        let model_key = self.pack.embedding_model_key();
        let dim = self.pack.manifest.model.embedding_dim;
        let (embedding, cache_hit, hash) =
            if let Some(v) = self.sidecar_clip(path, dim) {
                self.cache.put_embedding(&probe, &model_key, &v)?;
                (v, true, probe)
            } else {
                match self.cache.embedding(&probe, &model_key)? {
                    Some(v) if v.len() == dim => (v, true, probe),
                    _ => {
                        if cancelled() {
                            return Ok(None);
                        }
                        let (tensor, hash) = self.decode_for_embed(path, &probe)?;
                        if cancelled() {
                            return Ok(None);
                        }
                        let v = self.encoder.embed(&tensor)?;
                        self.cache.put_embedding(&hash, &model_key, &v)?;
                        (v, false, hash)
                    }
                }
            };

        // Recorded after the fact, so the row names the bytes we actually
        // tagged. Zero rows affected means the row was reset from under us.
        if !self.cache.set_content_hash(path, &hash)? {
            return Ok(None);
        }

        if cancelled() {
            return Ok(None);
        }

        let tags = ZeroShotTagger::new(&self.pack).tags(&embedding, &BTreeSet::new());
        let request = TagWriteRequest::new(
            tags.clone(),
            self.pack.version().to_string(),
            tagged_at.to_string(),
        )
        .with_clip(
            clip_embedding_b64(&embedding),
            self.pack.version(),
            tagged_at,
        );
        let outcome = write_tags(self.vfs.as_ref(), path, &request)?;

        Ok(Some(PhotoResult {
            tag_count: tags.len(),
            written: outcome.written,
            cache_hit,
        }))
    }

    fn sidecar_view(&self, path: &str) -> Option<gallery_meta::SidecarView> {
        let bytes = self.vfs.read(&gallery_meta::sidecar_path(path)).ok()?;
        gallery_meta::read_view(&bytes).ok()
    }

    /// Sidecar already carries this pack, file unchanged, not a forced re-tag.
    /// Those photos are settled off the queue but are not the progress total.
    fn already_current(&self, item: &WorkItem, force: bool) -> bool {
        if force || item.state == WorkState::Stale {
            return false;
        }
        self.sidecar_view(&item.path).is_some_and(|view| {
            view.photo_tools.tagger_version.as_deref() == Some(self.pack.version())
        })
    }

    fn sidecar_clip(&self, path: &str, dim: usize) -> Option<Vec<f32>> {
        let view = self.sidecar_view(path)?;
        if view.photo_tools.clip_model.as_deref() != Some(self.pack.version()) {
            return None;
        }
        clip_embedding_from_b64(view.photo_tools.clip_embedding.as_deref()?, dim)
    }

    /// Decode + preprocess one photo for embedding.
    ///
    /// HEIC on a host that installed a platform decoder skips the second full
    /// file read (ImageIO opens the path itself) and the software HEVC
    /// decode. A host failure is the photo's failure — software HEVC of a
    /// 48 MP frame is the allocation a phone cannot absorb. JPEG/PNG stay
    /// on the pinned `vfs.read` + `preprocess` path, hashed from the buffer
    /// that is actually decoded so a rewrite between the probe hash and the
    /// read cannot poison the cache.
    fn decode_for_embed(&self, path: &str, probe: &[u8; 32]) -> MlResult<(crate::Tensor, [u8; 32])> {
        if let Some(rgb) =
            crate::preprocess::host_heic_decode(self.heic_decoder.as_deref(), path)?
        {
            // ImageIO already caps the long side; this is the backstop if a
            // host decoder ignores its own thumbnail size.
            let rgb = crate::preprocess::limit_long_side(
                rgb,
                crate::preprocess::ANALYSIS_MAX_LONG_SIDE,
            );
            let tensor = crate::preprocess::tensor_from_rgb(path, rgb, &self.preprocess)?;
            return Ok((tensor, *probe));
        }
        let bytes = self.vfs.read(path)?;
        let hash = crate::hash::hash_bytes(&bytes);
        let tensor = preprocess(path, &bytes, &self.preprocess)?;
        drop(bytes);
        Ok((tensor, hash))
    }
}

struct PhotoResult {
    tag_count: usize,
    written: bool,
    cache_hit: bool,
}

enum Outcome {
    Done(PhotoResult),
    Skipped,
    Failed,
    Cancelled,
    /// The row was taken from under this worker (a queue reset mid-run). Not
    /// progress, not a failure — there is simply nothing to report.
    Lost,
}

/// Cross-worker accumulators.
struct Shared {
    done: AtomicUsize,
    totals: Mutex<RunSummary>,
    reporter: Mutex<Reporter>,
}

impl Shared {
    /// Fold one outcome into the totals. Returns whether the item reached a
    /// terminal state — a cancelled item did not, and does not count as
    /// progress.
    fn absorb(&self, item: &WorkItem, outcome: Outcome) -> bool {
        let mut totals = lock(&self.totals);
        match outcome {
            Outcome::Done(result) => {
                totals.processed += 1;
                if result.tag_count > 0 {
                    totals.tagged += 1;
                }
                if result.cache_hit {
                    totals.cache_hits += 1;
                }
                if result.written {
                    totals.sidecars_written += 1;
                    lock(&self.reporter).tagged.push(item.path.clone());
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

    fn report(&self, progress: &dyn TaggingProgress, done: usize, total: usize, force: bool) {
        let batch = {
            let mut reporter = lock(&self.reporter);
            let due = force || reporter.last.elapsed() >= PROGRESS_INTERVAL;
            if !due && reporter.tagged.len() < TAGGED_BATCH {
                return;
            }
            if due {
                reporter.last = Instant::now();
            }
            std::mem::take(&mut reporter.tagged)
        };
        if !batch.is_empty() {
            progress.on_photos_tagged(&batch);
        }
        progress.on_progress(done, total);
    }

    fn flush(&self, progress: &dyn TaggingProgress, done: usize, total: usize) {
        self.report(progress, done, total, true);
    }

    fn take_totals(&self) -> RunSummary {
        *lock(&self.totals)
    }
}

struct Reporter {
    last: Instant,
    tagged: Vec<String>,
}

impl Reporter {
    fn new() -> Reporter {
        Reporter {
            // Start one interval in the past so the first completed item
            // produces a progress callback immediately — a UI that shows
            // nothing for 250 ms after "Tag now" looks broken. `checked_sub`
            // because `Instant` is monotonic-since-boot on Apple platforms and
            // plain subtraction panics in the first 250 ms of uptime.
            last: Instant::now()
                .checked_sub(PROGRESS_INTERVAL)
                .unwrap_or_else(Instant::now),
            tagged: Vec::new(),
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
/// Without it `/Users/me/Photos` matches `/Users/me/PhotosOld/x.jpg`, which is
/// the entire point of scoping a run to a root.
fn normalize_root_prefix(root: &str) -> String {
    let trimmed = root.trim_end_matches('/');
    format!("{trimmed}/")
}

/// Worker count: the request, else `available_parallelism()`, clamped to
/// `1..=`[`MAX_WORKERS`].
pub fn default_workers(requested: Option<usize>) -> usize {
    let n = requested.unwrap_or_else(|| {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
    });
    n.clamp(1, MAX_WORKERS)
}

/// photo-tools §1.2: `CLIPEmbedding` is standard-base64 of little-endian
/// `f32` bytes. Hand-rolled so the crate does not pick up a codec just for
/// one sidecar field — the alphabet and padding are the RFC 4648 ones
/// `base64.b64encode` uses, which is what photo-tools writes and reads.
fn clip_embedding_b64(embedding: &[f32]) -> String {
    let mut bytes = Vec::with_capacity(embedding.len() * 4);
    for value in embedding {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    encode_base64(&bytes)
}

fn clip_embedding_from_b64(b64: &str, dim: usize) -> Option<Vec<f32>> {
    let bytes = decode_base64(b64)?;
    if bytes.len() != dim * 4 {
        return None;
    }
    Some(
        bytes
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect(),
    )
}

fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len().div_ceil(4) * 3);
    let mut buf = 0u32;
    let mut bits = 0u32;
    for &c in input.as_bytes() {
        if c == b'=' {
            break;
        }
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'\n' | b'\r' | b' ' => continue,
            _ => return None,
        } as u32;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Some(out)
}

const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encode_base64(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let a = u32::from(chunk[0]);
        let b = u32::from(chunk.get(1).copied().unwrap_or(0));
        let c = u32::from(chunk.get(2).copied().unwrap_or(0));
        let n = (a << 16) | (b << 8) | c;
        out.push(BASE64_ALPHABET[((n >> 18) & 63) as usize] as char);
        out.push(BASE64_ALPHABET[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            BASE64_ALPHABET[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            BASE64_ALPHABET[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// `2026-08-03T10:00:00Z` from the system clock.
///
/// Hand-rolled rather than pulling `chrono`/`time` in: this is the only date
/// formatting the crate does, the format is fixed by
/// `gallery_meta::TagWriteRequest::tagged_at`, and a date library is a
/// surprising amount of code to ship to a phone for one `strftime`.
pub fn iso8601_utc_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    iso8601_utc(secs)
}

/// `secs` since the Unix epoch as `YYYY-MM-DDTHH:MM:SSZ`.
///
/// Proleptic Gregorian, days-from-civil (Howard Hinnant's algorithm). Negative
/// inputs (pre-1970 clocks) are clamped to the epoch rather than producing a
/// year-1969 sentinel nobody wants in a sidecar.
pub fn iso8601_utc(secs: i64) -> String {
    let secs = secs.max(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_timestamps_match_known_instants() {
        assert_eq!(iso8601_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601_utc(1_770_000_000), "2026-02-02T02:40:00Z");
        // 2024-02-29, the leap day the algorithm must not lose.
        assert_eq!(iso8601_utc(1_709_164_800), "2024-02-29T00:00:00Z");
        assert_eq!(iso8601_utc(-5), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn a_root_prefix_always_ends_in_exactly_one_separator() {
        assert_eq!(
            normalize_root_prefix("/Users/me/Photos"),
            "/Users/me/Photos/"
        );
        assert_eq!(
            normalize_root_prefix("/Users/me/Photos/"),
            "/Users/me/Photos/"
        );
        assert_eq!(
            normalize_root_prefix("/Users/me/Photos///"),
            "/Users/me/Photos/"
        );
    }

    #[test]
    fn worker_count_is_clamped_to_the_ceiling() {
        assert_eq!(default_workers(Some(0)), 1);
        assert_eq!(default_workers(Some(1)), 1);
        assert_eq!(default_workers(Some(64)), MAX_WORKERS);
        assert!((1..=MAX_WORKERS).contains(&default_workers(None)));
    }

    #[test]
    fn inference_sessions_do_not_multiply_the_weights() {
        assert_eq!(INFERENCE_SESSIONS, 1);
        assert!(INFERENCE_SESSIONS <= MAX_WORKERS);
    }

    #[test]
    fn clip_embedding_b64_matches_the_photo_tools_fixture() {
        // phototools.jpg.xmp: three little-endian f32s, 0.5 / 0.5 / 1.0.
        assert_eq!(clip_embedding_b64(&[0.5, 0.5, 1.0]), "AAAAPwAAAD8AAIA/");
        assert_eq!(
            clip_embedding_from_b64("AAAAPwAAAD8AAIA/", 3).as_deref(),
            Some(&[0.5, 0.5, 1.0][..])
        );
    }
}
