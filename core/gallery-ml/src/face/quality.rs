//! A single `[0, 1]` number saying how much this face is worth trusting.
//!
//! Three things independently make a detection a bad basis for a decision, and
//! they multiply rather than average because any one of them being near zero
//! should be disqualifying on its own:
//!
//! ```text
//! quality = detector_score × size_term × frontality
//! ```
//!
//! **`detector_score`** — the detector's own confidence, already in `[0, 1]`.
//! A 0.51 detection on a 0.5 threshold is a face the model is barely willing to
//! claim.
//!
//! **`size_term`** — `min(1, √(w·h) / (SIZE_REF · min(image_w, image_h)))`.
//! The geometric mean of the box's sides against a fraction of the photo's
//! short edge, so it is resolution-independent: the same face fills the same
//! fraction of a 12 MP photo and its 2 MP export. [`SIZE_REF`] is 0.15 — a face
//! whose sides average 15% of the short edge is a normal portrait subject and
//! scores full marks; a face at 3% (a person in a group shot at the back)
//! scores 0.2. This is a proxy for *pixels on target*: the aligned crop is
//! 112×112, so a small face is upsampled and its embedding carries less
//! information than the model thinks it does.
//!
//! **`frontality`** — `clamp(1 − 2 · yaw_offset, 0, 1)`, where `yaw_offset` is
//! how far the nose sits off the face's midline, measured perpendicular to the
//! eye-to-mouth axis and normalized by the interocular distance. A face looking
//! straight at the camera has its nose on the midline; as it turns, the nose
//! swings toward the near eye. At `yaw_offset = 0.5` the nose is over one eye —
//! roughly 60° of yaw — and frontality is 0.
//!
//! Deliberately *not* included: sharpness, exposure, occlusion. Each would need
//! the pixels (this works from the detection alone, so it can be recomputed
//! from cached rows), and each is a much noisier signal than the three above.
//!
//! # What the number is used for
//!
//! Not for gating clustering: a blurry three-quarter face of a known person is
//! still evidence about who is in the photo, and dropping it would shrink
//! exactly the clusters that need members most. It gates the two places a bad
//! face causes visible harm — auto-tagging into a named cluster (which writes
//! a sidecar) and cover-crop selection (which puts the face on screen). Both
//! compare against `faces.clustering.min_quality` from the pack manifest.

use crate::face::detect::Detection;

/// Box size, as a fraction of the photo's short edge, that scores full marks.
pub const SIZE_REF: f32 = 0.15;

/// Composite quality in `[0, 1]`. See the module docs for the formula.
pub fn quality(d: &Detection, image_w: u32, image_h: u32) -> f32 {
    let score = d.score.clamp(0.0, 1.0);
    let size = size_term(d, image_w, image_h);
    let front = frontality(&d.landmarks);
    (score * size * front).clamp(0.0, 1.0)
}

fn size_term(d: &Detection, image_w: u32, image_h: u32) -> f32 {
    let short = image_w.min(image_h) as f32;
    if short <= 0.0 {
        return 0.0;
    }
    let mean_side = (d.width() * d.height()).sqrt();
    if !mean_side.is_finite() {
        return 0.0;
    }
    (mean_side / (SIZE_REF * short)).clamp(0.0, 1.0)
}

/// How square-on the face is, from the five landmarks alone.
///
/// Returns 0 for degenerate geometry (coincident eyes, coincident eye and mouth
/// centres) rather than a divide-by-zero: such a "face" should not be trusted
/// for anything, which is exactly what a quality of 0 says.
pub fn frontality(landmarks: &[[f32; 2]; 5]) -> f32 {
    let (le, re, nose, lm, rm) = (
        landmarks[0],
        landmarks[1],
        landmarks[2],
        landmarks[3],
        landmarks[4],
    );
    let interocular = dist(le, re);
    if interocular.is_nan() || interocular <= 0.0 {
        return 0.0;
    }
    let eye_mid = mid(le, re);
    let mouth_mid = mid(lm, rm);
    // The face's own vertical axis, which absorbs roll: a head tilted 30° is
    // still frontal, and alignment straightens it anyway.
    let axis = [mouth_mid[0] - eye_mid[0], mouth_mid[1] - eye_mid[1]];
    let axis_len = (axis[0] * axis[0] + axis[1] * axis[1]).sqrt();
    if axis_len.is_nan() || axis_len <= 0.0 {
        return 0.0;
    }
    let unit = [axis[0] / axis_len, axis[1] / axis_len];
    let to_nose = [nose[0] - eye_mid[0], nose[1] - eye_mid[1]];
    // Perpendicular component == 2-D cross product with the unit axis.
    let perpendicular = (to_nose[0] * unit[1] - to_nose[1] * unit[0]).abs();
    let yaw_offset = perpendicular / interocular;
    (1.0 - 2.0 * yaw_offset).clamp(0.0, 1.0)
}

fn mid(a: [f32; 2], b: [f32; 2]) -> [f32; 2] {
    [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
}

fn dist(a: [f32; 2], b: [f32; 2]) -> f32 {
    let (dx, dy) = (a[0] - b[0], a[1] - b[1]);
    (dx * dx + dy * dy).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::face::align::ARCFACE_TEMPLATE;

    fn detection(bbox: [f32; 4], landmarks: [[f32; 2]; 5], score: f32) -> Detection {
        Detection {
            bbox,
            landmarks,
            score,
        }
    }

    /// The template *is* a frontal face by construction.
    fn template_landmarks(scale: f32, tx: f32, ty: f32) -> [[f32; 2]; 5] {
        let mut out = [[0.0f32; 2]; 5];
        for (i, p) in ARCFACE_TEMPLATE.iter().enumerate() {
            out[i] = [p[0] as f32 * scale + tx, p[1] as f32 * scale + ty];
        }
        out
    }

    #[test]
    fn the_arcface_template_is_very_nearly_perfectly_frontal() {
        let f = frontality(&template_landmarks(1.0, 0.0, 0.0));
        assert!(f > 0.95, "{f}");
    }

    /// Roll must not cost anything: alignment removes it.
    #[test]
    fn rotating_the_face_does_not_change_frontality() {
        let upright = frontality(&template_landmarks(1.0, 0.0, 0.0));
        let mut tilted = [[0.0f32; 2]; 5];
        let a = 0.5f32;
        for (i, p) in ARCFACE_TEMPLATE.iter().enumerate() {
            let (x, y) = (p[0] as f32, p[1] as f32);
            tilted[i] = [x * a.cos() - y * a.sin(), x * a.sin() + y * a.cos()];
        }
        assert!((frontality(&tilted) - upright).abs() < 1e-3);
    }

    /// Scale must not change it either — it is a ratio.
    #[test]
    fn frontality_is_scale_and_translation_invariant() {
        let a = frontality(&template_landmarks(1.0, 0.0, 0.0));
        let b = frontality(&template_landmarks(7.5, -300.0, 900.0));
        assert!((a - b).abs() < 1e-3, "{a} vs {b}");
    }

    /// Sliding the nose toward one eye is what turning your head looks like in
    /// five points, and it must cost frontality monotonically.
    #[test]
    fn a_turned_head_loses_frontality_and_bottoms_out() {
        let base = template_landmarks(1.0, 0.0, 0.0);
        let interocular = dist(base[0], base[1]);
        let mut previous = frontality(&base);
        for step in 1..=5 {
            let mut turned = base;
            turned[2][0] -= interocular * 0.1 * step as f32;
            let f = frontality(&turned);
            assert!(f < previous, "step {step}: {f} !< {previous}");
            previous = f;
        }
        // Nose over the far eye: no longer a face worth trusting.
        let mut extreme = base;
        extreme[2][0] -= interocular * 0.6;
        assert_eq!(frontality(&extreme), 0.0);
    }

    #[test]
    fn degenerate_landmarks_score_zero_rather_than_dividing_by_zero() {
        assert_eq!(frontality(&[[5.0, 5.0]; 5]), 0.0);
        // Eyes apart but the mouth exactly on the eye line: no face axis.
        let flat = [[0.0, 0.0], [10.0, 0.0], [5.0, 0.0], [0.0, 0.0], [10.0, 0.0]];
        assert_eq!(frontality(&flat), 0.0);
    }

    #[test]
    fn size_scores_full_marks_at_the_reference_fraction_and_scales_below_it() {
        let landmarks = template_landmarks(1.0, 0.0, 0.0);
        // 150×150 in a 1000×1000 photo is exactly SIZE_REF.
        let big = detection([0.0, 0.0, 150.0, 150.0], landmarks, 1.0);
        assert!((size_term(&big, 1000, 1000) - 1.0).abs() < 1e-6);
        // Bigger still is capped, not rewarded.
        let huge = detection([0.0, 0.0, 900.0, 900.0], landmarks, 1.0);
        assert_eq!(size_term(&huge, 1000, 1000), 1.0);
        // A third of the reference scores a third.
        let small = detection([0.0, 0.0, 50.0, 50.0], landmarks, 1.0);
        assert!((size_term(&small, 1000, 1000) - 1.0 / 3.0).abs() < 1e-5);
    }

    /// The same face in a downscaled export must score the same.
    #[test]
    fn size_is_resolution_independent() {
        let landmarks = template_landmarks(1.0, 0.0, 0.0);
        let full = detection([0.0, 0.0, 300.0, 300.0], landmarks, 1.0);
        let export = detection([0.0, 0.0, 75.0, 75.0], landmarks, 1.0);
        assert!((size_term(&full, 4000, 3000) - size_term(&export, 1000, 750)).abs() < 1e-6);
    }

    /// The three terms multiply: a perfect score on two of them cannot rescue
    /// a zero on the third.
    #[test]
    fn any_single_term_at_zero_disqualifies_the_face() {
        let good = template_landmarks(1.0, 0.0, 0.0);
        assert_eq!(
            quality(&detection([0.0, 0.0, 150.0, 150.0], good, 0.0), 1000, 1000),
            0.0
        );
        assert_eq!(
            quality(&detection([0.0, 0.0, 0.0, 0.0], good, 1.0), 1000, 1000),
            0.0
        );
        assert_eq!(
            quality(
                &detection([0.0, 0.0, 150.0, 150.0], [[3.0, 3.0]; 5], 1.0),
                1000,
                1000
            ),
            0.0
        );
    }

    #[test]
    fn a_good_portrait_scores_near_one() {
        let landmarks = template_landmarks(2.0, 100.0, 100.0);
        let d = detection([80.0, 80.0, 340.0, 340.0], landmarks, 0.95);
        let q = quality(&d, 1000, 1000);
        assert!(q > 0.85, "{q}");
        assert!(q <= 1.0);
    }

    #[test]
    fn a_zero_sized_photo_does_not_panic() {
        let d = detection(
            [0.0, 0.0, 10.0, 10.0],
            template_landmarks(1.0, 0.0, 0.0),
            1.0,
        );
        assert_eq!(quality(&d, 0, 0), 0.0);
    }
}
