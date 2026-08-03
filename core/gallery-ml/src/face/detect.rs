//! Face detection: letterbox → anchor-free head decode → NMS → original
//! coordinates.
//!
//! # The head
//!
//! SCRFD-family detectors emit, per pyramid level (strides 8/16/32), three
//! tensors over the same flattened anchor grid:
//!
//! | tensor | shape | meaning |
//! |---|---|---|
//! | score | `[N, 1]` | confidence, already through a sigmoid in the graph |
//! | bbox  | `[N, 4]` | distances **in stride units** from the anchor centre to the left, top, right and bottom edges |
//! | kps   | `[N, 10]`| five `(dx, dy)` landmark offsets, also in stride units |
//!
//! `N = (input_size / stride)² × anchors_per_cell`, and the flattening is
//! row-major over `(y, x)` with the per-cell anchors adjacent — that ordering is
//! not documented anywhere in the ONNX file, it is a property of the exporter,
//! and [`anchor_centre`] is where this crate writes it down.
//!
//! Everything about the layout that could differ between detectors (strides,
//! anchors per cell, which output is which) comes from the pack manifest, so a
//! detector swap is a pack rebuild.
//!
//! # Single scale, not a pyramid
//!
//! The image is letterboxed once, to `input_size` (640 for the shipped pack),
//! and run once. SCRFD *is* a feature-pyramid detector — the three strides are
//! its pyramid — so wrapping it in a second, image-space pyramid would triple
//! the cost to re-detect faces the stride-8 level already covers. The cost is a
//! floor on detectable face size: a face smaller than about 12 px in the 640
//! frame is missed, which for a 4032-px-wide photo is a face under ~75 px. That
//! is a face nobody could name from the crop anyway.
//!
//! # Determinism
//!
//! * one fixed input geometry, so the anchor grid never depends on the photo;
//! * fixed score and IoU thresholds from the manifest;
//! * NMS walks candidates in a **total order** — score descending, then `x0`,
//!   `y0`, `x1`, `y1` — so two boxes with bit-identical scores (which happens
//!   on synthetic images with repeated structure) cannot swap places between
//!   runs. Sorting by score alone is a partial order and would.
//! * the surviving detections are re-sorted into that same total order before
//!   they are numbered, so `face_idx` is a property of the photo rather than of
//!   the run.

use std::sync::Arc;

use image::RgbImage;

use crate::encoder::{ModelOutput, MultiOutputModel};
use crate::error::{ErrorCode, MlError, MlResult};
use crate::pack::FaceDetectorSpec;
use crate::preprocess::letterbox;

/// One detected face, in original-image pixels (post-EXIF-orientation).
#[derive(Debug, Clone, PartialEq)]
pub struct Detection {
    /// `[x0, y0, x1, y1]`.
    pub bbox: [f32; 4],
    /// Five landmarks, ArcFace order; see [`super::align`].
    pub landmarks: [[f32; 2]; 5],
    /// Detector confidence.
    pub score: f32,
}

impl Detection {
    /// Box width, never negative.
    pub fn width(&self) -> f32 {
        (self.bbox[2] - self.bbox[0]).max(0.0)
    }

    /// Box height, never negative.
    pub fn height(&self) -> f32 {
        (self.bbox[3] - self.bbox[1]).max(0.0)
    }

    fn area(&self) -> f32 {
        self.width() * self.height()
    }
}

/// The detector: a model plus the manifest that says how to read it.
pub struct FaceDetector {
    model: Arc<dyn MultiOutputModel>,
    spec: FaceDetectorSpec,
    outputs: Vec<String>,
}

impl std::fmt::Debug for FaceDetector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FaceDetector")
            .field("backend", &self.model.backend_name())
            .field("input_size", &self.spec.input_size)
            .field("strides", &self.spec.strides)
            .finish()
    }
}

impl FaceDetector {
    /// Wire a model to a manifest section.
    pub fn new(model: Arc<dyn MultiOutputModel>, spec: FaceDetectorSpec) -> FaceDetector {
        // One flat request in a fixed order, so the backend is asked for each
        // tensor exactly once: scores for every stride, then boxes, then
        // landmarks.
        let outputs = spec
            .score_outputs
            .iter()
            .chain(&spec.bbox_outputs)
            .chain(&spec.kps_outputs)
            .cloned()
            .collect();
        FaceDetector {
            model,
            spec,
            outputs,
        }
    }

    /// The manifest section this detector was built from.
    pub fn spec(&self) -> &FaceDetectorSpec {
        &self.spec
    }

    /// Detect every face in an already-decoded, already-oriented image.
    pub fn detect(&self, path: &str, rgb: &RgbImage) -> MlResult<Vec<Detection>> {
        let framed = letterbox(
            path,
            rgb,
            self.spec.input_size,
            &self.spec.mean,
            &self.spec.std,
            self.spec.resize_filter,
        )?;
        let outputs = self
            .model
            .run(&self.spec.input_name, &framed.tensor, &self.outputs)?;
        decode(
            &self.spec,
            &outputs,
            framed.scale,
            rgb.width(),
            rgb.height(),
        )
    }
}

/// Turn the raw head outputs into detections in original-image coordinates.
///
/// Split from [`FaceDetector::detect`] so the arithmetic — which is where the
/// bugs live — is testable with hand-built tensors and no ONNX Runtime.
pub fn decode(
    spec: &FaceDetectorSpec,
    outputs: &[ModelOutput],
    scale: f64,
    image_w: u32,
    image_h: u32,
) -> MlResult<Vec<Detection>> {
    let levels = spec.strides.len();
    if outputs.len() != levels * 3 {
        return Err(MlError::Inference {
            detail: format!(
                "detector returned {} tensors, manifest describes {}",
                outputs.len(),
                levels * 3
            ),
        });
    }
    if scale <= 0.0 || !scale.is_finite() {
        return Err(MlError::Preprocess {
            path: String::new(),
            code: ErrorCode::BadImage,
            detail: format!("letterbox scale {scale} is unusable"),
        });
    }

    let inv = 1.0 / scale as f32;
    let mut candidates: Vec<Detection> = Vec::new();

    for (level, stride) in spec.strides.iter().copied().enumerate() {
        let scores = &outputs[level];
        let boxes = &outputs[levels + level];
        let kps = &outputs[levels * 2 + level];

        let cells = (spec.input_size / stride) as usize;
        let n = cells * cells * spec.anchors_per_cell;
        // A mismatch here means the letterbox size and the graph disagree,
        // which silently decodes garbage if it is not caught.
        if scores.len() != n || boxes.len() != n * 4 || kps.len() != n * 10 {
            return Err(MlError::Inference {
                detail: format!(
                    "stride {stride}: expected {n}/{}/{} values, got {}/{}/{}",
                    n * 4,
                    n * 10,
                    scores.len(),
                    boxes.len(),
                    kps.len()
                ),
            });
        }

        let s = stride as f32;
        for i in 0..n {
            let score = scores.data[i];
            // NaN-safe: a bare `<` would let a NaN score through as a face.
            if score.is_nan() || score < spec.score_threshold {
                continue;
            }
            let (cx, cy) = anchor_centre(i, cells, spec.anchors_per_cell, s);
            let b = &boxes.data[i * 4..i * 4 + 4];
            let bbox = [
                (cx - b[0] * s) * inv,
                (cy - b[1] * s) * inv,
                (cx + b[2] * s) * inv,
                (cy + b[3] * s) * inv,
            ];
            let k = &kps.data[i * 10..i * 10 + 10];
            let mut landmarks = [[0.0f32; 2]; 5];
            for (j, p) in landmarks.iter_mut().enumerate() {
                *p = [(cx + k[j * 2] * s) * inv, (cy + k[j * 2 + 1] * s) * inv];
            }
            if !bbox.iter().all(|v| v.is_finite())
                || !landmarks.iter().flatten().all(|v| v.is_finite())
            {
                continue;
            }
            candidates.push(Detection {
                bbox,
                landmarks,
                score,
            });
        }
    }

    Ok(finalize(spec, candidates, image_w, image_h))
}

/// Clip, drop the too-small, suppress overlaps, cap, and number.
fn finalize(
    spec: &FaceDetectorSpec,
    mut candidates: Vec<Detection>,
    image_w: u32,
    image_h: u32,
) -> Vec<Detection> {
    let (w, h) = (image_w as f32, image_h as f32);
    candidates.retain_mut(|d| {
        // A box may legitimately poke off the edge of the photo — half a face
        // at the frame border is still a face — but the *landmarks* are left
        // alone: they are the alignment input, and clamping one onto the border
        // would silently skew the crop.
        d.bbox[0] = d.bbox[0].clamp(0.0, w);
        d.bbox[1] = d.bbox[1].clamp(0.0, h);
        d.bbox[2] = d.bbox[2].clamp(0.0, w);
        d.bbox[3] = d.bbox[3].clamp(0.0, h);
        d.width().min(d.height()) >= spec.min_face_pixels && d.area() > 0.0
    });

    sort_detections(&mut candidates);
    let mut kept: Vec<Detection> = Vec::new();
    for candidate in candidates {
        if kept.len() >= spec.max_faces {
            break;
        }
        if kept.iter().any(|k| iou(k, &candidate) > spec.nms_iou) {
            continue;
        }
        kept.push(candidate);
    }
    // `kept` is already in the sort order — NMS preserves it — but re-sorting
    // states the invariant the `face_idx` numbering depends on rather than
    // relying on a property of the loop above.
    sort_detections(&mut kept);
    kept
}

/// The total order every detection list is in: score descending, then geometry.
///
/// Score alone is a *partial* order; ties are common on synthetic and repeated
/// imagery, and a partial order lets two runs number the same two faces
/// differently. `face_idx` is a database key, so that would be a cache that
/// disagrees with itself.
pub fn sort_detections(v: &mut [Detection]) {
    v.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.bbox[0].total_cmp(&b.bbox[0]))
            .then_with(|| a.bbox[1].total_cmp(&b.bbox[1]))
            .then_with(|| a.bbox[2].total_cmp(&b.bbox[2]))
            .then_with(|| a.bbox[3].total_cmp(&b.bbox[3]))
    });
}

/// Anchor centre for flat index `i`, in letterbox pixels.
///
/// The layout is row-major over the grid with `anchors_per_cell` consecutive
/// entries sharing a centre: `i = (y · cells + x) · anchors + a`.
fn anchor_centre(i: usize, cells: usize, anchors: usize, stride: f32) -> (f32, f32) {
    let cell = i / anchors;
    let x = cell % cells;
    let y = cell / cells;
    (x as f32 * stride, y as f32 * stride)
}

/// Intersection over union of two boxes.
fn iou(a: &Detection, b: &Detection) -> f32 {
    let x0 = a.bbox[0].max(b.bbox[0]);
    let y0 = a.bbox[1].max(b.bbox[1]);
    let x1 = a.bbox[2].min(b.bbox[2]);
    let y1 = a.bbox[3].min(b.bbox[3]);
    let inter = (x1 - x0).max(0.0) * (y1 - y0).max(0.0);
    let union = a.area() + b.area() - inter;
    if union <= 0.0 {
        0.0
    } else {
        inter / union
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::preprocess::ResizeFilter;

    fn spec() -> FaceDetectorSpec {
        FaceDetectorSpec {
            file: "d.onnx".into(),
            sha256: "00".into(),
            input_name: "input".into(),
            input_size: 32,
            score_outputs: vec!["s16".into(), "s32".into()],
            bbox_outputs: vec!["b16".into(), "b32".into()],
            kps_outputs: vec!["k16".into(), "k32".into()],
            strides: vec![16, 32],
            anchors_per_cell: 2,
            mean: [0.5; 3],
            std: [0.5; 3],
            resize_filter: ResizeFilter::Bilinear,
            score_threshold: 0.5,
            nms_iou: 0.4,
            max_faces: 8,
            min_face_pixels: 0.0,
        }
    }

    /// `[scores…, boxes…, kps…]` for the two-level spec above, all zeros.
    fn empty_outputs(spec: &FaceDetectorSpec) -> Vec<ModelOutput> {
        let mut out = Vec::new();
        for width in [1usize, 4, 10] {
            for stride in &spec.strides {
                let cells = (spec.input_size / stride) as usize;
                let n = cells * cells * spec.anchors_per_cell;
                out.push(ModelOutput {
                    shape: vec![n, width],
                    data: vec![0.0; n * width],
                });
            }
        }
        out
    }

    /// Write one candidate into the level-0 tensors at flat index `i`.
    fn put(
        outputs: &mut [ModelOutput],
        levels: usize,
        i: usize,
        score: f32,
        ltrb: [f32; 4],
        kps: [f32; 10],
    ) {
        outputs[0].data[i] = score;
        outputs[levels].data[i * 4..i * 4 + 4].copy_from_slice(&ltrb);
        outputs[levels * 2].data[i * 10..i * 10 + 10].copy_from_slice(&kps);
    }

    #[test]
    fn anchor_centres_walk_the_grid_row_major_with_paired_anchors() {
        // 2×2 cells, 2 anchors, stride 16.
        assert_eq!(anchor_centre(0, 2, 2, 16.0), (0.0, 0.0));
        assert_eq!(anchor_centre(1, 2, 2, 16.0), (0.0, 0.0));
        assert_eq!(anchor_centre(2, 2, 2, 16.0), (16.0, 0.0));
        assert_eq!(anchor_centre(4, 2, 2, 16.0), (0.0, 16.0));
        assert_eq!(anchor_centre(7, 2, 2, 16.0), (16.0, 16.0));
    }

    /// Distances are in stride units and land relative to the anchor centre;
    /// the whole thing then divides by the letterbox scale.
    #[test]
    fn a_box_decodes_from_stride_units_into_original_pixels() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        // Cell (1, 0) at stride 16 → centre (16, 0). Distances of 1 stride each.
        put(&mut outputs, 2, 2, 0.9, [1.0, 0.0, 1.0, 2.0], [0.0; 10]);
        // scale 0.5 → the letterbox halved the image, so coordinates double.
        let got = decode(&spec, &outputs, 0.5, 1000, 1000).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].bbox, [0.0, 0.0, 64.0, 64.0]);
        assert_eq!(got[0].score, 0.9);
        // All five landmarks sat at the anchor centre.
        assert_eq!(got[0].landmarks[0], [32.0, 0.0]);
    }

    #[test]
    fn candidates_below_the_score_threshold_never_appear() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        put(&mut outputs, 2, 4, 0.49, [1.0, 1.0, 1.0, 1.0], [0.0; 10]);
        assert!(decode(&spec, &outputs, 1.0, 100, 100).unwrap().is_empty());
        put(&mut outputs, 2, 4, 0.5, [1.0, 1.0, 1.0, 1.0], [0.0; 10]);
        assert_eq!(decode(&spec, &outputs, 1.0, 100, 100).unwrap().len(), 1);
    }

    #[test]
    fn overlapping_boxes_are_suppressed_and_the_stronger_survives() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        // Two nearly-coincident boxes around neighbouring anchors.
        put(&mut outputs, 2, 4, 0.7, [1.0, 1.0, 1.0, 1.0], [0.0; 10]);
        put(&mut outputs, 2, 6, 0.9, [1.5, 1.0, 0.5, 1.0], [0.0; 10]);
        let got = decode(&spec, &outputs, 1.0, 100, 100).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].score, 0.9);
    }

    #[test]
    fn distant_boxes_both_survive() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        put(&mut outputs, 2, 0, 0.7, [0.0, 0.0, 0.5, 0.5], [0.0; 10]);
        put(&mut outputs, 2, 6, 0.9, [0.5, 0.5, 0.0, 0.0], [0.0; 10]);
        let got = decode(&spec, &outputs, 1.0, 100, 100).unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].score, 0.9, "sorted score-descending");
    }

    /// Two boxes with bit-identical scores must come back in the same order
    /// however the anchor grid happened to feed them in.
    #[test]
    fn ties_are_broken_by_geometry_not_by_iteration_order() {
        let spec = FaceDetectorSpec {
            nms_iou: 1.0,
            ..spec()
        };
        let mut outputs = empty_outputs(&spec);
        put(&mut outputs, 2, 0, 0.8, [0.0, 0.0, 0.5, 0.5], [0.0; 10]);
        put(&mut outputs, 2, 6, 0.8, [0.5, 0.5, 0.0, 0.0], [0.0; 10]);
        let first = decode(&spec, &outputs, 1.0, 100, 100).unwrap();

        let mut swapped = empty_outputs(&spec);
        put(&mut swapped, 2, 6, 0.8, [0.5, 0.5, 0.0, 0.0], [0.0; 10]);
        put(&mut swapped, 2, 0, 0.8, [0.0, 0.0, 0.5, 0.5], [0.0; 10]);
        let second = decode(&spec, &swapped, 1.0, 100, 100).unwrap();
        assert_eq!(first, second);
        assert!(first[0].bbox[0] <= first[1].bbox[0]);
    }

    #[test]
    fn boxes_are_clipped_to_the_photo_but_landmarks_are_not() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        // Anchor (0,0), extending 2 strides left/up — off the frame.
        put(
            &mut outputs,
            2,
            0,
            0.9,
            [2.0, 2.0, 1.0, 1.0],
            [-1.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        );
        let got = decode(&spec, &outputs, 1.0, 100, 100).unwrap();
        assert_eq!(got[0].bbox[0], 0.0);
        assert_eq!(got[0].bbox[1], 0.0);
        assert_eq!(got[0].landmarks[0], [-16.0, -16.0], "landmarks kept exact");
    }

    #[test]
    fn faces_below_the_pixel_floor_are_dropped() {
        let spec = FaceDetectorSpec {
            min_face_pixels: 40.0,
            ..spec()
        };
        let mut outputs = empty_outputs(&spec);
        put(&mut outputs, 2, 4, 0.9, [1.0, 1.0, 1.0, 1.0], [0.0; 10]);
        // 32×32 in letterbox pixels, and the letterbox shrank nothing.
        assert!(decode(&spec, &outputs, 1.0, 100, 100).unwrap().is_empty());
        // The same detection on a photo that was shrunk 4× is 128 px across.
        assert_eq!(decode(&spec, &outputs, 0.25, 1000, 1000).unwrap().len(), 1);
    }

    #[test]
    fn the_cap_keeps_the_strongest_faces() {
        let spec = FaceDetectorSpec {
            max_faces: 2,
            ..spec()
        };
        let mut outputs = empty_outputs(&spec);
        for (i, score) in [(0usize, 0.6f32), (2, 0.9), (4, 0.7), (6, 0.8)] {
            put(&mut outputs, 2, i, score, [0.4, 0.4, 0.4, 0.4], [0.0; 10]);
        }
        let got = decode(&spec, &outputs, 1.0, 200, 200).unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].score, 0.9);
        assert_eq!(got[1].score, 0.8);
    }

    #[test]
    fn a_tensor_of_the_wrong_length_is_an_error_not_garbage() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        outputs[0].data.truncate(3);
        assert!(matches!(
            decode(&spec, &outputs, 1.0, 10, 10),
            Err(MlError::Inference { .. })
        ));
        assert!(matches!(
            decode(&spec, &outputs[..3], 1.0, 10, 10),
            Err(MlError::Inference { .. })
        ));
    }

    #[test]
    fn non_finite_predictions_are_dropped_rather_than_propagated() {
        let spec = spec();
        let mut outputs = empty_outputs(&spec);
        put(
            &mut outputs,
            2,
            0,
            0.9,
            [f32::NAN, 1.0, 1.0, 1.0],
            [0.0; 10],
        );
        assert!(decode(&spec, &outputs, 1.0, 100, 100).unwrap().is_empty());
    }

    #[test]
    fn iou_is_symmetric_and_bounded() {
        let a = Detection {
            bbox: [0.0, 0.0, 10.0, 10.0],
            landmarks: [[0.0; 2]; 5],
            score: 1.0,
        };
        let b = Detection {
            bbox: [5.0, 0.0, 15.0, 10.0],
            landmarks: [[0.0; 2]; 5],
            score: 1.0,
        };
        assert!((iou(&a, &b) - 1.0 / 3.0).abs() < 1e-6);
        assert_eq!(iou(&a, &b), iou(&b, &a));
        assert!((iou(&a, &a) - 1.0).abs() < 1e-6);
    }
}
