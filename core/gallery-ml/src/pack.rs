//! Model-pack v1: the on-disk format, its loader, and its hash verification.
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

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{MlError, MlResult};
use crate::preprocess::{PreprocessConfig, ResizeFilter};

/// The manifest schema version this crate understands.
pub const MANIFEST_SCHEMA: u32 = 1;
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

/// `manifest.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    /// Format version; must equal [`MANIFEST_SCHEMA`].
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

        if manifest.schema != MANIFEST_SCHEMA {
            return Err(MlError::PackInvalid {
                detail: format!(
                    "manifest schema {} is not {MANIFEST_SCHEMA}",
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
    Ok(())
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

    #[test]
    fn a_missing_pack_dir_names_the_file_it_wanted() {
        let err = ModelPack::load("/definitely/not/here").unwrap_err();
        assert!(matches!(err, MlError::PackFileMissing { .. }), "{err:?}");
    }
}
