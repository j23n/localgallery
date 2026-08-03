//! Model-pack v2: the on-disk format, its loader, and its hash verification.
//!
//! A pack is a directory. Swift downloads it (networking stays out of Rust,
//! overview §"Model packs") into
//! `Application Support/ModelPacks/<version>/` and hands the core the path;
//! the core verifies every declared SHA-256 *before* loading anything, because
//! "same pinned model weights, SHA-256-verified" is the first clause of the
//! determinism doctrine.
//!
//! ```text
//! <pack dir>/
//!   manifest.json        # the only file read by name
//!   image_encoder.onnx   # name comes from the manifest
//!   labels.json          # name comes from the manifest
//!   label_embeddings.f32 # optional; see below
//! ```
//!
//! # `manifest.json`
//!
//! ```json
//! {
//!   "schema": 1,
//!   "pack_version": "mobileclip-s2-2026.1",
//!   "model": {
//!     "file": "image_encoder.onnx",
//!     "sha256": "8f43…",
//!     "input_name": "image",
//!     "output_name": "embedding",
//!     "input_size": 224,
//!     "embedding_dim": 512,
//!     "mean": [0.48145466, 0.4578275, 0.40821073],
//!     "std":  [0.26862954, 0.26130258, 0.27577711],
//!     "resize_filter": "catmull_rom"
//!   },
//!   "labels": { "file": "labels.json", "sha256": "1c9a…" },
//!   "label_embeddings": { "file": "label_embeddings.f32", "sha256": "77b0…" },
//!   "hysteresis_epsilon": 0.02,
//!   "roots": {
//!     "Objects": { "threshold": 0.24, "max_tags": 8 },
//!     "Scenes":  { "threshold": 0.22, "max_tags": 6 }
//!   }
//! }
//! ```
//!
//! `roots` mirrors photo-tools' `taxonomy.CATEGORY_CONFIG` (`Objects` 8 tags,
//! `Scenes` 6) and its `THRESHOLD_MARGIN`: photo-tools gates at
//! `score ≥ per_tag_threshold × 1.10`, which is a multiplicative margin around
//! a per-tag bar. A zero-shot cosine has no per-tag bar, so the margin becomes
//! `hysteresis_epsilon`, applied *downward* and only to tags we already own —
//! see [`crate::tagger`] for why the direction matters.
//!
//! # `labels.json`
//!
//! ```json
//! {
//!   "schema": 1,
//!   "dim": 512,
//!   "labels": [
//!     { "path": "Objects/Animal/Mammal/Cat", "prompt": "a photo of a cat" },
//!     { "path": "Scenes/Nature/Beach", "prompt": "a photo of a beach",
//!       "threshold": 0.30 }
//!   ]
//! }
//! ```
//!
//! `path` is the full hierarchical taxonomy path; its first segment must have
//! an entry in `roots`. `prompt` is documentation only — the text tower does
//! not ship. `threshold` is an optional per-label override of the root
//! threshold, for labels that are noisier than their neighbours.
//!
//! Embeddings come from **one of two places**, checked in this order:
//!
//! 1. `manifest.label_embeddings` — a raw little-endian `f32` matrix,
//!    `labels.len() × dim`, row-major, rows in `labels` order. This is the
//!    production form: a 4 500-label × 512-dim pack is 9 MB of binary and
//!    ~110 MB of JSON.
//! 2. an inline `"embedding": [...]` on every label. Convenient for tiny packs
//!    and hand-editing; used by some tests.
//!
//! Mixing the two is rejected rather than silently resolved.
//!
//! # `faces` (schema 2, optional)
//!
//! Phase 2 added two more models to the same pack. They are **optional**: a
//! pack that ships only the tagging encoder is still a valid schema-2 pack, and
//! [`crate::face::FaceEngine`] simply refuses to open against it. That is the
//! whole reason the block is a separate `Option` rather than three more
//! required fields — an app on a tagging-only pack must keep tagging, not
//! start failing to load its models.
//!
//! ```json
//! "faces": {
//!   "detector": {
//!     "file": "face_detector.onnx", "sha256": "…",
//!     "input_name": "input.1", "input_size": 640,
//!     "score_outputs": ["443", "468", "493"],
//!     "bbox_outputs":  ["446", "471", "496"],
//!     "kps_outputs":   ["449", "474", "499"],
//!     "strides": [8, 16, 32], "anchors_per_cell": 2,
//!     "mean": [0.5, 0.5, 0.5], "std": [0.50196, 0.50196, 0.50196],
//!     "resize_filter": "bilinear",
//!     "score_threshold": 0.5, "nms_iou": 0.4,
//!     "max_faces": 32, "min_face_pixels": 24.0
//!   },
//!   "embedder": {
//!     "file": "face_embedder.onnx", "sha256": "…",
//!     "input_name": "input.1", "output_name": "516",
//!     "input_size": 112, "embedding_dim": 512,
//!     "mean": [0.5, 0.5, 0.5], "std": [0.5, 0.5, 0.5]
//!   },
//!   "clustering": { "join": 0.42, "auto": 0.55, "merge": 0.60,
//!                   "edge": 0.45, "min_quality": 0.25,
//!                   "cw_iterations": 20, "cw_seed": 20260803 }
//! }
//! ```
//!
//! The detector's ONNX file is loaded **lazily** ([`ModelPack::load_face_models`])
//! rather than at [`ModelPack::load`]: reading and SHA-256-ing 16 MB of face
//! weights is pure waste for the many callers that only ever tag.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{MlError, MlResult};
use crate::preprocess::{PreprocessConfig, ResizeFilter};

/// The newest manifest schema version this crate writes and understands.
pub const MANIFEST_SCHEMA: u32 = 2;
/// The oldest manifest schema version this crate still loads.
///
/// v1 packs (tagging only) stay loadable forever: they describe a complete,
/// correct tagging pipeline, and the only thing v2 adds is optional.
pub const MIN_MANIFEST_SCHEMA: u32 = 1;
/// The labels schema version this crate understands.
pub const LABELS_SCHEMA: u32 = 1;
/// The file every pack directory must contain.
pub const MANIFEST_FILE: &str = "manifest.json";

/// A file declared by the manifest, with the hash it must have.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackFile {
    /// Name relative to the pack directory. Must not contain a path separator.
    pub file: String,
    /// Lowercase hex SHA-256 of the file's bytes.
    pub sha256: String,
}

/// The encoder half of the manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelSpec {
    /// ONNX file name, relative to the pack directory.
    pub file: String,
    /// Lowercase hex SHA-256 of the ONNX file.
    pub sha256: String,
    /// Name of the graph's single image input.
    pub input_name: String,
    /// Name of the graph's embedding output.
    pub output_name: String,
    /// Square input edge in pixels.
    pub input_size: u32,
    /// Length of the embedding the encoder produces.
    pub embedding_dim: usize,
    /// Per-channel mean, `[0, 1]` space.
    pub mean: [f32; 3],
    /// Per-channel standard deviation.
    pub std: [f32; 3],
    /// Resize kernel the pack was built against.
    #[serde(default)]
    pub resize_filter: ResizeFilter,
}

/// Per-root gating, mirroring photo-tools' `CATEGORY_CONFIG`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RootConfig {
    /// Minimum cosine similarity for a tag under this root to be emitted.
    pub threshold: f32,
    /// At most this many tags are kept under this root, best-scoring first.
    pub max_tags: usize,
}

/// The face detector half of the manifest.
///
/// Shaped around SCRFD's output convention — a per-stride triple of
/// (score, bbox-distance, landmark-offset) tensors over an anchor grid — because
/// that is what both candidate detectors (SCRFD, YuNet) emit. Everything the
/// decode needs is declared rather than hard-coded, so swapping in a detector
/// with different strides or a different anchor count is a pack rebuild and not
/// a code change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FaceDetectorSpec {
    /// ONNX file name, relative to the pack directory.
    pub file: String,
    /// Lowercase hex SHA-256 of the ONNX file.
    pub sha256: String,
    /// Name of the graph's single image input.
    pub input_name: String,
    /// Square letterbox edge the detector is fed, in pixels.
    pub input_size: u32,
    /// Per-stride confidence outputs, in `strides` order.
    pub score_outputs: Vec<String>,
    /// Per-stride box-distance outputs, in `strides` order.
    pub bbox_outputs: Vec<String>,
    /// Per-stride landmark-offset outputs, in `strides` order.
    pub kps_outputs: Vec<String>,
    /// Feature-map strides, coarsest last.
    pub strides: Vec<u32>,
    /// Anchors per grid cell.
    pub anchors_per_cell: usize,
    /// Per-channel mean, `[0, 1]` space.
    pub mean: [f32; 3],
    /// Per-channel standard deviation.
    pub std: [f32; 3],
    /// Resize kernel used to build the letterbox.
    #[serde(default)]
    pub resize_filter: ResizeFilter,
    /// Minimum confidence for a candidate to survive.
    pub score_threshold: f32,
    /// IoU above which NMS discards the weaker of two boxes.
    pub nms_iou: f32,
    /// Hard cap on faces kept per photo, best-scoring first.
    pub max_faces: usize,
    /// Boxes whose shorter side is below this many *original-image* pixels are
    /// dropped: below roughly this size the aligned crop is pure upsampling and
    /// the embedding is noise that would pollute clustering.
    pub min_face_pixels: f32,
}

/// The face embedder half of the manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FaceEmbedderSpec {
    /// ONNX file name, relative to the pack directory.
    pub file: String,
    /// Lowercase hex SHA-256 of the ONNX file.
    pub sha256: String,
    /// Name of the graph's single image input.
    pub input_name: String,
    /// Name of the graph's embedding output.
    pub output_name: String,
    /// Square input edge; the alignment template is scaled to it.
    pub input_size: u32,
    /// Length of the embedding.
    pub embedding_dim: usize,
    /// Per-channel mean, `[0, 1]` space.
    pub mean: [f32; 3],
    /// Per-channel standard deviation.
    pub std: [f32; 3],
}

/// Cosine thresholds and the fixed knobs of the clustering pass.
///
/// All four thresholds are cosine similarities between L2-normalized ArcFace-
/// style embeddings, and they are **not** transferable to another embedder.
/// The defaults are sized against the published ArcFace operating point
/// (verification on LFW-grade pairs sits near 0.28 cosine) with two deliberate
/// margins on top:
///
/// * clustering asks ~N²/2 questions where verification asks one, so the
///   per-pair false-accept rate has to be orders of magnitude lower — hence
///   [`ClusteringConfig::join`] well above the verification point;
/// * [`ClusteringConfig::auto`] gates a *write to disk* (a `People/<Name>`
///   keyword in somebody's sidecar), so it is stricter again. A missed
///   auto-match costs one review action; a wrong one edits a file.
///
/// Measured on this pack's embedder over the reference photo set, distinct
/// identities score ≤ 0.09 and the same identity across the whole imaging-
/// pipeline perturbation range (rescale to 35%, JPEG q30, ±40% brightness)
/// stays ≥ 0.70. The thresholds sit in that gap with room on both sides.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ClusteringConfig {
    /// A face joins the nearest **unlabeled** cluster at or above this.
    pub join: f32,
    /// A face joins a **named** cluster — and so becomes auto-tagged — only at
    /// or above this, which is higher than [`ClusteringConfig::join`].
    pub auto: f32,
    /// Two cluster centroids at or above this produce a merge *proposal*.
    /// Never applied automatically.
    pub merge: f32,
    /// Edge threshold of the chinese-whispers graph in the full pass.
    pub edge: f32,
    /// Faces below this quality still cluster, but are excluded from
    /// auto-tagging and from cover-crop selection.
    pub min_quality: f32,
    /// Label-propagation rounds in the full pass. Convergence is typically
    /// under five; the cap is a bound, not a target.
    pub cw_iterations: u32,
    /// Seed for the fixed node permutation. Pinned in the manifest so two
    /// devices shuffle identically — the entire determinism claim of the full
    /// pass rests on this plus the sorted node order.
    pub cw_seed: u64,
}

impl Default for ClusteringConfig {
    fn default() -> Self {
        ClusteringConfig {
            join: 0.42,
            auto: 0.55,
            merge: 0.60,
            edge: 0.45,
            min_quality: 0.25,
            cw_iterations: 20,
            cw_seed: 20_260_803,
        }
    }
}

/// The optional face half of a schema-2 manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FaceSpec {
    /// Detector geometry and gating.
    pub detector: FaceDetectorSpec,
    /// Embedder geometry.
    pub embedder: FaceEmbedderSpec,
    /// Clustering thresholds; omitted means [`ClusteringConfig::default`].
    #[serde(default)]
    pub clustering: ClusteringConfig,
}

/// The verified bytes of the two face models.
#[derive(Debug, Clone)]
pub struct FaceModelBytes {
    /// Detector ONNX.
    pub detector: Vec<u8>,
    /// Embedder ONNX.
    pub embedder: Vec<u8>,
}

/// `manifest.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    /// Format version; between [`MIN_MANIFEST_SCHEMA`] and [`MANIFEST_SCHEMA`].
    pub schema: u32,
    /// Opaque pack identity, written into every sidecar sentinel and into
    /// `ml_work.model_pack`. Changing it marks existing rows stale.
    pub pack_version: String,
    /// The image encoder.
    pub model: ModelSpec,
    /// The label set.
    pub labels: PackFile,
    /// The binary label-embedding matrix, when embeddings are not inline.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label_embeddings: Option<PackFile>,
    /// How far below its threshold an already-owned tag is allowed to fall
    /// before it is retracted.
    pub hysteresis_epsilon: f32,
    /// Per-root thresholds and caps. Every label's root must appear here.
    pub roots: BTreeMap<String, RootConfig>,
    /// The face models, when this pack ships them. Schema 2 and up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub faces: Option<FaceSpec>,
}

/// One entry of `labels.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LabelEntry {
    /// Full hierarchical path, e.g. `Objects/Animal/Mammal/Cat`.
    pub path: String,
    /// The text prompt the embedding came from. Documentation only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    /// Overrides the root threshold for this label alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub threshold: Option<f32>,
    /// Inline embedding, for packs small enough not to want a binary blob.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedding: Option<Vec<f32>>,
}

/// `labels.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LabelsFile {
    /// Format version; must equal [`LABELS_SCHEMA`].
    pub schema: u32,
    /// Embedding length; must equal `model.embedding_dim`.
    pub dim: usize,
    /// The labels, in the same order as the binary embedding matrix's rows.
    pub labels: Vec<LabelEntry>,
}

/// One label, resolved and ready to score against.
#[derive(Debug, Clone, PartialEq)]
pub struct Label {
    /// Full hierarchical path.
    pub path: String,
    /// First path segment; the key into [`Manifest::roots`].
    pub root: String,
    /// The threshold that applies to this label.
    pub threshold: f32,
    /// L2-normalized embedding, `dim` long.
    pub embedding: Vec<f32>,
}

/// A verified, loaded model pack.
///
/// Holds the ONNX bytes rather than a session: the encoder backend decides how
/// many sessions to build (one per worker thread, in the `ort` backend's case),
/// and it should not have to re-read and re-verify the file to do it.
#[derive(Debug, Clone)]
pub struct ModelPack {
    /// The directory the pack was loaded from.
    pub dir: PathBuf,
    /// The parsed manifest.
    pub manifest: Manifest,
    /// The verified ONNX model bytes.
    pub model_bytes: Vec<u8>,
    /// Labels in manifest order, embeddings normalized.
    pub labels: Vec<Label>,
}

impl ModelPack {
    /// Read, verify and parse the pack in `dir`.
    ///
    /// Uses `std::fs` directly and not the [`gallery_vfs::Vfs`] seam: the pack
    /// lives in the app's own container, never behind a security scope or a
    /// SAF handle, and the encoder backend needs real bytes anyway.
    pub fn load(dir: impl AsRef<Path>) -> MlResult<ModelPack> {
        let dir = dir.as_ref().to_path_buf();
        let manifest_path = dir.join(MANIFEST_FILE);
        let manifest_bytes = read_file(&manifest_path)?;
        let manifest: Manifest =
            serde_json::from_slice(&manifest_bytes).map_err(|e| MlError::PackInvalid {
                detail: format!("{MANIFEST_FILE}: {e}"),
            })?;

        if !(MIN_MANIFEST_SCHEMA..=MANIFEST_SCHEMA).contains(&manifest.schema) {
            return Err(MlError::PackInvalid {
                detail: format!(
                    "manifest schema {} is not in {MIN_MANIFEST_SCHEMA}..={MANIFEST_SCHEMA}",
                    manifest.schema
                ),
            });
        }
        validate_manifest(&manifest)?;

        let model_bytes = read_verified(&dir, &manifest.model.file, &manifest.model.sha256)?;
        let labels_bytes = read_verified(&dir, &manifest.labels.file, &manifest.labels.sha256)?;
        let labels_file: LabelsFile =
            serde_json::from_slice(&labels_bytes).map_err(|e| MlError::PackInvalid {
                detail: format!("{}: {e}", manifest.labels.file),
            })?;
        let matrix = match &manifest.label_embeddings {
            Some(spec) => Some(read_verified(&dir, &spec.file, &spec.sha256)?),
            None => None,
        };

        let labels = resolve_labels(&manifest, &labels_file, matrix.as_deref())?;

        Ok(ModelPack {
            dir,
            manifest,
            model_bytes,
            labels,
        })
    }

    /// The preprocessing configuration this pack demands.
    pub fn preprocess_config(&self) -> PreprocessConfig {
        PreprocessConfig {
            input_size: self.manifest.model.input_size,
            mean: self.manifest.model.mean,
            std: self.manifest.model.std,
            filter: self.manifest.model.resize_filter,
        }
    }

    /// The identity written into sidecars and `ml_work.model_pack`.
    pub fn version(&self) -> &str {
        &self.manifest.pack_version
    }

    /// The face half of the manifest, if this pack has one.
    pub fn faces(&self) -> Option<&FaceSpec> {
        self.manifest.faces.as_ref()
    }

    /// Read and verify the two face ONNX files.
    ///
    /// Deliberately not done at [`ModelPack::load`]: a pack's face weights are
    /// 16 MB that a tagging-only caller would read, hash and throw away.
    pub fn load_face_models(&self) -> MlResult<FaceModelBytes> {
        let faces = self.faces().ok_or_else(|| MlError::PackInvalid {
            detail: "pack has no face models".into(),
        })?;
        Ok(FaceModelBytes {
            detector: read_verified(&self.dir, &faces.detector.file, &faces.detector.sha256)?,
            embedder: read_verified(&self.dir, &faces.embedder.file, &faces.embedder.sha256)?,
        })
    }

    /// The identity stamped into `face_work.model_pack`.
    ///
    /// Derived from the *face model hashes*, not from `pack_version`: adding
    /// face models to an existing pack must not re-tag the library, and a
    /// labels-only tagging rebuild must not re-detect every face. Two packs
    /// that ship the same two face models share face results, which is exactly
    /// the property `pack_version` cannot express.
    ///
    /// [`crate::face::ALIGN_VERSION`] and
    /// [`crate::preprocess::PREPROCESS_VERSION`] join it because both move
    /// pixels the content hash cannot see.
    pub fn face_pack_key(&self) -> Option<String> {
        let faces = self.faces()?;
        Some(format!(
            "{}+{}#p{}a{}",
            short_hash(&faces.detector.sha256),
            short_hash(&faces.embedder.sha256),
            crate::preprocess::PREPROCESS_VERSION,
            crate::face::ALIGN_VERSION,
        ))
    }

    /// The key embeddings are cached under.
    ///
    /// Keyed on the **encoder's** SHA-256, not on `pack_version`. An embedding
    /// is a function of exactly two things: the pixels (covered by the content
    /// hash) and the weights that consumed them. `pack_version` is a function
    /// of far more — thresholds, the label set, prompts — and keying on it made
    /// a labels-only pack rebuild re-run inference over the entire library for
    /// vectors it already had. Two packs that ship the same encoder now share a
    /// cache, and one that ships a different encoder cannot collide with it.
    ///
    /// [`crate::preprocess::PREPROCESS_VERSION`] joins it because a change to
    /// the decode/resize path produces a different vector from the same bytes,
    /// and the content hash cannot see that.
    ///
    /// Note that re-*scoring* is still driven by `pack_version`, through
    /// [`crate::CacheDb::mark_stale_for_pack`] — which is the point: a
    /// labels-only bump re-scores every photo from cached embeddings.
    pub fn embedding_model_key(&self) -> String {
        format!(
            "{}#p{}",
            self.manifest.model.sha256,
            crate::preprocess::PREPROCESS_VERSION
        )
    }
}

fn validate_manifest(m: &Manifest) -> MlResult<()> {
    let invalid = |detail: String| MlError::PackInvalid { detail };
    if m.pack_version.trim().is_empty() {
        return Err(invalid("pack_version is empty".into()));
    }
    if m.model.input_size == 0 {
        return Err(invalid("model.input_size is 0".into()));
    }
    if m.model.embedding_dim == 0 {
        return Err(invalid("model.embedding_dim is 0".into()));
    }
    if m.model.std.iter().any(|s| *s == 0.0 || !s.is_finite()) {
        return Err(invalid(format!(
            "model.std {:?} is not usable",
            m.model.std
        )));
    }
    if m.model.mean.iter().any(|v| !v.is_finite()) {
        return Err(invalid(format!(
            "model.mean {:?} is not usable",
            m.model.mean
        )));
    }
    if !(0.0..=1.0).contains(&m.hysteresis_epsilon) || !m.hysteresis_epsilon.is_finite() {
        return Err(invalid(format!(
            "hysteresis_epsilon {} is outside [0, 1]",
            m.hysteresis_epsilon
        )));
    }
    if m.roots.is_empty() {
        return Err(invalid("roots is empty".into()));
    }
    for (root, cfg) in &m.roots {
        if !cfg.threshold.is_finite() {
            return Err(invalid(format!("roots.{root}.threshold is not finite")));
        }
        if cfg.max_tags == 0 {
            return Err(invalid(format!("roots.{root}.max_tags is 0")));
        }
        // `People/*` belongs to face recognition (Phase 2) and gallery-meta
        // rejects it outright. Catching it here turns a per-photo write error
        // into a load-time one.
        if root == gallery_meta::tags::PEOPLE_ROOT {
            return Err(invalid(
                "roots may not contain People — face names are not the tagger's".into(),
            ));
        }
    }
    if let Some(faces) = &m.faces {
        if m.schema < 2 {
            return Err(invalid(format!(
                "manifest schema {} declares faces, which arrived in schema 2",
                m.schema
            )));
        }
        validate_faces(faces)?;
    }
    Ok(())
}

fn validate_faces(f: &FaceSpec) -> MlResult<()> {
    let invalid = |detail: String| MlError::PackInvalid { detail };
    let d = &f.detector;
    if d.strides.is_empty() {
        return Err(invalid("faces.detector.strides is empty".into()));
    }
    if d.strides.contains(&0) {
        return Err(invalid(format!(
            "faces.detector.strides {:?} contains 0",
            d.strides
        )));
    }
    // The three output lists index the same per-stride pyramid level. A short
    // list is a manifest that would silently decode the wrong tensor.
    for (name, list) in [
        ("score_outputs", &d.score_outputs),
        ("bbox_outputs", &d.bbox_outputs),
        ("kps_outputs", &d.kps_outputs),
    ] {
        if list.len() != d.strides.len() {
            return Err(invalid(format!(
                "faces.detector.{name} has {} entries, strides has {}",
                list.len(),
                d.strides.len()
            )));
        }
    }
    if d.anchors_per_cell == 0 {
        return Err(invalid("faces.detector.anchors_per_cell is 0".into()));
    }
    if d.input_size == 0 {
        return Err(invalid("faces.detector.input_size is 0".into()));
    }
    let coarsest = d.strides.iter().copied().max().unwrap_or(1);
    if !d.input_size.is_multiple_of(coarsest) {
        return Err(invalid(format!(
            "faces.detector.input_size {} is not a multiple of the coarsest stride",
            d.input_size
        )));
    }
    if d.max_faces == 0 {
        return Err(invalid("faces.detector.max_faces is 0".into()));
    }
    if !(0.0..=1.0).contains(&d.score_threshold) || !(0.0..=1.0).contains(&d.nms_iou) {
        return Err(invalid(format!(
            "faces.detector score_threshold {} / nms_iou {} outside [0, 1]",
            d.score_threshold, d.nms_iou
        )));
    }
    check_norm("faces.detector", &d.mean, &d.std)?;

    let e = &f.embedder;
    if e.input_size == 0 {
        return Err(invalid("faces.embedder.input_size is 0".into()));
    }
    if e.embedding_dim == 0 {
        return Err(invalid("faces.embedder.embedding_dim is 0".into()));
    }
    check_norm("faces.embedder", &e.mean, &e.std)?;

    let c = &f.clustering;
    for (name, v) in [
        ("join", c.join),
        ("auto", c.auto),
        ("merge", c.merge),
        ("edge", c.edge),
        ("min_quality", c.min_quality),
    ] {
        if !v.is_finite() || !(-1.0..=1.0).contains(&v) {
            return Err(invalid(format!(
                "faces.clustering.{name} = {v} is not a usable cosine threshold"
            )));
        }
    }
    // The one *relationship* between thresholds that carries meaning: joining a
    // named cluster writes to a file, so it must never be easier than joining
    // an anonymous one.
    if c.auto < c.join {
        return Err(invalid(format!(
            "faces.clustering.auto {} is below join {} — auto-tagging would be \
             looser than clustering",
            c.auto, c.join
        )));
    }
    if c.cw_iterations == 0 {
        return Err(invalid("faces.clustering.cw_iterations is 0".into()));
    }
    Ok(())
}

fn check_norm(what: &str, mean: &[f32; 3], std: &[f32; 3]) -> MlResult<()> {
    if std.iter().any(|s| *s == 0.0 || !s.is_finite()) {
        return Err(MlError::PackInvalid {
            detail: format!("{what}.std {std:?} is not usable"),
        });
    }
    if mean.iter().any(|v| !v.is_finite()) {
        return Err(MlError::PackInvalid {
            detail: format!("{what}.mean {mean:?} is not usable"),
        });
    }
    Ok(())
}

/// First 12 hex characters — enough to name a model in a cache key without
/// putting a 64-character hash in every row.
fn short_hash(hex: &str) -> &str {
    &hex[..hex.len().min(12)]
}

fn resolve_labels(
    manifest: &Manifest,
    file: &LabelsFile,
    matrix: Option<&[u8]>,
) -> MlResult<Vec<Label>> {
    let invalid = |detail: String| MlError::PackInvalid { detail };
    if file.schema != LABELS_SCHEMA {
        return Err(invalid(format!(
            "labels schema {} is not {LABELS_SCHEMA}",
            file.schema
        )));
    }
    let dim = file.dim;
    if dim != manifest.model.embedding_dim {
        return Err(invalid(format!(
            "labels dim {dim} != model.embedding_dim {}",
            manifest.model.embedding_dim
        )));
    }
    if file.labels.is_empty() {
        return Err(invalid("labels list is empty".into()));
    }

    let inline_count = file.labels.iter().filter(|l| l.embedding.is_some()).count();
    let rows: Option<Vec<Vec<f32>>> = match (matrix, inline_count) {
        (Some(_), n) if n > 0 => {
            return Err(invalid(
                "both label_embeddings and inline embeddings are present".into(),
            ))
        }
        (Some(bytes), _) => {
            let expected = file.labels.len() * dim * 4;
            if bytes.len() != expected {
                return Err(invalid(format!(
                    "label_embeddings is {} bytes, expected {expected} ({} labels × {dim} × 4)",
                    bytes.len(),
                    file.labels.len()
                )));
            }
            Some(
                bytes
                    .chunks_exact(dim * 4)
                    .map(|row| {
                        row.chunks_exact(4)
                            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                            .collect()
                    })
                    .collect(),
            )
        }
        (None, n) if n == file.labels.len() => None,
        (None, _) => {
            return Err(invalid(
                "no label_embeddings file and not every label carries an inline embedding".into(),
            ))
        }
    };

    let mut out = Vec::with_capacity(file.labels.len());
    let mut seen: BTreeMap<&str, usize> = BTreeMap::new();
    for (i, entry) in file.labels.iter().enumerate() {
        if let Some(prev) = seen.insert(entry.path.as_str(), i) {
            return Err(invalid(format!(
                "duplicate label path {:?} at rows {prev} and {i}",
                entry.path
            )));
        }
        let root = entry
            .path
            .split_once('/')
            .map(|(r, _)| r)
            .unwrap_or(entry.path.as_str())
            .to_string();
        let root_cfg = manifest.roots.get(&root).ok_or_else(|| {
            invalid(format!(
                "label {:?} has root {root:?}, which is not in roots",
                entry.path
            ))
        })?;

        let raw = match &rows {
            Some(rows) => rows[i].clone(),
            None => entry.embedding.clone().expect("checked above"),
        };
        if raw.len() != dim {
            return Err(invalid(format!(
                "label {:?} has {} components, expected {dim}",
                entry.path,
                raw.len()
            )));
        }
        let embedding = normalize(&raw).ok_or_else(|| {
            invalid(format!(
                "label {:?} has a zero or non-finite embedding",
                entry.path
            ))
        })?;

        let threshold = entry.threshold.unwrap_or(root_cfg.threshold);
        if !threshold.is_finite() {
            return Err(invalid(format!(
                "label {:?} has a non-finite threshold",
                entry.path
            )));
        }

        out.push(Label {
            path: entry.path.clone(),
            root,
            threshold,
            embedding,
        });
    }
    Ok(out)
}

/// L2-normalize, or `None` if the vector has no usable length.
///
/// Applied to label embeddings at load and to image embeddings at score time,
/// so [`crate::tagger`] can use a plain dot product and stay honest about
/// working in cosine space.
pub fn normalize(v: &[f32]) -> Option<Vec<f32>> {
    if v.iter().any(|x| !x.is_finite()) {
        return None;
    }
    let norm = v
        .iter()
        .map(|x| f64::from(*x) * f64::from(*x))
        .sum::<f64>()
        .sqrt();
    if norm <= f64::EPSILON {
        return None;
    }
    Some(v.iter().map(|x| (f64::from(*x) / norm) as f32).collect())
}

/// Lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// Lowercase hex of an arbitrary byte slice.
pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn read_file(path: &Path) -> MlResult<Vec<u8>> {
    std::fs::read(path).map_err(|_| MlError::PackFileMissing {
        path: path.display().to_string(),
    })
}

fn read_verified(dir: &Path, file: &str, expected: &str) -> MlResult<Vec<u8>> {
    if file.contains('/') || file.contains('\\') || file.is_empty() {
        return Err(MlError::PackInvalid {
            detail: format!("pack file name {file:?} must be a bare file name"),
        });
    }
    let bytes = read_file(&dir.join(file))?;
    let actual = sha256_hex(&bytes);
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(MlError::PackHashMismatch {
            file: file.to_string(),
            expected: expected.to_ascii_lowercase(),
            actual,
        });
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest_with(roots: BTreeMap<String, RootConfig>) -> Manifest {
        Manifest {
            schema: 1,
            pack_version: "test-1".into(),
            model: ModelSpec {
                file: "m.onnx".into(),
                sha256: "00".into(),
                input_name: "image".into(),
                output_name: "embedding".into(),
                input_size: 8,
                embedding_dim: 2,
                mean: [0.0, 0.0, 0.0],
                std: [1.0, 1.0, 1.0],
                resize_filter: ResizeFilter::CatmullRom,
            },
            labels: PackFile {
                file: "labels.json".into(),
                sha256: "00".into(),
            },
            label_embeddings: None,
            hysteresis_epsilon: 0.02,
            roots,
            faces: None,
        }
    }

    fn face_spec() -> FaceSpec {
        FaceSpec {
            detector: FaceDetectorSpec {
                file: "det.onnx".into(),
                sha256: "aa".into(),
                input_name: "input.1".into(),
                input_size: 640,
                score_outputs: vec!["s8".into(), "s16".into(), "s32".into()],
                bbox_outputs: vec!["b8".into(), "b16".into(), "b32".into()],
                kps_outputs: vec!["k8".into(), "k16".into(), "k32".into()],
                strides: vec![8, 16, 32],
                anchors_per_cell: 2,
                mean: [0.5; 3],
                std: [0.501_960_8; 3],
                resize_filter: ResizeFilter::Bilinear,
                score_threshold: 0.5,
                nms_iou: 0.4,
                max_faces: 32,
                min_face_pixels: 24.0,
            },
            embedder: FaceEmbedderSpec {
                file: "emb.onnx".into(),
                sha256: "bb".into(),
                input_name: "input.1".into(),
                output_name: "516".into(),
                input_size: 112,
                embedding_dim: 512,
                mean: [0.5; 3],
                std: [0.5; 3],
            },
            clustering: ClusteringConfig::default(),
        }
    }

    fn objects_root() -> BTreeMap<String, RootConfig> {
        BTreeMap::from([(
            "Objects".to_string(),
            RootConfig {
                threshold: 0.2,
                max_tags: 8,
            },
        )])
    }

    fn inline_labels(paths: &[&str]) -> LabelsFile {
        LabelsFile {
            schema: 1,
            dim: 2,
            labels: paths
                .iter()
                .map(|p| LabelEntry {
                    path: (*p).to_string(),
                    prompt: None,
                    threshold: None,
                    embedding: Some(vec![3.0, 4.0]),
                })
                .collect(),
        }
    }

    #[test]
    fn normalization_makes_unit_vectors() {
        let v = normalize(&[3.0, 4.0]).unwrap();
        assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
        assert!(normalize(&[0.0, 0.0]).is_none());
        assert!(normalize(&[f32::NAN, 1.0]).is_none());
    }

    #[test]
    fn inline_embeddings_resolve_and_normalize() {
        let m = manifest_with(objects_root());
        let labels = resolve_labels(&m, &inline_labels(&["Objects/Animal/Cat"]), None).unwrap();
        assert_eq!(labels.len(), 1);
        assert_eq!(labels[0].root, "Objects");
        assert_eq!(labels[0].threshold, 0.2);
        assert!((labels[0].embedding[0] - 0.6).abs() < 1e-6);
    }

    #[test]
    fn binary_matrix_rows_line_up_with_labels() {
        let m = manifest_with(objects_root());
        let mut file = inline_labels(&["Objects/A", "Objects/B"]);
        for l in &mut file.labels {
            l.embedding = None;
        }
        let mut bytes = Vec::new();
        for v in [1.0f32, 0.0, 0.0, 1.0] {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        let labels = resolve_labels(&m, &file, Some(&bytes)).unwrap();
        assert_eq!(labels[0].embedding, vec![1.0, 0.0]);
        assert_eq!(labels[1].embedding, vec![0.0, 1.0]);
    }

    #[test]
    fn mixing_inline_and_binary_embeddings_is_rejected() {
        let m = manifest_with(objects_root());
        let err = resolve_labels(&m, &inline_labels(&["Objects/A"]), Some(&[0u8; 8])).unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    #[test]
    fn a_short_matrix_is_rejected() {
        let m = manifest_with(objects_root());
        let mut file = inline_labels(&["Objects/A", "Objects/B"]);
        for l in &mut file.labels {
            l.embedding = None;
        }
        let err = resolve_labels(&m, &file, Some(&[0u8; 8])).unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    #[test]
    fn a_label_whose_root_has_no_config_is_rejected() {
        let m = manifest_with(objects_root());
        let err = resolve_labels(&m, &inline_labels(&["Scenes/Beach"]), None).unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    #[test]
    fn duplicate_label_paths_are_rejected() {
        let m = manifest_with(objects_root());
        let err =
            resolve_labels(&m, &inline_labels(&["Objects/A", "Objects/A"]), None).unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    #[test]
    fn a_people_root_is_rejected_at_load() {
        let roots = BTreeMap::from([(
            "People".to_string(),
            RootConfig {
                threshold: 0.2,
                max_tags: 4,
            },
        )]);
        let err = validate_manifest(&manifest_with(roots)).unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    #[test]
    fn a_nonsense_epsilon_is_rejected() {
        let mut m = manifest_with(objects_root());
        m.hysteresis_epsilon = 1.5;
        assert!(validate_manifest(&m).is_err());
        m.hysteresis_epsilon = -0.1;
        assert!(validate_manifest(&m).is_err());
        m.hysteresis_epsilon = 0.0;
        assert!(validate_manifest(&m).is_ok());
    }

    #[test]
    fn a_zero_std_is_rejected_before_it_divides_by_zero() {
        let mut m = manifest_with(objects_root());
        m.model.std = [1.0, 0.0, 1.0];
        assert!(validate_manifest(&m).is_err());
    }

    #[test]
    fn hash_verification_catches_a_flipped_byte() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("f.bin"), b"hello").unwrap();
        let good = sha256_hex(b"hello");
        assert_eq!(read_verified(dir.path(), "f.bin", &good).unwrap(), b"hello");
        let err = read_verified(dir.path(), "f.bin", &sha256_hex(b"hellO")).unwrap_err();
        assert!(matches!(err, MlError::PackHashMismatch { .. }), "{err:?}");
    }

    #[test]
    fn pack_file_names_may_not_escape_the_pack_dir() {
        let dir = tempfile::tempdir().unwrap();
        let err = read_verified(dir.path(), "../etc/passwd", "00").unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    // -----------------------------------------------------------------------
    // Model pack v2: the optional face block
    // -----------------------------------------------------------------------

    fn manifest_with_faces(faces: FaceSpec) -> Manifest {
        Manifest {
            schema: 2,
            faces: Some(faces),
            ..manifest_with(objects_root())
        }
    }

    /// The whole reason `faces` is an `Option`: a pack that ships no face
    /// models is a complete, valid pack.
    #[test]
    fn a_tagging_only_pack_is_valid_at_both_schemas() {
        assert!(validate_manifest(&manifest_with(objects_root())).is_ok());
        let v2 = Manifest {
            schema: 2,
            ..manifest_with(objects_root())
        };
        assert!(validate_manifest(&v2).is_ok());
        assert!(v2.faces.is_none());
    }

    #[test]
    fn a_v1_manifest_may_not_smuggle_in_face_models() {
        let m = Manifest {
            schema: 1,
            faces: Some(face_spec()),
            ..manifest_with(objects_root())
        };
        assert!(validate_manifest(&m).is_err());
    }

    #[test]
    fn a_well_formed_face_block_validates() {
        assert!(validate_manifest(&manifest_with_faces(face_spec())).is_ok());
    }

    /// The three output lists are parallel arrays indexed by pyramid level. A
    /// short one would decode the wrong tensor and produce plausible garbage.
    #[test]
    fn a_short_output_list_is_rejected() {
        for mutate in [
            |f: &mut FaceSpec| f.detector.score_outputs.pop(),
            |f: &mut FaceSpec| f.detector.bbox_outputs.pop(),
            |f: &mut FaceSpec| f.detector.kps_outputs.pop(),
        ] {
            let mut spec = face_spec();
            mutate(&mut spec);
            assert!(
                validate_manifest(&manifest_with_faces(spec)).is_err(),
                "a truncated output list was accepted"
            );
        }
    }

    #[test]
    fn an_input_size_the_strides_do_not_divide_is_rejected() {
        let mut spec = face_spec();
        spec.detector.input_size = 100;
        assert!(validate_manifest(&manifest_with_faces(spec)).is_err());
    }

    #[test]
    fn nonsense_detector_geometry_is_rejected() {
        for mutate in [
            |f: &mut FaceSpec| f.detector.strides.clear(),
            |f: &mut FaceSpec| f.detector.strides = vec![0, 16, 32],
            |f: &mut FaceSpec| f.detector.anchors_per_cell = 0,
            |f: &mut FaceSpec| f.detector.input_size = 0,
            |f: &mut FaceSpec| f.detector.max_faces = 0,
            |f: &mut FaceSpec| f.detector.score_threshold = 1.5,
            |f: &mut FaceSpec| f.detector.nms_iou = -0.1,
            |f: &mut FaceSpec| f.detector.std = [1.0, 0.0, 1.0],
            |f: &mut FaceSpec| f.embedder.input_size = 0,
            |f: &mut FaceSpec| f.embedder.embedding_dim = 0,
            |f: &mut FaceSpec| f.embedder.std = [0.0; 3],
        ] {
            let mut spec = face_spec();
            mutate(&mut spec);
            assert!(validate_manifest(&manifest_with_faces(spec)).is_err());
        }
    }

    /// Auto-tagging writes to somebody's sidecar. It must never be an easier
    /// bar to clear than plain clustering.
    #[test]
    fn an_auto_threshold_below_the_join_threshold_is_rejected() {
        let mut spec = face_spec();
        spec.clustering.auto = spec.clustering.join - 0.01;
        let err = validate_manifest(&manifest_with_faces(spec)).unwrap_err();
        assert!(matches!(err, MlError::PackInvalid { .. }), "{err:?}");
    }

    #[test]
    fn a_threshold_outside_cosine_range_is_rejected() {
        let mut spec = face_spec();
        spec.clustering.merge = 1.5;
        assert!(validate_manifest(&manifest_with_faces(spec)).is_err());
        let mut spec = face_spec();
        spec.clustering.cw_iterations = 0;
        assert!(validate_manifest(&manifest_with_faces(spec)).is_err());
    }

    /// Omitting `clustering` must give the documented defaults rather than
    /// zeroes, which would cluster the entire library into one person.
    #[test]
    fn an_omitted_clustering_block_falls_back_to_the_defaults() {
        let json = serde_json::json!({
            "detector": serde_json::to_value(face_spec().detector).unwrap(),
            "embedder": serde_json::to_value(face_spec().embedder).unwrap(),
        });
        let spec: FaceSpec = serde_json::from_value(json).unwrap();
        assert_eq!(spec.clustering, ClusteringConfig::default());
        assert!(spec.clustering.auto > spec.clustering.join);
    }

    /// A schema-2 manifest with no `faces` key must round-trip *without* one,
    /// so adding face support does not rewrite every existing pack file.
    #[test]
    fn the_faces_key_is_omitted_when_absent() {
        let bytes = serde_json::to_vec(&manifest_with(objects_root())).unwrap();
        assert!(!String::from_utf8(bytes.clone()).unwrap().contains("faces"));
        let back: Manifest = serde_json::from_slice(&bytes).unwrap();
        assert!(back.faces.is_none());
    }

    #[test]
    fn the_face_pack_key_tracks_the_models_not_the_pack_version() {
        let dir = tempfile::tempdir().unwrap();
        let base = ModelPack {
            dir: dir.path().to_path_buf(),
            manifest: manifest_with_faces(face_spec()),
            model_bytes: Vec::new(),
            labels: Vec::new(),
        };
        let key = base.face_pack_key().unwrap();

        // A labels-only tagging rebuild changes `pack_version` and must not
        // invalidate a single face row.
        let mut renamed = base.clone();
        renamed.manifest.pack_version = "something-else".into();
        assert_eq!(renamed.face_pack_key().unwrap(), key);

        // A different detector must.
        let mut swapped = base.clone();
        swapped.manifest.faces.as_mut().unwrap().detector.sha256 = "ffffffffffffff".into();
        assert_ne!(swapped.face_pack_key().unwrap(), key);

        // And a tagging-only pack has no key at all.
        let mut plain = base.clone();
        plain.manifest.faces = None;
        assert!(plain.face_pack_key().is_none());
        assert!(plain.load_face_models().is_err());
    }

    #[test]
    fn face_model_bytes_are_hash_verified_like_everything_else() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("det.onnx"), b"detector").unwrap();
        std::fs::write(dir.path().join("emb.onnx"), b"embedder").unwrap();
        let mut spec = face_spec();
        spec.detector.sha256 = sha256_hex(b"detector");
        spec.embedder.sha256 = sha256_hex(b"embedder");
        let pack = ModelPack {
            dir: dir.path().to_path_buf(),
            manifest: manifest_with_faces(spec),
            model_bytes: Vec::new(),
            labels: Vec::new(),
        };
        let bytes = pack.load_face_models().unwrap();
        assert_eq!(bytes.detector, b"detector");
        assert_eq!(bytes.embedder, b"embedder");

        std::fs::write(dir.path().join("emb.onnx"), b"tampered").unwrap();
        assert!(matches!(
            pack.load_face_models().unwrap_err(),
            MlError::PackHashMismatch { .. }
        ));
    }

    #[test]
    fn a_missing_pack_dir_names_the_file_it_wanted() {
        let err = ModelPack::load("/definitely/not/here").unwrap_err();
        assert!(matches!(err, MlError::PackFileMissing { .. }), "{err:?}");
    }
}
