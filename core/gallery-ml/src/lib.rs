//! On-device photo tagging for the gallery core.
//!
//! Takes a list of image paths and, for each one, writes photo-tools-taxonomy
//! tags into its `.xmp` sidecar. Everything that makes that non-trivial is
//! about *agreement*: two devices looking at the same bytes must reach the
//! same tags, and a second run over an unchanged library must write nothing at
//! all.
//!
//! ```text
//!  paths ──▶ TaggingEngine::enqueue ──▶ CacheDb (ml_work)
//!                                          │
//!               TaggingEngine::run ────────┘
//!                     │
//!            content hash (sha2, streamed)
//!                     │
//!            embeddings cache ──hit──▶ (skip everything below)
//!                     │ miss
//!            preprocess (pinned decode/orient/resize)
//!                     │
//!            ImageEncoder (ort, CPU EP, 1 intra-op thread)
//!                     │
//!            ZeroShotTagger (cosine + per-root caps + hysteresis)
//!                     │
//!            gallery_meta::write_tags ──▶ IMG_1234.jpg.xmp
//! ```
//!
//! # Module map
//!
//! * [`cache`] — `gallery-cache.sqlite`: work queues, embeddings, faces,
//!   clusters.
//! * [`preprocess`] — the pinned decode → orient → resize → tensor path.
//! * [`encoder`] — the [`encoder::ImageEncoder`] /
//!   [`encoder::MultiOutputModel`] seams and the `ort` backend.
//! * [`pack`] — model-pack v2: manifest, labels, optional face models,
//!   SHA-256 verification.
//! * [`tagger`] — cosine scoring, per-root caps, hysteresis.
//! * [`engine`] — the tagging orchestrator and its thread pool.
//! * [`face`] — detection, alignment, embedding, quality and clustering, plus
//!   [`face::FaceEngine`].
//! * [`hash`] — streamed content hashing.
//!
//! # What this crate is not
//!
//! * Not an FFI surface. No UniFFI attributes anywhere; `gallery-ffi` wraps
//!   [`TaggingEngine`] and [`face::FaceEngine`].
//! * Not a video pipeline. photo-tools samples frames with ffmpeg; there is no
//!   ffmpeg on iOS, and there is no determinism story for a platform decoder.
//! * Not a HEIC decoder — see [`preprocess`] for the gap and why it is open.
//! * Not the owner of the sidecar format. [`face::naming`] decides *what* a
//!   named cluster means for a photo; `gallery-meta` decides how that lands in
//!   the XMP and what it is allowed to touch there.
//!
//! ```no_run
//! use std::sync::atomic::AtomicBool;
//! use std::sync::Arc;
//! use gallery_ml::{NoProgress, TaggingEngine};
//! use gallery_vfs::StdVfs;
//!
//! let engine = TaggingEngine::open(
//!     "/tmp/gallery-cache.sqlite",
//!     "/tmp/ModelPacks/mobileclip-s2-2026.1",
//!     Arc::new(StdVfs),
//! )?;
//! engine.enqueue(&["/photos/IMG_1234.jpg".to_string()])?;
//! let summary = engine.run(&NoProgress, &AtomicBool::new(false))?;
//! assert_eq!(summary.failed, 0);
//! # Ok::<(), gallery_ml::MlError>(())
//! ```

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod cache;
pub mod encoder;
pub mod engine;
pub mod error;
pub mod face;
pub mod hash;
pub mod pack;
pub mod preprocess;
pub mod tagger;

pub use cache::{
    CacheDb, ClusterRow, ClusterState, FaceLibraryStats, NamedFace, Stats, StoredFace, WorkItem,
    WorkState,
};
pub use encoder::{ImageEncoder, ModelOutput, MultiOutputModel};
pub use engine::{NoProgress, RunOptions, RunSummary, TaggingEngine, TaggingProgress, MAX_WORKERS};
pub use error::{ErrorCode, MlError, MlResult};
pub use face::{
    Detection, FaceEngine, FaceProgress, FaceRunOptions, FaceRunSummary, FailedWrite,
    NoFaceProgress, ReclusterSummary, SidecarWritePlan, ALIGN_VERSION,
};
pub use pack::{ClusteringConfig, FaceSpec, Manifest, ModelPack, RootConfig};
pub use preprocess::{PreprocessConfig, ResizeFilter, Tensor, PREPROCESS_VERSION};
pub use tagger::{ScoredTag, ZeroShotTagger};
