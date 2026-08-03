//! Zero-shot scoring: image embedding → taxonomy tags.
//!
//! The text tower does not ship. `labels.json` carries a precomputed prompt
//! embedding per taxonomy leaf, so scoring is one dot product per label
//! against an L2-normalized image embedding — i.e. cosine similarity — and the
//! whole label set is a `dim × labels` matrix multiply the CPU eats for
//! breakfast.
//!
//! # Gating, and why it mirrors photo-tools
//!
//! photo-tools' RAM++ tagger gates at `score ≥ per_tag_threshold × 1.10` and
//! then caps per category (`Objects` 8, `Scenes` 6, `taxonomy.py`). The shapes
//! carry over exactly: per-label threshold (defaulting to the root's),
//! per-root cap, best-scoring first. What does not carry over is the
//! multiplicative margin — RAM++ has a trained per-class bar to scale, a
//! zero-shot cosine does not.
//!
//! # Hysteresis
//!
//! The margin instead becomes a *retention* band, and this is the mechanism
//! that makes the determinism doctrine survive contact with floating point:
//!
//! * a tag we do not currently own is emitted at `score ≥ T`;
//! * a tag the sidecar says we already own is retained down to `score ≥ T − ε`.
//!
//! Without it, a photo scoring 0.2401 against a 0.2400 threshold would gain
//! and lose its tag on alternate runs as SIMD kernels, ORT versions or
//! architectures nudge the last mantissa bits — and every flip is a sidecar
//! rewrite, an mtime bump, and a sidecar-sync storm in the app. ε is sized in
//! the manifest (`hysteresis_epsilon`) to be orders of magnitude larger than
//! float drift and much smaller than a real content change.
//!
//! The band is deliberately one-directional. A symmetric band (emit at
//! `T + ε`, retract at `T − ε`) would also stop flapping, but it would make the
//! *first* run on a photo stricter than every subsequent one, so two devices
//! that first tagged a photo under different pack versions could disagree
//! forever. Emitting at exactly `T` keeps first-run behaviour identical
//! everywhere; the band only ever says "keep what you already decided".

use std::collections::BTreeSet;

use crate::pack::{normalize, ModelPack};

/// One label that cleared its bar.
#[derive(Debug, Clone, PartialEq)]
pub struct ScoredTag {
    /// Full hierarchical path.
    pub path: String,
    /// Cosine similarity against the image embedding.
    pub score: f32,
    /// The threshold this label had to clear.
    pub threshold: f32,
    /// True when the label only survived because it was already owned and the
    /// hysteresis band caught it.
    pub retained: bool,
}

/// Scores an image embedding against a pack's label set.
#[derive(Debug)]
pub struct ZeroShotTagger<'a> {
    pack: &'a ModelPack,
}

impl<'a> ZeroShotTagger<'a> {
    /// Borrow `pack` for scoring.
    pub fn new(pack: &'a ModelPack) -> ZeroShotTagger<'a> {
        ZeroShotTagger { pack }
    }

    /// Tags for `image_embedding`, given the tags the core already owns on
    /// this photo (from the sidecar's core sentinel).
    ///
    /// Returns paths sorted lexicographically — the write path sorts anyway
    /// (`gallery_meta::tags::normalize_tag_list`), and sorting here means the
    /// engine's own comparisons and logs are order-stable too.
    pub fn tags(&self, image_embedding: &[f32], owned: &BTreeSet<String>) -> Vec<String> {
        let mut paths: Vec<String> = self
            .scored(image_embedding, owned)
            .into_iter()
            .map(|t| t.path)
            .collect();
        paths.sort();
        paths
    }

    /// The full scored result, for diagnostics and tests.
    ///
    /// An embedding that will not normalize (all zeros, a NaN) yields no tags
    /// rather than an error: a degenerate embedding is a fact about one photo,
    /// and it must not take a 20k-photo run down.
    pub fn scored(&self, image_embedding: &[f32], owned: &BTreeSet<String>) -> Vec<ScoredTag> {
        let Some(image) = normalize(image_embedding) else {
            return Vec::new();
        };
        if image.len() != self.pack.manifest.model.embedding_dim {
            return Vec::new();
        }
        let epsilon = self.pack.manifest.hysteresis_epsilon;

        // Group survivors by root so the per-root cap can be applied.
        let mut by_root: std::collections::BTreeMap<&str, Vec<ScoredTag>> = Default::default();
        for label in &self.pack.labels {
            let score = dot(&image, &label.embedding);
            if !score.is_finite() {
                continue;
            }
            let is_owned = owned.contains(&label.path);
            let bar = if is_owned {
                label.threshold - epsilon
            } else {
                label.threshold
            };
            if score < bar {
                continue;
            }
            by_root
                .entry(label.root.as_str())
                .or_default()
                .push(ScoredTag {
                    path: label.path.clone(),
                    score,
                    threshold: label.threshold,
                    retained: is_owned && score < label.threshold,
                });
        }

        let mut out = Vec::new();
        for (root, mut tags) in by_root {
            // Sort by score descending, then by path ascending. The tiebreak is
            // not cosmetic: two labels can score bit-identically (a duplicated
            // prompt, a saturated image), and without a total order the cap
            // would keep whichever the label file happened to list first — a
            // detail that must not decide what lands in someone's sidecar.
            tags.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.path.cmp(&b.path))
            });
            let cap = self
                .pack
                .manifest
                .roots
                .get(root)
                .map(|c| c.max_tags)
                .unwrap_or(usize::MAX);
            tags.truncate(cap);
            out.extend(tags);
        }
        out
    }
}

/// Dot product in f64, rounded once at the end.
///
/// Both operands are unit vectors, so this is the cosine. Accumulating in f64
/// costs nothing measurable next to the encoder and removes the largest
/// remaining source of cross-build score wobble — an f32 sum over 512 terms
/// depends on the compiler's vectorization width.
fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut sum = 0.0f64;
    for (x, y) in a.iter().zip(b.iter()) {
        sum += f64::from(*x) * f64::from(*y);
    }
    sum as f32
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use super::*;
    use crate::pack::{Label, Manifest, ModelSpec, PackFile, RootConfig};
    use crate::preprocess::ResizeFilter;

    /// A pack with 2-d embeddings on the unit circle, so scores are easy to
    /// reason about: cos(angle between the label and the image).
    fn pack(labels: Vec<(&str, f32, [f32; 2])>, epsilon: f32, caps: &[(&str, usize)]) -> ModelPack {
        let roots: BTreeMap<String, RootConfig> = caps
            .iter()
            .map(|(r, max)| {
                (
                    (*r).to_string(),
                    RootConfig {
                        threshold: 0.5,
                        max_tags: *max,
                    },
                )
            })
            .collect();
        ModelPack {
            dir: PathBuf::from("/pack"),
            manifest: Manifest {
                schema: 1,
                pack_version: "test-1".into(),
                model: ModelSpec {
                    file: "m.onnx".into(),
                    sha256: "00".into(),
                    input_name: "image".into(),
                    output_name: "embedding".into(),
                    input_size: 8,
                    embedding_dim: 2,
                    mean: [0.0; 3],
                    std: [1.0; 3],
                    resize_filter: ResizeFilter::CatmullRom,
                },
                labels: PackFile {
                    file: "labels.json".into(),
                    sha256: "00".into(),
                },
                label_embeddings: None,
                hysteresis_epsilon: epsilon,
                roots,
                faces: None,
            },
            model_bytes: Vec::new(),
            labels: labels
                .into_iter()
                .map(|(path, threshold, e)| Label {
                    path: path.to_string(),
                    root: path.split('/').next().unwrap().to_string(),
                    threshold,
                    embedding: normalize(&e).unwrap(),
                })
                .collect(),
        }
    }

    fn owned(paths: &[&str]) -> BTreeSet<String> {
        paths.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn only_labels_over_their_threshold_are_emitted() {
        let p = pack(
            vec![
                ("Objects/A", 0.9, [1.0, 0.0]),
                ("Objects/B", 0.9, [0.0, 1.0]),
            ],
            0.0,
            &[("Objects", 8)],
        );
        let t = ZeroShotTagger::new(&p);
        assert_eq!(t.tags(&[1.0, 0.0], &owned(&[])), vec!["Objects/A"]);
    }

    #[test]
    fn a_per_label_threshold_overrides_the_root() {
        let p = pack(
            vec![
                // cos([1,0], normalize([1, 0.1])) ≈ 0.995: over the loose bar,
                // under the strict one, while the root's own 0.5 would pass
                // both.
                ("Objects/Strict", 0.999, [1.0, 0.1]),
                ("Objects/Loose", 0.10, [1.0, 0.1]),
            ],
            0.0,
            &[("Objects", 8)],
        );
        let t = ZeroShotTagger::new(&p);
        assert_eq!(t.tags(&[1.0, 0.0], &owned(&[])), vec!["Objects/Loose"]);
    }

    #[test]
    fn hysteresis_retains_an_owned_tag_just_under_the_bar() {
        // cos(image, label) ≈ 0.8; threshold 0.85; ε 0.10 → retained only when
        // the tag is already ours.
        let p = pack(
            vec![("Objects/Cat", 0.85, [0.8, 0.6])],
            0.10,
            &[("Objects", 8)],
        );
        let t = ZeroShotTagger::new(&p);
        assert!(t.tags(&[1.0, 0.0], &owned(&[])).is_empty());
        assert_eq!(
            t.tags(&[1.0, 0.0], &owned(&["Objects/Cat"])),
            vec!["Objects/Cat"]
        );
        let scored = t.scored(&[1.0, 0.0], &owned(&["Objects/Cat"]));
        assert!(scored[0].retained);
    }

    #[test]
    fn hysteresis_does_not_retain_below_the_band() {
        let p = pack(
            vec![("Objects/Cat", 0.99, [0.8, 0.6])],
            0.01,
            &[("Objects", 8)],
        );
        let t = ZeroShotTagger::new(&p);
        assert!(t.tags(&[1.0, 0.0], &owned(&["Objects/Cat"])).is_empty());
    }

    #[test]
    fn a_clearly_scoring_owned_tag_is_not_marked_retained() {
        let p = pack(
            vec![("Objects/Cat", 0.5, [1.0, 0.0])],
            0.1,
            &[("Objects", 8)],
        );
        let scored = ZeroShotTagger::new(&p).scored(&[1.0, 0.0], &owned(&["Objects/Cat"]));
        assert_eq!(scored.len(), 1);
        assert!(!scored[0].retained);
    }

    #[test]
    fn caps_apply_per_root_and_keep_the_best() {
        let p = pack(
            vec![
                ("Objects/Near", 0.0, [1.0, 0.0]),
                ("Objects/Mid", 0.0, [0.9, 0.436]),
                ("Objects/Far", 0.0, [0.7, 0.714]),
                ("Scenes/Near", 0.0, [1.0, 0.0]),
                ("Scenes/Far", 0.0, [0.7, 0.714]),
            ],
            0.0,
            &[("Objects", 2), ("Scenes", 1)],
        );
        let t = ZeroShotTagger::new(&p);
        assert_eq!(
            t.tags(&[1.0, 0.0], &owned(&[])),
            vec!["Objects/Mid", "Objects/Near", "Scenes/Near"]
        );
    }

    #[test]
    fn ties_are_broken_by_path_not_by_label_order() {
        let p = pack(
            vec![
                ("Objects/Zebra", 0.0, [1.0, 0.0]),
                ("Objects/Aardvark", 0.0, [1.0, 0.0]),
            ],
            0.0,
            &[("Objects", 1)],
        );
        let t = ZeroShotTagger::new(&p);
        assert_eq!(t.tags(&[1.0, 0.0], &owned(&[])), vec!["Objects/Aardvark"]);
    }

    #[test]
    fn output_is_sorted_and_stable() {
        let p = pack(
            vec![
                ("Scenes/Beach", 0.0, [1.0, 0.0]),
                ("Objects/Cat", 0.0, [1.0, 0.0]),
            ],
            0.0,
            &[("Objects", 8), ("Scenes", 8)],
        );
        let t = ZeroShotTagger::new(&p);
        assert_eq!(
            t.tags(&[1.0, 0.0], &owned(&[])),
            vec!["Objects/Cat", "Scenes/Beach"]
        );
    }

    #[test]
    fn a_degenerate_embedding_yields_no_tags_rather_than_an_error() {
        let p = pack(
            vec![("Objects/A", -1.0, [1.0, 0.0])],
            0.0,
            &[("Objects", 8)],
        );
        let t = ZeroShotTagger::new(&p);
        assert!(t.tags(&[0.0, 0.0], &owned(&[])).is_empty());
        assert!(t.tags(&[f32::NAN, 1.0], &owned(&[])).is_empty());
        // Wrong dimensionality is also a no-op, not a panic.
        assert!(t.tags(&[1.0, 0.0, 0.0], &owned(&[])).is_empty());
    }

    #[test]
    fn dot_of_unit_vectors_is_the_cosine() {
        let a = normalize(&[1.0, 1.0]).unwrap();
        let b = normalize(&[1.0, 0.0]).unwrap();
        assert!((dot(&a, &b) - std::f32::consts::FRAC_1_SQRT_2).abs() < 1e-6);
    }
}
