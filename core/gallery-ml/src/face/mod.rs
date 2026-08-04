//! Face detection, alignment, embedding and clustering.
//!
//! ```text
//!  paths ──▶ FaceEngine::enqueue ──▶ CacheDb (face_work)
//!                                        │
//!             FaceEngine::run ───────────┘
//!                   │
//!          content hash (sha2, streamed)
//!                   │
//!          face_scans cache ──hit──▶ (skip everything below)
//!                   │ miss
//!          preprocess::decode_oriented   (pinned decode, once)
//!                   │
//!          detect  — SCRFD head over a 640 letterbox, fixed NMS
//!                   │
//!          align   — 5-point Umeyama onto the ArcFace 112×112 template
//!                   │
//!          embed   — ArcFace-style tower, 512-d, L2-normalized
//!                   │
//!          quality — score × size × frontality
//!                   │
//!          CacheDb::put_faces   (faces / face_scans)
//!                   │
//!          cluster — incremental assign, then an optional full pass
//! ```
//!
//! Naming a cluster is the one thing that leaves the cache: [`naming`] turns it
//! into `People/<Name>` keywords and `XMP-mwg-rs:RegionInfo` regions through
//! `gallery_meta::write_faces`. Everything *else* here stops at the cache DB,
//! which is the standing decision that unlabeled clusters and embeddings are
//! per-device derived data while only named results travel.
//!
//! # What this module does not do
//!
//! It does not decide *who* anyone is. A cluster is a set of faces that look
//! alike; turning one into a person is a human action, by design (Phase 2 plan,
//! non-goals). What the core does do on its own is extend an identity a human
//! already gave it — see [`naming`]'s auto-tagging section.
//!
//! # Model choice
//!
//! **SCRFD-500M** (detector, 2.5 MB) and **w600k_mbf** (embedder, 13 MB), both
//! from insightface's `buffalo_sc` release bundle. The alternatives considered
//! were YuNet (OpenCV Zoo) for detection and SFace for recognition; the
//! deciding factor was that SCRFD and w600k_mbf are *designed against each
//! other*. SCRFD emits its five landmarks in the exact order and convention
//! w600k_mbf's training crops were aligned with, so the riskiest part of this
//! pipeline — the alignment contract — has no conversion step in it at all.
//! YuNet emits the two eyes in the opposite order, which is a silent, plausible
//! and very expensive bug waiting to be written. They also ship as a single
//! GitHub release asset containing exactly these two files, which makes the
//! whole pack reproducible from one pinned SHA-256.
//!
//! `scripts/build_model_pack/README.md` records the full comparison, including
//! the licensing note: the insightface pretrained models are published for
//! non-commercial research use, and the manifest's model-swap story is what
//! keeps the permissively-licensed pairing (YuNet + SFace) a pack rebuild
//! rather than a rewrite.

pub mod align;
pub mod cluster;
pub mod detect;
pub mod engine;
pub mod naming;
pub mod quality;

pub use align::{align_crop, align_tensor, umeyama, ALIGN_VERSION, ARCFACE_TEMPLATE};
pub use cluster::{
    assign, centroid, chinese_whispers, cosine, merge_proposals, Assignment, FaceVec,
};
pub use detect::{Detection, FaceDetector};
pub use engine::{
    FaceEngine, FaceProgress, FaceRunOptions, FaceRunSummary, NoFaceProgress, ReclusterSummary,
};
pub use naming::{FailedWrite, SidecarWritePlan, SyncScope, SIDECAR_RETRIES};
pub use quality::quality;
