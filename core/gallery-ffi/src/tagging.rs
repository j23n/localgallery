//! The UniFFI surface over [`gallery_ml::TaggingEngine`].
//!
//! Everything here is a thin adapter. The engine is plain Rust and knows
//! nothing about bindings; this module owns the three things the boundary
//! needs and the engine deliberately does not have:
//!
//! 1. **A thread.** [`TaggingEngine::run`] blocks. `start` spawns one
//!    core-owned thread and returns immediately, per the FFI rule that long
//!    work runs on core-owned threads with start/cancel/progress. It runs at
//!    whatever the OS gives a plain pthread — Rust's `std::thread` has no
//!    portable QoS knob, and setting a Darwin QoS class needs an `unsafe`
//!    `pthread_set_qos_class_self_np`, which `gallery-ml` forbids. Tagging is
//!    user-initiated and cancellable, so default scheduling is the right
//!    trade until that stops being true.
//! 2. **A run lock.** One run at a time; a second `start` while running is an
//!    error rather than a second thread racing the same SQLite connection.
//! 3. **Typed errors.** [`gallery_ml::MlError`] carries `VfsError`/`MetaError`
//!    values that would drag two more crates' enums across the boundary.
//!    [`TaggingError`] flattens them into one closed enum ("errors cross the
//!    boundary as typed enums, never strings").
//!
//! # Callback ordering
//!
//! The engine's own `on_finished` is swallowed by [`ProgressAdapter`] and
//! re-emitted here *after* the run lock is released, so a listener that
//! reacts to `onFinished` by calling `isRunning()` (or by starting another
//! run) always sees a settled session.
//!
//! Two things make that contract survive contact with a real listener:
//! [`FinishGuard`] runs the release-then-report pair on the way out of the run
//! thread even if it unwinds, and [`join_unless_current`] keeps a listener that
//! restarts or releases the session from self-joining the thread it is standing
//! on.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use gallery_ml::{
    engine::iso8601_utc_now, MlError, RunOptions, RunSummary, TaggingEngine, TaggingProgress,
};
use gallery_vfs::{StdVfs, VfsError};

use gallery_meta::MetaError;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Why a tagging call failed.
///
/// A flattening of [`MlError`] (plus the one failure mode only this layer has,
/// [`TaggingError::AlreadyRunning`]). The `detail` strings are for logs — the
/// *variant* is what callers switch on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum TaggingError {
    /// A file named by the model-pack manifest is missing.
    PackFileMissing {
        /// Path that was expected to exist.
        path: String,
    },
    /// A model-pack file does not hash to what the manifest claims.
    PackHashMismatch {
        /// Manifest-relative file name.
        file: String,
        /// Hex SHA-256 from the manifest.
        expected: String,
        /// Hex SHA-256 actually computed.
        actual: String,
    },
    /// The manifest or the label set is malformed.
    PackInvalid {
        /// What was wrong; for logs only.
        detail: String,
    },
    /// The cache DB is unusable.
    Cache {
        /// SQLite message; for logs only.
        detail: String,
    },
    /// The inference backend refused the model.
    Inference {
        /// Backend message; for logs only.
        detail: String,
    },
    /// A filesystem operation failed.
    Io {
        /// The path involved.
        path: String,
        /// Platform message; for logs only.
        detail: String,
    },
    /// A sidecar could not be parsed or written.
    Sidecar {
        /// Parser/writer message; for logs only.
        detail: String,
    },
    /// The run was cancelled.
    Cancelled,
    /// `start` was called while a run was already in flight.
    AlreadyRunning,
}

impl std::fmt::Display for TaggingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TaggingError::PackFileMissing { path } => write!(f, "model pack file missing: {path}"),
            TaggingError::PackHashMismatch {
                file,
                expected,
                actual,
            } => write!(f, "model pack {file}: expected {expected}, got {actual}"),
            TaggingError::PackInvalid { detail } => write!(f, "invalid model pack: {detail}"),
            TaggingError::Cache { detail } => write!(f, "cache db: {detail}"),
            TaggingError::Inference { detail } => write!(f, "inference: {detail}"),
            TaggingError::Io { path, detail } => write!(f, "io {path}: {detail}"),
            TaggingError::Sidecar { detail } => write!(f, "sidecar: {detail}"),
            TaggingError::Cancelled => write!(f, "cancelled"),
            TaggingError::AlreadyRunning => write!(f, "a tagging run is already in progress"),
        }
    }
}

impl std::error::Error for TaggingError {}

impl From<MlError> for TaggingError {
    fn from(e: MlError) -> Self {
        match e {
            MlError::PackFileMissing { path } => TaggingError::PackFileMissing { path },
            MlError::PackHashMismatch {
                file,
                expected,
                actual,
            } => TaggingError::PackHashMismatch {
                file,
                expected,
                actual,
            },
            MlError::PackInvalid { detail } => TaggingError::PackInvalid { detail },
            MlError::Cache { detail } => TaggingError::Cache { detail },
            MlError::Inference { detail } => TaggingError::Inference { detail },
            MlError::Preprocess { path, detail, .. } => TaggingError::Io { path, detail },
            MlError::Vfs(v) => v.into(),
            MlError::Meta(m) => m.into(),
            MlError::Cancelled => TaggingError::Cancelled,
        }
    }
}

impl From<VfsError> for TaggingError {
    fn from(e: VfsError) -> Self {
        let detail = e.to_string();
        let path = match &e {
            VfsError::NotFound { path }
            | VfsError::PermissionDenied { path }
            | VfsError::NotADirectory { path }
            | VfsError::AlreadyExists { path }
            | VfsError::InvalidPath { path, .. }
            | VfsError::Io { path, .. } => path.clone(),
        };
        TaggingError::Io { path, detail }
    }
}

impl From<MetaError> for TaggingError {
    fn from(e: MetaError) -> Self {
        match e {
            MetaError::Vfs(v) => v.into(),
            other => TaggingError::Sidecar {
                detail: other.to_string(),
            },
        }
    }
}

/// Coarse classification of a run-level failure, carried on
/// [`TaggingRunSummary::failure`].
///
/// Deliberately field-less: it exists so `onFinished` can say *why* a run
/// stopped without the summary record having to embed an error type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TaggingFailure {
    /// The model pack is missing, corrupt, or mis-hashed.
    Pack,
    /// The cache DB rejected the run.
    CacheDb,
    /// The inference backend failed.
    Inference,
    /// A filesystem operation failed.
    Io,
    /// A sidecar could not be parsed or written.
    Sidecar,
    /// The run was aborted by cancellation (distinct from
    /// [`TaggingRunSummary::cancelled`], which is the normal cancel path).
    Cancelled,
}

impl From<&TaggingError> for TaggingFailure {
    fn from(e: &TaggingError) -> Self {
        match e {
            TaggingError::PackFileMissing { .. }
            | TaggingError::PackHashMismatch { .. }
            | TaggingError::PackInvalid { .. } => TaggingFailure::Pack,
            TaggingError::Cache { .. } => TaggingFailure::CacheDb,
            TaggingError::Inference { .. } => TaggingFailure::Inference,
            TaggingError::Io { .. } => TaggingFailure::Io,
            TaggingError::Sidecar { .. } => TaggingFailure::Sidecar,
            TaggingError::Cancelled | TaggingError::AlreadyRunning => TaggingFailure::Cancelled,
        }
    }
}

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Queue counts. Cheap enough to poll.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TaggingStats {
    /// Rows waiting to be processed (including stale and retryable failures).
    pub pending: u64,
    /// Rows tagged under the current pack.
    pub done: u64,
    /// Rows that failed and are out of retries.
    pub failed: u64,
    /// Rows skipped as an unsupported format.
    pub skipped: u64,
    /// Rows that ended up with at least one tag.
    pub tagged: u64,
}

/// What one run did. Mirrors [`gallery_ml::RunSummary`] with a `failure` field
/// for the run-level-error case, since `onFinished` fires either way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TaggingRunSummary {
    /// Items carried to a terminal state.
    pub processed: u32,
    /// Items that ended up with at least one tag.
    pub tagged: u32,
    /// Sidecars actually written (a no-op rewrite does not count).
    pub sidecars_written: u32,
    /// Items whose embedding came from the cache.
    pub cache_hits: u32,
    /// Items skipped as an unsupported format.
    pub skipped: u32,
    /// Items that failed.
    pub failed: u32,
    /// Whether the run stopped early because `cancel` was set.
    pub cancelled: bool,
    /// Set when the run aborted with a run-level error.
    pub failure: Option<TaggingFailure>,
}

impl From<RunSummary> for TaggingRunSummary {
    fn from(s: RunSummary) -> Self {
        TaggingRunSummary {
            processed: s.processed as u32,
            tagged: s.tagged as u32,
            sidecars_written: s.sidecars_written as u32,
            cache_hits: s.cache_hits as u32,
            skipped: s.skipped as u32,
            failed: s.failed as u32,
            cancelled: s.cancelled,
            failure: None,
        }
    }
}

/// Identity and shape of the loaded model pack, for the Settings status line.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ModelPackInfo {
    /// `manifest.pack_version` — the string written into every sidecar.
    pub version: String,
    /// How many taxonomy leaves the pack can emit.
    pub label_count: u32,
    /// Encoder embedding length.
    pub embedding_dim: u32,
    /// Encoder input edge, in pixels.
    pub input_size: u32,
}

// ---------------------------------------------------------------------------
// Progress
// ---------------------------------------------------------------------------

/// Callbacks into the host app during a run.
///
/// Implementations are called from the core's worker threads and must not
/// block — on Swift the implementation hands off to the main actor and
/// returns. `on_progress` is already throttled in Rust (250 ms) and
/// `on_photos_tagged` is already batched, so no throttling is needed here.
#[uniffi::export(with_foreign)]
pub trait TaggingProgressListener: Send + Sync {
    /// Throttled progress, plus one final call at the end of the run.
    fn on_progress(&self, done: u32, total: u32);

    /// Absolute paths whose sidecars were *written*, batched.
    ///
    /// Only written sidecars appear here, so the app's refresh is driven by
    /// files that actually changed.
    fn on_photos_tagged(&self, paths: Vec<String>);

    /// Exactly once per `start`, whether the run finished, was cancelled, or
    /// failed. Fires after the session has released its run lock.
    fn on_finished(&self, summary: TaggingRunSummary);
}

/// Bridges [`TaggingProgress`] (engine-side, `&[String]`) to
/// [`TaggingProgressListener`] (FFI-side, `Vec<String>`), and swallows the
/// engine's `on_finished` — see the module docs on callback ordering.
struct ProgressAdapter {
    inner: Arc<dyn TaggingProgressListener>,
}

impl TaggingProgress for ProgressAdapter {
    fn on_progress(&self, done: usize, total: usize) {
        self.inner.on_progress(done as u32, total as u32);
    }

    fn on_photos_tagged(&self, paths: &[String]) {
        self.inner.on_photos_tagged(paths.to_vec());
    }

    fn on_finished(&self, _summary: &RunSummary) {}
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// A tagging session: one cache DB, one model pack, at most one run at a time.
///
/// Holding one open holds the ONNX sessions and the SQLite connection, so the
/// app keeps a single instance for as long as tagging is available rather than
/// constructing one per run.
#[derive(uniffi::Object)]
pub struct TaggingSession {
    engine: Arc<TaggingEngine>,
    cancel: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
    /// The in-flight (or just-finished) run thread, joined on the next
    /// `start` and on drop so a session never outlives its worker.
    thread: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export]
impl TaggingSession {
    /// Open the cache DB and load + verify the model pack.
    ///
    /// The VFS is [`StdVfs`]: on iOS the caller has already resolved the
    /// security-scoped root, so the core only ever sees plain paths under an
    /// active scope (overview, FFI rules).
    #[uniffi::constructor]
    pub fn new(
        cache_db_path: String,
        model_pack_dir: String,
    ) -> Result<Arc<TaggingSession>, TaggingError> {
        let engine = TaggingEngine::open(&cache_db_path, &model_pack_dir, Arc::new(StdVfs))?;
        Ok(Arc::new(TaggingSession {
            engine: Arc::new(engine),
            cancel: Arc::new(AtomicBool::new(false)),
            running: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
        }))
    }

    /// Add paths to the queue; returns how many rows were newly inserted.
    ///
    /// Idempotent — re-enqueuing an already-tagged path leaves its state
    /// alone, which is what makes "enqueue the whole library every time" the
    /// correct call pattern.
    pub fn enqueue(&self, paths: Vec<String>) -> Result<u32, TaggingError> {
        Ok(self.engine.enqueue(&paths)? as u32)
    }

    /// Start processing the queue on a core-owned thread and return at once.
    ///
    /// `root_prefix`, when given, confines the run to queue rows under that
    /// directory — the cache DB outlives any one library root, and rows left
    /// over from a previous root must not be tagged (they are skipped, not
    /// failed, so nothing burns a retry).
    ///
    /// Fails with [`TaggingError::AlreadyRunning`] if a run is in flight.
    pub fn start(
        &self,
        progress: Arc<dyn TaggingProgressListener>,
        root_prefix: Option<String>,
    ) -> Result<(), TaggingError> {
        // Acquire the run lock before touching anything else: two concurrent
        // `start` calls must not both get as far as spawning.
        if self
            .running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(TaggingError::AlreadyRunning);
        }

        // Reap the previous run's thread. It has already cleared `running`, so
        // this join is effectively instant; skipping it would leak a thread
        // handle per run.
        let mut slot = lock(&self.thread);
        if let Some(previous) = slot.take() {
            join_unless_current(previous);
        }

        self.cancel.store(false, Ordering::Release);

        let engine = Arc::clone(&self.engine);
        let cancel = Arc::clone(&self.cancel);
        let running = Arc::clone(&self.running);
        let listener = Arc::clone(&progress);

        let spawned = std::thread::Builder::new()
            .name("gallery-tagging".to_string())
            .spawn(move || {
                // The cleanup — release the run lock, then report — lives in a
                // drop guard so it also happens if this thread unwinds. Without
                // it a panic anywhere below leaves `running` true forever:
                // every later `start` answers `AlreadyRunning` and the app's
                // tagging UI is wedged until it is killed.
                let mut guard = FinishGuard {
                    running,
                    listener: Arc::clone(&listener),
                    summary: None,
                };
                let adapter = ProgressAdapter {
                    inner: Arc::clone(&listener),
                };
                // One timestamp for the whole run: gallery-meta writes it
                // verbatim, so a per-photo clock read would make two identical
                // runs produce different sidecar bytes.
                let opts = RunOptions {
                    tagged_at: Some(iso8601_utc_now()),
                    root_prefix,
                    ..RunOptions::default()
                };
                let outcome = engine.run_with_options(&adapter, &cancel, &opts);
                guard.summary = Some(match outcome {
                    Ok(s) => TaggingRunSummary::from(s),
                    Err(e) => {
                        let err = TaggingError::from(e);
                        TaggingRunSummary {
                            processed: 0,
                            tagged: 0,
                            sidecars_written: 0,
                            cache_hits: 0,
                            skipped: 0,
                            failed: 0,
                            cancelled: cancel.load(Ordering::Acquire),
                            failure: Some(TaggingFailure::from(&err)),
                        }
                    }
                });
            });

        match spawned {
            Ok(handle) => {
                *slot = Some(handle);
                Ok(())
            }
            Err(e) => {
                self.running.store(false, Ordering::Release);
                Err(TaggingError::Io {
                    path: String::new(),
                    detail: format!("could not spawn tagging thread: {e}"),
                })
            }
        }
    }

    /// Ask the in-flight run to stop. Returns immediately; the run ends at the
    /// next item boundary (or the next 256 KiB of a content hash) and reports
    /// through `on_finished` with `cancelled == true`.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
    }

    /// Whether a run is in flight.
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    /// Queue counts.
    pub fn stats(&self) -> Result<TaggingStats, TaggingError> {
        let s = self.engine.stats()?;
        Ok(TaggingStats {
            pending: s.pending,
            done: s.done,
            failed: s.failed,
            skipped: s.skipped,
            tagged: s.tagged,
        })
    }

    /// Forget every queue row (cached embeddings survive), so the next run
    /// re-tags the whole library. Refused mid-run — resetting the queue under
    /// a live run would have workers finishing rows that no longer exist.
    pub fn reset_queue(&self) -> Result<(), TaggingError> {
        if self.is_running() {
            return Err(TaggingError::AlreadyRunning);
        }
        self.engine.reset_queue()?;
        Ok(())
    }

    /// The loaded pack's identity and shape.
    pub fn model_pack_info(&self) -> ModelPackInfo {
        pack_info(self.engine.pack())
    }
}

impl Drop for TaggingSession {
    fn drop(&mut self) {
        // A detached worker thread would keep an `Arc<TaggingEngine>` — and
        // with it the SQLite connection — alive past the session the app
        // thinks it released.
        self.cancel.store(true, Ordering::Release);
        if let Some(handle) = lock(&self.thread).take() {
            join_unless_current(handle);
        }
    }
}

/// Runs the end-of-run cleanup on the way out of the run thread, unwinding or
/// not: release the run lock first, then report.
///
/// The ordering is the documented contract — a listener that reacts to
/// `onFinished` by calling `isRunning()` or `start()` must see a settled
/// session — and it is why this is a guard rather than two statements: a panic
/// between them would strand the lock.
struct FinishGuard {
    running: Arc<AtomicBool>,
    listener: Arc<dyn TaggingProgressListener>,
    summary: Option<TaggingRunSummary>,
}

impl Drop for FinishGuard {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Release);
        let summary = self.summary.take().unwrap_or(TaggingRunSummary {
            processed: 0,
            tagged: 0,
            sidecars_written: 0,
            cache_hits: 0,
            skipped: 0,
            failed: 0,
            cancelled: false,
            // Reached only when the run thread unwound: the engine's own
            // guarantees say nothing about a panic, so the run is reported as a
            // failure rather than as a quiet zero-item success.
            failure: Some(TaggingFailure::Inference),
        });
        self.listener.on_finished(summary);
    }
}

/// Join `handle` unless it *is* the current thread.
///
/// `on_finished` runs on the run thread, and the contract explicitly invites a
/// listener to call `start()` from it — or to drop its last session reference,
/// which reaches `Drop`. Both paths would otherwise join the very thread they
/// are running on, and a self-join aborts the process. Skipping the join
/// detaches the thread, which is safe precisely here: the thread is finishing
/// its own last statement, so nothing outlives what the join was protecting.
fn join_unless_current(handle: JoinHandle<()>) {
    if handle.thread().id() == std::thread::current().id() {
        return;
    }
    let _ = handle.join();
}

/// Verify and inspect a model pack directory without opening a session.
///
/// This is what Settings calls after importing a pack: it runs the same
/// SHA-256 verification [`TaggingSession::new`] does, so an invalid pack is
/// rejected at import time rather than at the first "Tag Library Now".
#[uniffi::export]
pub fn inspect_model_pack(model_pack_dir: String) -> Result<ModelPackInfo, TaggingError> {
    let pack = gallery_ml::ModelPack::load(&model_pack_dir)?;
    Ok(pack_info(&pack))
}

fn pack_info(pack: &gallery_ml::ModelPack) -> ModelPackInfo {
    ModelPackInfo {
        version: pack.version().to_string(),
        label_count: pack.labels.len() as u32,
        embedding_dim: pack.manifest.model.embedding_dim as u32,
        input_size: pack.manifest.model.input_size,
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ml_errors_flatten_onto_the_boundary_enum() {
        assert_eq!(
            TaggingError::from(MlError::Vfs(VfsError::NotFound { path: "/x".into() })),
            TaggingError::Io {
                path: "/x".into(),
                detail: VfsError::NotFound { path: "/x".into() }.to_string(),
            }
        );
        assert!(matches!(
            TaggingError::from(MlError::Meta(MetaError::MalformedXml {
                detail: "boom".into()
            })),
            TaggingError::Sidecar { .. }
        ));
        assert!(matches!(
            TaggingError::from(MlError::PackInvalid {
                detail: "boom".into()
            }),
            TaggingError::PackInvalid { .. }
        ));
    }

    #[test]
    fn failures_classify_by_family() {
        assert_eq!(
            TaggingFailure::from(&TaggingError::Cache {
                detail: String::new()
            }),
            TaggingFailure::CacheDb
        );
        assert_eq!(
            TaggingFailure::from(&TaggingError::PackFileMissing {
                path: String::new()
            }),
            TaggingFailure::Pack
        );
    }

    /// The guard is what keeps a panicking run thread from latching `running`
    /// true forever — after which every `start` answers `AlreadyRunning` and
    /// the app's tagging UI is wedged until it is killed.
    #[test]
    fn an_unwinding_run_thread_still_releases_the_lock_and_reports() {
        #[derive(Default)]
        struct Recorder {
            finished: Mutex<Vec<TaggingRunSummary>>,
            /// `running` as observed from inside `on_finished` — the ordering
            /// the trait documents.
            running_when_reported: Mutex<Vec<bool>>,
            running: Mutex<Option<Arc<AtomicBool>>>,
        }
        impl TaggingProgressListener for Recorder {
            fn on_progress(&self, _done: u32, _total: u32) {}
            fn on_photos_tagged(&self, _paths: Vec<String>) {}
            fn on_finished(&self, summary: TaggingRunSummary) {
                let observed = lock(&self.running)
                    .as_ref()
                    .map(|r| r.load(Ordering::Acquire))
                    .unwrap_or(true);
                lock(&self.running_when_reported).push(observed);
                lock(&self.finished).push(summary);
            }
        }

        let running = Arc::new(AtomicBool::new(true));
        let recorder = Arc::new(Recorder::default());
        *lock(&recorder.running) = Some(Arc::clone(&running));

        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = FinishGuard {
                running: Arc::clone(&running),
                listener: Arc::clone(&recorder) as Arc<dyn TaggingProgressListener>,
                summary: None,
            };
            panic!("the run thread exploded");
        }))
        .is_err();
        std::panic::set_hook(previous);

        assert!(unwound);
        assert!(
            !running.load(Ordering::Acquire),
            "the run lock was stranded"
        );
        let finished = lock(&recorder.finished);
        assert_eq!(finished.len(), 1, "on_finished must fire exactly once");
        assert_eq!(finished[0].failure, Some(TaggingFailure::Inference));
        // Released *before* the report, so a listener that restarts the session
        // from `on_finished` sees a settled one.
        assert_eq!(lock(&recorder.running_when_reported).as_slice(), &[false]);
    }

    #[test]
    fn a_completed_run_reports_the_summary_it_was_given() {
        #[derive(Default)]
        struct Recorder {
            finished: Mutex<Vec<TaggingRunSummary>>,
        }
        impl TaggingProgressListener for Recorder {
            fn on_progress(&self, _done: u32, _total: u32) {}
            fn on_photos_tagged(&self, _paths: Vec<String>) {}
            fn on_finished(&self, summary: TaggingRunSummary) {
                lock(&self.finished).push(summary);
            }
        }

        let recorder = Arc::new(Recorder::default());
        let done = TaggingRunSummary::from(RunSummary {
            processed: 7,
            ..RunSummary::default()
        });
        drop(FinishGuard {
            running: Arc::new(AtomicBool::new(true)),
            listener: Arc::clone(&recorder) as Arc<dyn TaggingProgressListener>,
            summary: Some(done),
        });
        assert_eq!(lock(&recorder.finished).as_slice(), &[done]);
    }

    /// `on_finished` runs on the run thread and the contract invites a listener
    /// to call `start()` (or release its last session reference) from it. Both
    /// reach a `JoinHandle` for the thread they are standing on, and joining
    /// yourself aborts the process.
    #[test]
    fn a_thread_handed_its_own_handle_does_not_self_join() {
        let done = Arc::new(AtomicBool::new(false));
        let (tx, rx) = std::sync::mpsc::channel::<JoinHandle<()>>();

        let flag = Arc::clone(&done);
        let handle = std::thread::spawn(move || {
            let own = rx.recv().expect("handle");
            join_unless_current(own);
            flag.store(true, Ordering::SeqCst);
        });
        tx.send(handle).unwrap();

        for _ in 0..300 {
            if done.load(Ordering::SeqCst) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("the thread never got past join_unless_current — it self-joined");
    }

    #[test]
    fn a_handle_for_another_thread_is_still_joined() {
        let done = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&done);
        let handle = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(20));
            flag.store(true, Ordering::SeqCst);
        });
        join_unless_current(handle);
        assert!(done.load(Ordering::SeqCst), "the join did not wait");
    }

    #[test]
    fn a_bad_pack_directory_is_rejected_by_the_inspector() {
        let err = inspect_model_pack("/definitely/not/here".to_string()).unwrap_err();
        assert!(
            matches!(err, TaggingError::PackFileMissing { .. }),
            "{err:?}"
        );
    }
}
