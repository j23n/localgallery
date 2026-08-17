//! The UniFFI surface over [`gallery_ml::face::FaceEngine`].
//!
//! A sibling of [`crate::tagging`], built on the same [`crate::support`]
//! plumbing and obeying the same three rules: long work on a core-owned thread,
//! one run at a time, errors as typed enums. What is new here is that the face
//! pipeline has a second kind of call — *naming* — which writes to disk without
//! being a run.
//!
//! # Naming never takes the run lock
//!
//! [`FaceSession::name_cluster`] and friends refuse with
//! [`FaceError::AlreadyRunning`] while a run is in flight, rather than blocking
//! until it finishes or racing it. Blocking would freeze the app's main actor
//! behind a whole inference; racing would let the auto-tag pass and a user's
//! naming re-derive the same photo's sidecar from two different views of the
//! cluster table. Refusing is the honest third option: the UI disables its
//! Name/Ignore buttons for the duration, which it has to do anyway because a
//! run can re-partition the very clusters those buttons refer to.
//!
//! What they *do* take is the gate `start` takes ([`RunLock::try_mutate`]),
//! held for the whole call. Reading `is_running()` and then working would be
//! check-then-act, and a `start` landing in the gap is precisely the race the
//! refusal exists to prevent.
//!
//! # Naming is root-scoped
//!
//! The cache DB outlives any one library root, so a hash can carry queue rows
//! under a folder the app has since switched away from — outside its
//! security scope. A run takes its `root_prefix` from `start`; naming has no
//! run to inherit one from (a user can name a cluster with nothing scanning),
//! so every mutator takes its own. Paths outside land in
//! `SidecarWriteReport::skipped`.
//!
//! # Exemplars
//!
//! A cluster card shows a few face crops, and the pixels for them do *not*
//! cross this boundary — Swift crops from its own thumbnail pipeline using the
//! normalized rectangle in [`FaceRef`] (Phase 2 plan, "FFI additions"). Picking
//! *which* faces is done here, in Rust, because it depends on the quality score
//! the app has no other reason to know about. See [`exemplars`].

use std::sync::atomic::Ordering;
use std::sync::Arc;

use gallery_meta::MetaError;
use gallery_ml::cache::{FaceKey, FaceThumb};
use gallery_ml::engine::iso8601_utc_now;
use gallery_ml::face::{
    FaceEngine, FaceProgress, FaceRunOptions, FaceRunSummary as CoreFaceRunSummary,
    ReclusterSummary as CoreReclusterSummary, SidecarWritePlan,
};
use gallery_ml::{ClusterState as CoreClusterState, MlError};
use gallery_vfs::{StdVfs, VfsError};

use crate::support::{FinishGuard, RunLock, StartError};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Why a face call failed.
///
/// A flattening of [`MlError`] plus the one failure mode only this layer has,
/// [`FaceError::AlreadyRunning`]. The `detail` strings are for logs — the
/// *variant* is what callers switch on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum FaceError {
    /// The pack loaded but ships no face models.
    ///
    /// Not a broken pack: a tagging-only pack is valid, and the app's answer is
    /// to hide the faces controls.
    ModelsUnavailable,
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
    /// The inference backend refused a model.
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
    /// The person's name cannot be used as one.
    ///
    /// Its own variant rather than a [`FaceError::Sidecar`]: this is the one
    /// error a user can fix by typing something else, and the review UI shows
    /// it next to the field rather than as a failure banner.
    InvalidName {
        /// The name as typed.
        name: String,
        /// Why it was rejected; shown to the user.
        reason: String,
    },
    /// The cluster id is gone — a re-cluster pass rebuilt the partition under a
    /// list the UI was still holding.
    ClusterNotFound {
        /// The id that was not found.
        id: i64,
    },
    /// The merge would not produce a group: the two ids are the same.
    InvalidMerge {
        /// What was wrong; for logs only.
        detail: String,
    },
    /// The split selects nothing, or selects the whole cluster. Either leaves
    /// the partition where it was while creating an empty or duplicate group.
    InvalidSplit {
        /// What was wrong; for logs only.
        detail: String,
    },
    /// A face key is not one this boundary handed out.
    ///
    /// Distinct from a key whose face is *gone*, which a split counts and skips
    /// — the cache can move under a review screen the user left open.
    InvalidFaceKey {
        /// The key as supplied.
        key: String,
    },
    /// The run was cancelled.
    Cancelled,
    /// A run is in flight and this call refuses to share it. See the module
    /// docs.
    AlreadyRunning,
}

impl std::fmt::Display for FaceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FaceError::ModelsUnavailable => write!(f, "model pack ships no face models"),
            FaceError::PackFileMissing { path } => write!(f, "model pack file missing: {path}"),
            FaceError::PackHashMismatch {
                file,
                expected,
                actual,
            } => write!(f, "model pack {file}: expected {expected}, got {actual}"),
            FaceError::PackInvalid { detail } => write!(f, "invalid model pack: {detail}"),
            FaceError::Cache { detail } => write!(f, "cache db: {detail}"),
            FaceError::Inference { detail } => write!(f, "inference: {detail}"),
            FaceError::Io { path, detail } => write!(f, "io {path}: {detail}"),
            FaceError::Sidecar { detail } => write!(f, "sidecar: {detail}"),
            FaceError::InvalidName { name, reason } => write!(f, "invalid name {name:?}: {reason}"),
            FaceError::ClusterNotFound { id } => write!(f, "no such cluster: {id}"),
            FaceError::InvalidMerge { detail } => write!(f, "invalid merge: {detail}"),
            FaceError::InvalidSplit { detail } => write!(f, "invalid split: {detail}"),
            FaceError::InvalidFaceKey { key } => write!(f, "invalid face key: {key:?}"),
            FaceError::Cancelled => write!(f, "cancelled"),
            FaceError::AlreadyRunning => write!(f, "a face run is already in progress"),
        }
    }
}

impl std::error::Error for FaceError {}

impl From<MlError> for FaceError {
    fn from(e: MlError) -> Self {
        match e {
            MlError::PackFileMissing { path } => FaceError::PackFileMissing { path },
            MlError::PackHashMismatch {
                file,
                expected,
                actual,
            } => FaceError::PackHashMismatch {
                file,
                expected,
                actual,
            },
            MlError::PackInvalid { detail } => FaceError::PackInvalid { detail },
            MlError::FaceModelsUnavailable => FaceError::ModelsUnavailable,
            MlError::Cache { detail } => FaceError::Cache { detail },
            MlError::Inference { detail } => FaceError::Inference { detail },
            MlError::Preprocess { path, detail, .. } => FaceError::Io { path, detail },
            MlError::Vfs(v) => v.into(),
            MlError::Meta(m) => m.into(),
            MlError::ClusterNotFound { id } => FaceError::ClusterNotFound { id },
            MlError::InvalidMerge { detail } => FaceError::InvalidMerge { detail },
            MlError::InvalidSplit { detail } => FaceError::InvalidSplit { detail },
            MlError::InvalidFaceKey { key } => FaceError::InvalidFaceKey { key },
            MlError::Cancelled => FaceError::Cancelled,
        }
    }
}

impl From<VfsError> for FaceError {
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
        FaceError::Io { path, detail }
    }
}

impl From<MetaError> for FaceError {
    fn from(e: MetaError) -> Self {
        match e {
            MetaError::Vfs(v) => v.into(),
            // `normalize_person` rejects empty names and names carrying a `/`
            // through this variant, and that is the only way a user's typing
            // reaches the boundary.
            MetaError::InvalidTag { tag, reason } => FaceError::InvalidName { name: tag, reason },
            other => FaceError::Sidecar {
                detail: other.to_string(),
            },
        }
    }
}

/// Coarse classification of a run-level failure, carried on
/// [`FaceRunSummary::failure`].
///
/// Deliberately field-less: it exists so `onFinished` can say *why* a run
/// stopped without the summary record having to embed an error type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FaceFailure {
    /// The model pack is missing, corrupt, mis-hashed, or has no face models.
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
    /// [`FaceRunSummary::cancelled`], which is the normal cancel path).
    Cancelled,
}

impl From<&FaceError> for FaceFailure {
    fn from(e: &FaceError) -> Self {
        match e {
            FaceError::ModelsUnavailable
            | FaceError::PackFileMissing { .. }
            | FaceError::PackHashMismatch { .. }
            | FaceError::PackInvalid { .. } => FaceFailure::Pack,
            FaceError::Cache { .. }
            | FaceError::ClusterNotFound { .. }
            | FaceError::InvalidMerge { .. }
            | FaceError::InvalidSplit { .. }
            | FaceError::InvalidFaceKey { .. } => FaceFailure::CacheDb,
            FaceError::Inference { .. } => FaceFailure::Inference,
            FaceError::Io { .. } => FaceFailure::Io,
            FaceError::Sidecar { .. } | FaceError::InvalidName { .. } => FaceFailure::Sidecar,
            FaceError::Cancelled | FaceError::AlreadyRunning => FaceFailure::Cancelled,
        }
    }
}

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Face-queue counts. Cheap enough to poll.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FaceStats {
    /// Rows waiting to be processed (including stale and retryable failures).
    pub pending: u64,
    /// Rows scanned under the current face models.
    pub done: u64,
    /// Rows that failed and are out of retries.
    pub failed: u64,
    /// Rows skipped as an unsupported format.
    pub skipped: u64,
    /// Rows that turned out to contain at least one face.
    pub with_faces: u64,
}

/// What the face tables hold — the numbers behind Settings' faces status line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FaceLibraryStats {
    /// Stored face rows.
    pub faces: u64,
    /// Faces that belong to a cluster.
    pub assigned: u64,
    /// Clusters nobody has looked at.
    pub unlabeled_clusters: u64,
    /// Clusters a person's name is attached to.
    pub named_clusters: u64,
    /// Clusters the user dismissed.
    pub ignored_clusters: u64,
    /// Outstanding merge proposals. Computed and stored; applying one is not
    /// implemented (Phase 2 status), so this is advisory.
    pub merge_proposals: u64,
}

/// What one run did. Mirrors [`gallery_ml::face::FaceRunSummary`] with a
/// `failure` field for the run-level-error case, since `onFinished` fires
/// either way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FaceRunSummary {
    /// Photos carried to a terminal state.
    pub processed: u32,
    /// Photos that contain at least one face.
    pub photos_with_faces: u32,
    /// Faces detected and embedded across the run.
    pub faces_found: u32,
    /// Photos whose detections came from the cache.
    pub cache_hits: u32,
    /// Photos skipped as an unsupported format.
    pub skipped: u32,
    /// Photos that failed.
    pub failed: u32,
    /// Faces the post-run pass placed into a cluster.
    pub faces_assigned: u32,
    /// Clusters that pass created.
    pub clusters_created: u32,
    /// Faces that joined an already-**named** cluster and cleared the quality
    /// floor, so their photo's sidecar was written without anybody asking.
    pub faces_auto_tagged: u32,
    /// Sidecars the auto-tag pass actually rewrote.
    pub sidecars_written: u32,
    /// Sidecars the auto-tag pass could not write.
    pub sidecars_failed: u32,
    /// Whether the run stopped early because `cancel` was set.
    pub cancelled: bool,
    /// Set when the run aborted with a run-level error.
    pub failure: Option<FaceFailure>,
}

impl From<CoreFaceRunSummary> for FaceRunSummary {
    fn from(s: CoreFaceRunSummary) -> Self {
        FaceRunSummary {
            processed: s.processed as u32,
            photos_with_faces: s.photos_with_faces as u32,
            faces_found: s.faces_found as u32,
            cache_hits: s.cache_hits as u32,
            skipped: s.skipped as u32,
            failed: s.failed as u32,
            faces_assigned: s.faces_assigned as u32,
            clusters_created: s.clusters_created as u32,
            faces_auto_tagged: s.faces_auto_tagged as u32,
            sidecars_written: s.sidecars_written as u32,
            sidecars_failed: s.sidecars_failed as u32,
            cancelled: s.cancelled,
            failure: None,
        }
    }
}

impl FaceRunSummary {
    /// The summary a run reports when it never produced one of its own.
    fn failed_with(failure: FaceFailure, cancelled: bool) -> FaceRunSummary {
        FaceRunSummary {
            processed: 0,
            photos_with_faces: 0,
            faces_found: 0,
            cache_hits: 0,
            skipped: 0,
            failed: 0,
            faces_assigned: 0,
            clusters_created: 0,
            faces_auto_tagged: 0,
            sidecars_written: 0,
            sidecars_failed: 0,
            cancelled,
            failure: Some(failure),
        }
    }
}

/// Where a cluster stands with the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ClusterState {
    /// Nobody has named it — the review queue.
    Unlabeled,
    /// A person's name is attached; new faces joining it are auto-tagged.
    Named,
    /// The user said "not a person".
    Ignored,
}

impl From<CoreClusterState> for ClusterState {
    fn from(s: CoreClusterState) -> Self {
        match s {
            CoreClusterState::Unlabeled => ClusterState::Unlabeled,
            CoreClusterState::Named => ClusterState::Named,
            CoreClusterState::Ignored => ClusterState::Ignored,
        }
    }
}

/// One face, as a crop instruction.
///
/// The rectangle is normalized MWG-style — centre plus extent, 0…1, top-left
/// origin — because that is exactly what the app's `FaceRegion` already is, so
/// the existing cover-crop renderer takes one of these unchanged. Pixel corners
/// would have made every consumer re-derive the same division.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FaceRef {
    /// Absolute path of a photo containing this face. One of possibly several:
    /// detections are keyed by content hash and a library can hold the same
    /// bytes twice.
    pub path: String,
    /// This face's identity, opaque to the caller: hand it back to
    /// [`FaceSession::split_cluster`] to say which faces are moving.
    ///
    /// A rectangle would not do — two detections in one photo can overlap, so a
    /// selection made by geometry could move the wrong face.
    pub face_key: String,
    /// Rectangle centre, 0…1 of the oriented image width.
    pub center_x: f64,
    /// Rectangle centre, 0…1 of the oriented image height.
    pub center_y: f64,
    /// Rectangle width, 0…1.
    pub width: f64,
    /// Rectangle height, 0…1.
    pub height: f64,
    /// Composite quality (detection score × size × frontality). Faces below the
    /// pack's floor still appear here — they are real faces — they just never
    /// reach a sidecar on their own.
    pub quality: f32,
}

/// One cluster, as the review grid renders it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClusterSummary {
    /// Stable for a **named** cluster forever. An *unlabeled* cluster's id does
    /// not survive a `recluster()` — that pass produces a partition, not a
    /// diff — which is why naming a stale id answers
    /// [`FaceError::ClusterNotFound`] rather than guessing.
    pub id: i64,
    /// Member count.
    pub size: u32,
    /// Unlabeled / named / ignored.
    pub state: ClusterState,
    /// The person's name, when `state` is [`ClusterState::Named`].
    pub name: Option<String>,
    /// Up to [`MAX_EXEMPLARS`] faces to show on the card. See [`exemplars`].
    pub exemplars: Vec<FaceRef>,
}

/// What a naming operation did to the files on disk.
///
/// Photo paths throughout, not sidecar paths — the app indexes by photo. Only
/// the failures carry their paths: `written` is a count because the app's
/// response to it is "rescan", not "look at these files", and a 5 000-photo
/// rename would otherwise hand the main actor a 5 000-element array it drops.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SidecarWriteReport {
    /// Photos whose sidecar bytes changed.
    pub written: u32,
    /// Photos whose sidecar already said exactly this.
    pub unchanged: u32,
    /// Photos with nothing to say and no sidecar of ours to correct.
    pub skipped: u32,
    /// Photos that could not be written.
    pub failed: u32,
    /// The paths behind `failed`, so the app can name them in a log line.
    pub failed_paths: Vec<String>,
}

impl From<SidecarWritePlan> for SidecarWriteReport {
    fn from(plan: SidecarWritePlan) -> Self {
        SidecarWriteReport {
            written: plan.written.len() as u32,
            unchanged: plan.unchanged.len() as u32,
            skipped: plan.skipped.len() as u32,
            failed: plan.failed.len() as u32,
            failed_paths: plan.failed.into_iter().map(|f| f.path).collect(),
        }
    }
}

/// Two clusters the core thinks are the same person.
///
/// Ids only. The app already holds `clusters()` and joins locally, and a
/// library with a chain of similar groups would otherwise ship the same
/// exemplars several times over.
///
/// Advisory in both directions: nothing merges on its own, and a proposal is
/// only as fresh as the centroids it was computed from — a merge invalidates
/// every proposal touching either end, and the next run recomputes them.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct MergeProposal {
    /// The lower of the two cluster ids.
    pub a: i64,
    /// The higher.
    pub b: i64,
    /// Cosine similarity of the two centroids, 0…1.
    pub similarity: f32,
}

/// What one `split_cluster()` did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SplitResult {
    /// The cluster the selected faces moved into. Unlabeled and pinned.
    pub new_cluster_id: i64,
    /// Selected keys that named no face of the source cluster.
    ///
    /// Non-zero means the screen's selection was stale — a run deleted a face
    /// under it — which is worth a log line and is not a failure.
    pub ignored_keys: u32,
    /// The sidecars the split rewrote.
    pub report: SidecarWriteReport,
}

/// What one `recluster()` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ReclusterSummary {
    /// Unlabeled clusters that existed before the pass.
    pub clusters_before: u32,
    /// Unlabeled clusters after it.
    pub clusters_after: u32,
    /// Faces the pass re-partitioned.
    pub faces: u32,
    /// Merge proposals standing afterwards.
    pub proposals: u32,
}

impl From<CoreReclusterSummary> for ReclusterSummary {
    fn from(s: CoreReclusterSummary) -> Self {
        ReclusterSummary {
            clusters_before: s.clusters_before as u32,
            clusters_after: s.clusters_after as u32,
            faces: s.faces as u32,
            proposals: s.proposals as u32,
        }
    }
}

// ---------------------------------------------------------------------------
// Progress
// ---------------------------------------------------------------------------

/// Callbacks into the host app during a run.
///
/// Implementations are called from the core's worker threads and must not
/// block — on Swift the implementation hands off to the main actor and returns.
/// `on_progress` is already throttled in Rust (250 ms) and the path batches are
/// already batched, so no throttling is needed here.
#[uniffi::export(with_foreign)]
pub trait FaceProgressListener: Send + Sync {
    /// Throttled progress, plus one final call at the end of the run.
    fn on_progress(&self, done: u32, total: u32);

    /// Absolute paths that turned out to contain at least one face, batched.
    ///
    /// A *cache* change, not a disk change: nothing has been written yet.
    fn on_photos_with_faces(&self, paths: Vec<String>);

    /// Absolute paths whose sidecars the auto-tag pass rewrote, once, near the
    /// end of the run.
    ///
    /// This is the one that obliges the app to re-read sidecars.
    fn on_sidecars_written(&self, paths: Vec<String>);

    /// Exactly once per `start`, whether the run finished, was cancelled, or
    /// failed. Fires after the session has released its run lock.
    fn on_finished(&self, summary: FaceRunSummary);
}

/// Bridges [`FaceProgress`] (engine-side, `&[String]`) to
/// [`FaceProgressListener`] (FFI-side, `Vec<String>`), and swallows the engine's
/// `on_finished` — see [`crate::tagging`]'s notes on callback ordering.
struct ProgressAdapter {
    inner: Arc<dyn FaceProgressListener>,
}

impl FaceProgress for ProgressAdapter {
    fn on_progress(&self, done: usize, total: usize) {
        self.inner.on_progress(done as u32, total as u32);
    }

    fn on_photos_with_faces(&self, paths: &[String]) {
        self.inner.on_photos_with_faces(paths.to_vec());
    }

    fn on_sidecars_written(&self, paths: &[String]) {
        self.inner.on_sidecars_written(paths.to_vec());
    }

    fn on_finished(&self, _summary: &CoreFaceRunSummary) {}
}

// ---------------------------------------------------------------------------
// Exemplars
// ---------------------------------------------------------------------------

/// How many faces a cluster card gets.
///
/// Four: enough for "is this all the same person?" to be answerable at a
/// glance, few enough that the grid decodes four full-resolution images per
/// card and not forty.
pub const MAX_EXEMPLARS: usize = 4;

/// How many of a cluster's best faces are considered before the variety rule
/// below picks from them. Bounded so a 3 000-face cluster costs the same query
/// as a 6-face one.
const EXEMPLAR_POOL: usize = 16;

/// Pick the faces to show for a cluster: best quality first, **one photo each**
/// where possible.
///
/// The variety rule is what makes the card informative. Quality alone tends to
/// return four crops of one burst — the same face, four times — which answers
/// nothing about whether the cluster is coherent. Taking the best face from
/// each distinct photo first, then backfilling from the remainder, shows the
/// person across the library while still leading with the crop that looks best.
fn exemplars(thumbs: Vec<FaceThumb>) -> Vec<FaceRef> {
    let mut seen: Vec<&str> = Vec::with_capacity(MAX_EXEMPLARS);
    let mut chosen: Vec<&FaceThumb> = Vec::with_capacity(MAX_EXEMPLARS);
    // `thumbs` arrives sorted by quality descending, so first-wins is
    // best-wins in both passes.
    for thumb in &thumbs {
        if chosen.len() == MAX_EXEMPLARS {
            break;
        }
        if !seen.contains(&thumb.path.as_str()) {
            seen.push(&thumb.path);
            chosen.push(thumb);
        }
    }
    for thumb in &thumbs {
        if chosen.len() == MAX_EXEMPLARS {
            break;
        }
        if !chosen.iter().any(|c| std::ptr::eq(*c, thumb)) {
            chosen.push(thumb);
        }
    }
    chosen.into_iter().map(face_ref).collect()
}

/// One stored face as a normalized crop instruction.
///
/// A degenerate box — zero area, or a row written before the image dimensions
/// were known — becomes the whole frame rather than being dropped: the face is
/// really there, and an uncropped thumbnail is a better answer than a missing
/// card. (The sidecar writer makes the same call in the other direction: it
/// keeps the name and drops the region.)
fn face_ref(thumb: &FaceThumb) -> FaceRef {
    let face_key = encode_face_key(&thumb.content_hash, thumb.face_idx);
    let (w, h) = (f64::from(thumb.image_w), f64::from(thumb.image_h));
    let [x0, y0, x1, y1] = thumb.bbox.map(f64::from);
    if w <= 0.0 || h <= 0.0 || x1 <= x0 || y1 <= y0 {
        return FaceRef {
            path: thumb.path.clone(),
            face_key,
            center_x: 0.5,
            center_y: 0.5,
            width: 1.0,
            height: 1.0,
            quality: thumb.quality,
        };
    }
    let clamp = |v: f64| v.clamp(0.0, 1.0);
    FaceRef {
        path: thumb.path.clone(),
        face_key,
        center_x: clamp((x0 + x1) / 2.0 / w),
        center_y: clamp((y0 + y1) / 2.0 / h),
        width: clamp((x1 - x0) / w),
        height: clamp((y1 - y0) / h),
        quality: thumb.quality,
    }
}

// ---------------------------------------------------------------------------
// Face keys
// ---------------------------------------------------------------------------

/// `<content-hash-hex>:<detection index>` — the `faces` primary key as one
/// string, so the app can carry a face's identity around without learning what
/// it is made of.
fn encode_face_key(hash: &[u8; 32], face_idx: u32) -> String {
    format!("{}:{face_idx}", gallery_ml::pack::hex(hash))
}

/// Inverse of [`encode_face_key`].
///
/// Malformed is an error; *unknown* is not this function's business — a key
/// whose row has since been deleted parses fine and is skipped by the split
/// itself, because a review screen open across a run is an ordinary thing to
/// happen and not a reason to refuse the whole gesture.
fn decode_face_key(key: &str) -> Result<FaceKey, FaceError> {
    let invalid = || FaceError::InvalidFaceKey {
        key: key.to_string(),
    };
    let (hash_hex, idx) = key.split_once(':').ok_or_else(invalid)?;
    if hash_hex.len() != 64 {
        return Err(invalid());
    }
    let mut hash = [0u8; 32];
    for (byte, pair) in hash.iter_mut().zip(hash_hex.as_bytes().chunks_exact(2)) {
        let text = std::str::from_utf8(pair).map_err(|_| invalid())?;
        *byte = u8::from_str_radix(text, 16).map_err(|_| invalid())?;
    }
    Ok((hash, idx.parse::<u32>().map_err(|_| invalid())?))
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// A face session: one cache DB, one model pack, at most one run at a time.
///
/// Holding one open holds two ONNX sessions and a SQLite connection, so the app
/// keeps a single instance for as long as faces are available rather than
/// constructing one per run. It is a *sibling* of `TaggingSession`, not a
/// replacement: the two share the cache file and nothing else, so a tagging run
/// and a face run are independently resumable.
#[derive(uniffi::Object)]
pub struct FaceSession {
    engine: Arc<FaceEngine>,
    run: RunLock,
}

#[uniffi::export]
impl FaceSession {
    /// Open the cache DB, load and verify the pack's **face** models, and build
    /// both inference sessions.
    ///
    /// Fails with [`FaceError::ModelsUnavailable`] for a pack that ships no
    /// face models. That is the expected answer for a Phase 1 pack, not an
    /// error to report — the app uses it to decide whether the faces UI exists.
    #[uniffi::constructor]
    pub fn new(
        cache_db_path: String,
        model_pack_dir: String,
    ) -> Result<Arc<FaceSession>, FaceError> {
        let engine = FaceEngine::open(&cache_db_path, &model_pack_dir, Arc::new(StdVfs))?;
        Ok(Arc::new(FaceSession {
            engine: Arc::new(engine),
            run: RunLock::new(),
        }))
    }

    /// Add paths to the face queue; returns how many rows were newly inserted.
    ///
    /// Idempotent, which is what makes "enqueue the whole library every time"
    /// the correct call pattern.
    pub fn enqueue(&self, paths: Vec<String>) -> Result<u32, FaceError> {
        Ok(self.engine.enqueue(&paths)? as u32)
    }

    /// Start processing the face queue on a core-owned thread and return at
    /// once.
    ///
    /// `root_prefix`, when given, confines the run to queue rows under that
    /// directory — the cache DB outlives any one library root, and rows left
    /// over from a previous root must not be scanned (they are skipped, not
    /// failed, so nothing burns a retry).
    ///
    /// Fails with [`FaceError::AlreadyRunning`] if a run is in flight.
    pub fn start(
        &self,
        progress: Arc<dyn FaceProgressListener>,
        root_prefix: Option<String>,
    ) -> Result<(), FaceError> {
        let engine = Arc::clone(&self.engine);
        let listener = Arc::clone(&progress);

        let spawned = self.run.start("gallery-faces", move |cancel, running| {
            let reporter = Arc::clone(&listener);
            let mut guard =
                FinishGuard::new(running, move |summary| {
                    // `None` means the run thread unwound. The engine's guarantees
                    // say nothing about a panic, so it is reported as a failure
                    // rather than as a quiet zero-item success.
                    reporter.on_finished(summary.unwrap_or_else(|| {
                        FaceRunSummary::failed_with(FaceFailure::Inference, false)
                    }));
                });
            let adapter = ProgressAdapter {
                inner: Arc::clone(&listener),
            };
            // One timestamp for the whole run, for the same reason tagging
            // takes one: gallery-meta writes it verbatim, so a per-photo clock
            // read would make two identical runs produce different bytes.
            //
            // `full_recluster` stays off. It is O(n²) in the unlabeled face
            // count and the incremental pass already produced a usable
            // partition; the app asks for it explicitly through `recluster()`.
            let opts = FaceRunOptions {
                tagged_at: Some(iso8601_utc_now()),
                root_prefix,
                ..FaceRunOptions::default()
            };
            let outcome = engine.run_with_options(&adapter, &cancel, &opts);
            guard.summary = Some(match outcome {
                Ok(s) => FaceRunSummary::from(s),
                Err(e) => {
                    let err = FaceError::from(e);
                    FaceRunSummary::failed_with(
                        FaceFailure::from(&err),
                        cancel.load(Ordering::Acquire),
                    )
                }
            });
        });

        match spawned {
            Ok(()) => Ok(()),
            Err(StartError::AlreadyRunning) => Err(FaceError::AlreadyRunning),
            Err(StartError::Spawn(detail)) => Err(FaceError::Io {
                path: String::new(),
                detail: format!("could not spawn face thread: {detail}"),
            }),
        }
    }

    /// Ask the in-flight run to stop. Returns immediately; the run ends at the
    /// next photo (or the next face of a group shot) and reports through
    /// `on_finished` with `cancelled == true`.
    pub fn cancel(&self) {
        self.run.request_cancel();
    }

    /// Whether a run is in flight.
    pub fn is_running(&self) -> bool {
        self.run.is_running()
    }

    /// Face-queue counts.
    pub fn stats(&self) -> Result<FaceStats, FaceError> {
        let s = self.engine.stats()?;
        Ok(FaceStats {
            pending: s.pending,
            done: s.done,
            failed: s.failed,
            skipped: s.skipped,
            with_faces: s.tagged,
        })
    }

    /// Face-table counts.
    pub fn library_stats(&self) -> Result<FaceLibraryStats, FaceError> {
        let s = self.engine.library_stats()?;
        Ok(FaceLibraryStats {
            faces: s.faces,
            assigned: s.assigned,
            unlabeled_clusters: s.unlabeled_clusters,
            named_clusters: s.named_clusters,
            ignored_clusters: s.ignored_clusters,
            merge_proposals: s.merge_proposals,
        })
    }

    /// Forget every face-queue row (detections and clusters survive), so the
    /// next run re-scans the whole library. Refused mid-run — resetting the
    /// queue under a live run would have workers finishing rows that no longer
    /// exist.
    pub fn reset_queue(&self) -> Result<(), FaceError> {
        let _guard = self.mutating()?;
        self.engine.reset_queue()?;
        Ok(())
    }

    /// Every cluster, in id order, each with up to [`MAX_EXEMPLARS`] crops.
    ///
    /// Allowed during a run: it is a read, and a review screen that went blank
    /// for the length of a scan would be worse than one showing a partition
    /// that is about to grow.
    pub fn clusters(&self) -> Result<Vec<ClusterSummary>, FaceError> {
        let rows = self.engine.clusters()?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let thumbs = self
                .engine
                .cache()
                .cluster_face_thumbs(row.id, EXEMPLAR_POOL)?;
            out.push(ClusterSummary {
                id: row.id,
                size: row.size,
                state: row.state.into(),
                name: row.person_name,
                exemplars: exemplars(thumbs),
            });
        }
        Ok(out)
    }

    /// Every face of one cluster, best first.
    ///
    /// Unpaged: a cluster is a person, and the largest a person's cluster gets
    /// in a personal library is thousands of small records — cheaper to hand
    /// over once than to page across the boundary.
    pub fn cluster_faces(&self, cluster_id: i64) -> Result<Vec<FaceRef>, FaceError> {
        // Existence first. A re-cluster pass rebuilds the unlabeled partition,
        // so a screen holding an id from before it is holding a dead one — and
        // "no faces" is indistinguishable from "an empty cluster", which sends
        // the UI to a blank detail screen instead of back to the list.
        if self.engine.cache().cluster(cluster_id)?.is_none() {
            return Err(FaceError::ClusterNotFound { id: cluster_id });
        }
        Ok(self
            .engine
            .cache()
            .cluster_face_thumbs(cluster_id, 0)?
            .iter()
            .map(face_ref)
            .collect())
    }

    /// Attach a person's name to a cluster and write it into every affected
    /// photo's sidecar.
    ///
    /// The name is NFC-normalized, trimmed and whitespace-collapsed; an empty
    /// name or one containing `/` is [`FaceError::InvalidName`]. Casing is left
    /// exactly as typed.
    ///
    /// `root_prefix` confines the writes to the library root currently in
    /// scope; paths outside it are skipped. Refused while a run is in flight —
    /// see the module docs.
    pub fn name_cluster(
        &self,
        cluster_id: i64,
        name: String,
        root_prefix: Option<String>,
    ) -> Result<SidecarWriteReport, FaceError> {
        let _guard = self.mutating()?;
        Ok(self
            .engine
            .name_cluster(
                cluster_id,
                &name,
                Some(&iso8601_utc_now()),
                root_prefix.as_deref(),
            )?
            .into())
    }

    /// Take a cluster's name off and retract it from every affected sidecar.
    /// The cluster goes back to unlabeled, so the review queue shows it again.
    pub fn unname_cluster(
        &self,
        cluster_id: i64,
        root_prefix: Option<String>,
    ) -> Result<SidecarWriteReport, FaceError> {
        let _guard = self.mutating()?;
        Ok(self
            .engine
            .unname_cluster(cluster_id, Some(&iso8601_utc_now()), root_prefix.as_deref())?
            .into())
    }

    /// Dismiss a cluster ("not a person") and retract anything it had written.
    /// Kept rather than deleted, so its faces do not come back as a fresh
    /// cluster on the next pass.
    pub fn ignore_cluster(
        &self,
        cluster_id: i64,
        root_prefix: Option<String>,
    ) -> Result<SidecarWriteReport, FaceError> {
        let _guard = self.mutating()?;
        Ok(self
            .engine
            .ignore_cluster(cluster_id, Some(&iso8601_utc_now()), root_prefix.as_deref())?
            .into())
    }

    /// Rename a person everywhere: every cluster carrying `old`, and every
    /// sidecar those clusters reach.
    ///
    /// More than one cluster can carry a name, so this is not "rename cluster
    /// N". A name nobody carries produces an empty report rather than an error.
    pub fn rename_person(
        &self,
        old: String,
        new: String,
        root_prefix: Option<String>,
    ) -> Result<SidecarWriteReport, FaceError> {
        let _guard = self.mutating()?;
        Ok(self
            .engine
            .rename_person(&old, &new, Some(&iso8601_utc_now()), root_prefix.as_deref())?
            .into())
    }

    /// Fold one cluster into another: `into` survives, `from` disappears.
    ///
    /// Which of the two should survive is a presentation decision — the named
    /// one, or the bigger one, and the user has to be told whose name is being
    /// dropped — so the caller states it and the core carries no policy.
    ///
    /// If exactly one side is named, that name now reaches the absorbed faces'
    /// photos. If both are named differently, the absorbed name is retracted
    /// from photos where nothing else still claims it. The result is pinned, so
    /// the next `recluster()` leaves it alone.
    ///
    /// Refused while a run is in flight — see the module docs.
    pub fn merge_clusters(
        &self,
        into: i64,
        from: i64,
        root_prefix: Option<String>,
    ) -> Result<SidecarWriteReport, FaceError> {
        let _guard = self.mutating()?;
        Ok(self
            .engine
            .merge_clusters(into, from, Some(&iso8601_utc_now()), root_prefix.as_deref())?
            .into())
    }

    /// Move the named faces out of a cluster and into a new one.
    ///
    /// `face_keys` are `FaceRef.faceKey` values from `clusterFaces`. A key that
    /// no longer names a face of this cluster is counted in
    /// `SplitResult.ignoredKeys` and skipped; a key this boundary never handed
    /// out is [`FaceError::InvalidFaceKey`]. Selecting nothing, or selecting
    /// the whole cluster, is [`FaceError::InvalidSplit`].
    ///
    /// The faces that leave do **not** keep the cluster's name: the gesture
    /// means "this is not that person". Both groups end up pinned.
    pub fn split_cluster(
        &self,
        cluster_id: i64,
        face_keys: Vec<String>,
        root_prefix: Option<String>,
    ) -> Result<SplitResult, FaceError> {
        let _guard = self.mutating()?;
        let keys = face_keys
            .iter()
            .map(|k| decode_face_key(k))
            .collect::<Result<Vec<_>, _>>()?;
        let outcome = self.engine.split_cluster(
            cluster_id,
            &keys,
            Some(&iso8601_utc_now()),
            root_prefix.as_deref(),
        )?;
        Ok(SplitResult {
            new_cluster_id: outcome.new_cluster_id,
            ignored_keys: outcome.ignored_keys as u32,
            report: outcome.plan.into(),
        })
    }

    /// Pairs of clusters the core thinks are the same person, strongest first.
    ///
    /// A read, and open during a run for the same reason `clusters()` is: a
    /// review screen that emptied for the length of a scan would be worse than
    /// one showing a suggestion that is about to be recomputed. Proposals
    /// naming a cluster that no longer exists are dropped here.
    pub fn merge_proposals(&self) -> Result<Vec<MergeProposal>, FaceError> {
        Ok(self
            .engine
            .merge_proposals()?
            .into_iter()
            .map(|(a, b, similarity)| MergeProposal { a, b, similarity })
            .collect())
    }

    /// Forget one proposal — the user said these two are not the same person.
    ///
    /// Only until the next run recomputes proposals from the current centroids;
    /// what it buys is that a suggestion dismissed now does not come back on
    /// the same partition.
    pub fn dismiss_merge_proposal(&self, a: i64, b: i64) -> Result<(), FaceError> {
        let _guard = self.mutating()?;
        self.engine.cache().delete_merge_proposal(a, b)?;
        Ok(())
    }

    /// Rebuild the partition of every unlabeled face from scratch.
    ///
    /// Named, ignored and hand-edited (merged or split) clusters are untouched.
    /// Other unlabeled cluster **ids do not survive this call** — the pass
    /// produces a partition, not a diff — so the app must re-read `clusters()`
    /// afterwards.
    pub fn recluster(&self) -> Result<ReclusterSummary, FaceError> {
        let _guard = self.mutating()?;
        Ok(self.engine.recluster()?.into())
    }
}

impl FaceSession {
    /// The guard on every call that writes. Held for the whole call — see the
    /// module docs on why reading `is_running()` is not enough.
    fn mutating(&self) -> Result<std::sync::MutexGuard<'_, ()>, FaceError> {
        self.run.try_mutate().map_err(|_| FaceError::AlreadyRunning)
    }
}

impl Drop for FaceSession {
    fn drop(&mut self) {
        self.run.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thumb(path: &str, quality: f32) -> FaceThumb {
        FaceThumb {
            path: path.to_string(),
            content_hash: [7u8; 32],
            face_idx: 1,
            bbox: [10.0, 20.0, 30.0, 60.0],
            quality,
            image_w: 100,
            image_h: 200,
        }
    }

    #[test]
    fn ml_errors_flatten_onto_the_boundary_enum() {
        assert_eq!(
            FaceError::from(MlError::FaceModelsUnavailable),
            FaceError::ModelsUnavailable
        );
        assert_eq!(
            FaceError::from(MlError::ClusterNotFound { id: 7 }),
            FaceError::ClusterNotFound { id: 7 }
        );
        assert_eq!(
            FaceError::from(MlError::Vfs(VfsError::NotFound { path: "/x".into() })),
            FaceError::Io {
                path: "/x".into(),
                detail: VfsError::NotFound { path: "/x".into() }.to_string(),
            }
        );
    }

    /// A name the user typed has to come back as something the UI can put next
    /// to the field, not as a sidecar failure.
    #[test]
    fn a_rejected_name_is_its_own_variant() {
        let err = FaceError::from(MlError::Meta(MetaError::InvalidTag {
            tag: "People/Ada".into(),
            reason: "contains a path separator".into(),
        }));
        assert_eq!(
            err,
            FaceError::InvalidName {
                name: "People/Ada".into(),
                reason: "contains a path separator".into(),
            }
        );
        // Everything else from the sidecar layer still reads as a sidecar
        // problem.
        assert!(matches!(
            FaceError::from(MlError::Meta(MetaError::MalformedXml {
                detail: "boom".into()
            })),
            FaceError::Sidecar { .. }
        ));
    }

    #[test]
    fn failures_classify_by_family() {
        assert_eq!(
            FaceFailure::from(&FaceError::ModelsUnavailable),
            FaceFailure::Pack
        );
        assert_eq!(
            FaceFailure::from(&FaceError::ClusterNotFound { id: 1 }),
            FaceFailure::CacheDb
        );
    }

    /// The crop rectangle is what the app's existing cover-crop renderer
    /// consumes, so the pixel → MWG conversion is the contract, not an
    /// implementation detail.
    #[test]
    fn a_pixel_box_becomes_a_normalized_centre_and_extent() {
        let r = face_ref(&thumb("/a.jpg", 0.5));
        assert!((r.center_x - 0.2).abs() < 1e-9, "{r:?}");
        assert!((r.center_y - 0.2).abs() < 1e-9, "{r:?}");
        assert!((r.width - 0.2).abs() < 1e-9, "{r:?}");
        assert!((r.height - 0.2).abs() < 1e-9, "{r:?}");
    }

    #[test]
    fn a_degenerate_box_becomes_the_whole_frame_rather_than_disappearing() {
        let mut t = thumb("/a.jpg", 0.5);
        t.bbox = [10.0, 10.0, 10.0, 10.0];
        let r = face_ref(&t);
        assert_eq!(
            (r.center_x, r.center_y, r.width, r.height),
            (0.5, 0.5, 1.0, 1.0)
        );

        let mut unknown_size = thumb("/a.jpg", 0.5);
        unknown_size.image_w = 0;
        assert_eq!(face_ref(&unknown_size).width, 1.0);
    }

    /// Four crops of one burst answer nothing about whether a cluster is
    /// coherent. One per photo, best first, is the whole point of the card.
    #[test]
    fn exemplars_prefer_distinct_photos_over_the_next_best_face() {
        let picked = exemplars(vec![
            thumb("/a.jpg", 0.9),
            thumb("/a.jpg", 0.8),
            thumb("/b.jpg", 0.7),
            thumb("/c.jpg", 0.6),
        ]);
        assert_eq!(
            picked.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(),
            // Distinct photos first (best of each), then the leftover.
            vec!["/a.jpg", "/b.jpg", "/c.jpg", "/a.jpg"]
        );
    }

    #[test]
    fn exemplars_stop_at_the_cap() {
        let pool: Vec<FaceThumb> = (0..10)
            .map(|i| thumb(&format!("/{i}.jpg"), 1.0 - i as f32 / 10.0))
            .collect();
        let picked = exemplars(pool);
        assert_eq!(picked.len(), MAX_EXEMPLARS);
        assert_eq!(picked[0].path, "/0.jpg");
    }

    /// The key is the app's whole handle on a face, and a split acts on it —
    /// so the two halves have to be inverses, including the index that is not
    /// part of the hash.
    #[test]
    fn a_face_key_round_trips_through_the_boundary() {
        let mut hash = [0u8; 32];
        hash[0] = 0xde;
        hash[31] = 0x0f;
        let key = encode_face_key(&hash, 3);
        assert!(key.starts_with("de"), "{key}");
        assert_eq!(decode_face_key(&key).unwrap(), (hash, 3));
        assert_eq!(
            decode_face_key(&face_ref(&thumb("/a.jpg", 0.5)).face_key).unwrap(),
            ([7u8; 32], 1)
        );
    }

    #[test]
    fn a_malformed_face_key_is_refused_rather_than_guessed_at() {
        for bad in [
            "",
            "nope",
            "de:3",
            &format!("{}:x", "0".repeat(64)),
            &format!("{}:1", "0".repeat(63)),
            &format!("{}:1", "z".repeat(64)),
        ] {
            assert!(
                matches!(decode_face_key(bad), Err(FaceError::InvalidFaceKey { .. })),
                "{bad:?} was accepted"
            );
        }
    }

    #[test]
    fn a_cluster_with_one_face_yields_one_exemplar() {
        assert_eq!(exemplars(vec![thumb("/a.jpg", 0.4)]).len(), 1);
        assert!(exemplars(Vec::new()).is_empty());
    }
}
