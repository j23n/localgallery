//! Five-point similarity alignment onto the ArcFace template.
//!
//! Every ArcFace-family recognition model — `w600k_mbf` included — was trained
//! on crops produced by one specific transform: fit the five detected landmarks
//! to a fixed 112×112 template with a *similarity* transform (rotation, uniform
//! scale, translation — no shear, no per-axis scale), then resample. Feeding it
//! anything else, even a perfectly reasonable square crop of the same face,
//! moves the embedding far enough to matter at the thresholds this crate
//! clusters with. So the alignment is not a convenience: it is part of the
//! model's contract.
//!
//! # The template
//!
//! [`ARCFACE_TEMPLATE`] is insightface's `arcface_dst`, verbatim, in
//! `(x, y)` order: left eye, right eye, nose, left mouth corner, right mouth
//! corner — "left" meaning image-left, which is the subject's right. The
//! detector emits its landmarks in the same order, which is the single strongest
//! argument for pairing an insightface detector with an insightface embedder;
//! YuNet, for instance, emits the two eyes the other way round and a pack
//! swapping detectors would have to say so.
//!
//! For an embedder whose input edge is not 112 the template is scaled by
//! `size / 112`. That is what insightface's `estimate_norm` does for its
//! `image_size % 112 == 0` case.
//!
//! # The estimator
//!
//! [`umeyama`] is the Umeyama (1991) least-squares similarity transform, the
//! same algorithm behind `skimage.transform.SimilarityTransform`, which is what
//! insightface calls. In two dimensions it collapses to a closed form with no
//! SVD in it at all (see the function's own docs), so there is no iteration
//! count, no convergence tolerance and nothing to drift between devices. All of
//! the arithmetic is `f64`.
//!
//! # The resampler
//!
//! Inverse-mapped **bilinear** sampling with a constant zero border, matching
//! `cv2.warpAffine`'s defaults. Two deliberate deviations from OpenCV, both
//! pinned by [`crate::face::ALIGN_VERSION`] and by the golden test:
//!
//! * OpenCV evaluates its bilinear weights in 5-bit fixed point from a lookup
//!   table; this evaluates them in `f64`. Ours is the more accurate of the two
//!   and, more importantly, has no table to disagree about.
//! * `fast_image_resize` is not used here at all. It resamples axis-aligned
//!   rectangles; an aligned face crop is a rotated one. Rolling the sampler
//!   keeps the whole warp in one place instead of splitting it into a rotate
//!   and a resize with two rounding steps.
//!
//! The sampled values are rounded to `u8` before normalization, which is what
//! the reference pipeline does (`warpAffine` on a `uint8` image produces
//! `uint8`), so a crop can be compared against one produced by the reference
//! stack pixel for pixel rather than approximately.
//!
//! And it was. Fed the *same decoded pixels*, this warp is **bit-identical**
//! (max difference 0 over all 37 632 bytes) to the float-bilinear reference in
//! `scripts/build_model_pack`'s companion script, and [`umeyama`] reproduces
//! `skimage.transform.SimilarityTransform`'s matrix to 1e-6. Fed the same
//! *JPEG*, the crops differ by up to 11/255 — every bit of which is the
//! decoder, not this module: `zune-jpeg` and libjpeg disagree by up to 4/255 on
//! the source, and the 1.76× warp amplifies that. Which is the determinism
//! doctrine's whole thesis stated as a measurement: pin the decoder, or nothing
//! downstream can agree.

use image::{Rgb, RgbImage};

use crate::error::{MlError, MlResult};
use crate::preprocess::{tensor_from_square, Tensor};

/// Bumped whenever a change in this module moves an aligned pixel.
///
/// Joins the face cache key ([`crate::ModelPack::face_pack_key`]) for the same
/// reason [`crate::preprocess::PREPROCESS_VERSION`] joins the embedding key:
/// the content hash describes the file, not what we did to it.
pub const ALIGN_VERSION: u32 = 1;

/// The edge length [`ARCFACE_TEMPLATE`] is expressed in.
pub const TEMPLATE_SIZE: f64 = 112.0;

/// insightface's `arcface_dst`, `(x, y)` at 112×112.
pub const ARCFACE_TEMPLATE: [[f64; 2]; 5] = [
    [38.2946, 51.6963],
    [73.5318, 51.5014],
    [56.0252, 71.7366],
    [41.5493, 92.3655],
    [70.7299, 92.2041],
];

/// A 2×3 affine, row-major: `[a, b, tx, c, d, ty]`.
///
/// Maps source (image) coordinates to destination (template) coordinates:
/// `x' = a·x + b·y + tx`, `y' = c·x + d·y + ty`.
pub type Affine = [f64; 6];

/// The template scaled to a `size × size` crop.
pub fn template_for(size: u32) -> [[f64; 2]; 5] {
    let k = f64::from(size) / TEMPLATE_SIZE;
    let mut out = ARCFACE_TEMPLATE;
    for p in &mut out {
        p[0] *= k;
        p[1] *= k;
    }
    out
}

/// Least-squares similarity transform taking `src` onto `dst`.
///
/// Umeyama 1991, §"the case of similarity transformation", specialized to two
/// dimensions. The general algorithm needs an SVD of the cross-covariance
/// `A = Σ (dᵢ − d̄)(sᵢ − s̄)ᵀ / n` in order to build `R = U·D·Vᵀ` and the scale
/// `c = tr(D·S) / σ²ₛ`. In 2-D the whole thing has a closed form, because the
/// only rotations are `R(θ)` and
///
/// ```text
/// tr(R(θ)ᵀ A) = cos θ · (A₀₀ + A₁₁) + sin θ · (A₁₀ − A₀₁)
/// ```
///
/// which is maximized at `θ = atan2(A₁₀ − A₀₁, A₀₀ + A₁₁)` with maximum
/// `hypot(A₀₀ + A₁₁, A₁₀ − A₀₁)`. That maximum *is* `tr(D·S)` — including the
/// `D = diag(1, −1)` case, since restricting the search to rotations is exactly
/// what Umeyama's `D` correction accomplishes. So there is no SVD, no
/// reflection special case, and no branch: a reflected input is fitted by the
/// best rotation, which is what alignment must do (a mirrored face crop would
/// be embedded happily and wrongly).
///
/// Returns `None` when the source points are degenerate (all coincident), which
/// no real detection produces but a corrupt cache row could.
pub fn umeyama(src: &[[f64; 2]; 5], dst: &[[f64; 2]; 5]) -> Option<Affine> {
    let n = 5.0;
    let mean = |p: &[[f64; 2]; 5], i: usize| p.iter().map(|q| q[i]).sum::<f64>() / n;
    let (sx, sy) = (mean(src, 0), mean(src, 1));
    let (dx, dy) = (mean(dst, 0), mean(dst, 1));

    // Cross-covariance of the centred point sets, and the source variance.
    let mut cov = [[0.0f64; 2]; 2];
    let mut var_src = 0.0f64;
    for i in 0..5 {
        let s = [src[i][0] - sx, src[i][1] - sy];
        let d = [dst[i][0] - dx, dst[i][1] - dy];
        for (r, dr) in d.iter().enumerate() {
            for (c, sc) in s.iter().enumerate() {
                cov[r][c] += dr * sc / n;
            }
        }
        var_src += (s[0] * s[0] + s[1] * s[1]) / n;
    }
    if !var_src.is_finite() || var_src <= f64::EPSILON {
        return None;
    }

    let trace = cov[0][0] + cov[1][1];
    let skew = cov[1][0] - cov[0][1];
    let scale = trace.hypot(skew) / var_src;
    if !scale.is_finite() || scale <= 0.0 {
        return None;
    }
    let theta = skew.atan2(trace);
    let (sin, cos) = theta.sin_cos();

    let m = [scale * cos, -scale * sin, scale * sin, scale * cos];
    Some([
        m[0],
        m[1],
        dx - (m[0] * sx + m[1] * sy),
        m[2],
        m[3],
        dy - (m[2] * sx + m[3] * sy),
    ])
}

/// Warp `src` through `m` into a `size × size` RGB crop.
///
/// Destination pixels are sampled at their centres by inverse-mapping through
/// `m`, exactly as `cv2.warpAffine` does without `WARP_INVERSE_MAP`. Samples
/// that land outside the source contribute black.
pub fn warp_affine(src: &RgbImage, m: &Affine, size: u32) -> Option<RgbImage> {
    let inv = invert(m)?;
    let (w, h) = (src.width() as i64, src.height() as i64);
    let mut out = RgbImage::new(size, size);
    for y in 0..size {
        for x in 0..size {
            let fx = f64::from(x);
            let fy = f64::from(y);
            let sx = inv[0] * fx + inv[1] * fy + inv[2];
            let sy = inv[3] * fx + inv[4] * fy + inv[5];
            out.put_pixel(x, y, sample_bilinear(src, w, h, sx, sy));
        }
    }
    Some(out)
}

fn sample_bilinear(src: &RgbImage, w: i64, h: i64, sx: f64, sy: f64) -> Rgb<u8> {
    if !sx.is_finite() || !sy.is_finite() {
        return Rgb([0, 0, 0]);
    }
    let x0 = sx.floor();
    let y0 = sy.floor();
    let fx = sx - x0;
    let fy = sy - y0;
    let x0 = x0 as i64;
    let y0 = y0 as i64;

    let mut acc = [0.0f64; 3];
    for (dy, wy) in [(0i64, 1.0 - fy), (1, fy)] {
        for (dx, wx) in [(0i64, 1.0 - fx), (1, fx)] {
            let weight = wx * wy;
            if weight == 0.0 {
                continue;
            }
            let (xi, yi) = (x0 + dx, y0 + dy);
            // Outside is the constant border, i.e. it contributes nothing.
            if xi < 0 || yi < 0 || xi >= w || yi >= h {
                continue;
            }
            let px = src.get_pixel(xi as u32, yi as u32);
            for c in 0..3 {
                acc[c] += f64::from(px[c]) * weight;
            }
        }
    }
    Rgb([
        acc[0].round().clamp(0.0, 255.0) as u8,
        acc[1].round().clamp(0.0, 255.0) as u8,
        acc[2].round().clamp(0.0, 255.0) as u8,
    ])
}

/// Landmarks → aligned `size × size` crop, ready for [`tensor_from_square`].
pub fn align_crop(src: &RgbImage, landmarks: &[[f32; 2]; 5], size: u32) -> MlResult<RgbImage> {
    let fail = |detail: &str| MlError::Preprocess {
        path: String::new(),
        code: crate::error::ErrorCode::BadImage,
        detail: detail.to_string(),
    };
    if size == 0 {
        return Err(MlError::PackInvalid {
            detail: "faces.embedder.input_size is 0".into(),
        });
    }
    let mut src_pts = [[0.0f64; 2]; 5];
    for (i, p) in landmarks.iter().enumerate() {
        if !p[0].is_finite() || !p[1].is_finite() {
            return Err(fail("landmark is not finite"));
        }
        src_pts[i] = [f64::from(p[0]), f64::from(p[1])];
    }
    let m = umeyama(&src_pts, &template_for(size)).ok_or_else(|| fail("degenerate landmarks"))?;
    warp_affine(src, &m, size).ok_or_else(|| fail("non-invertible alignment"))
}

/// [`align_crop`] followed by normalization into the embedder's input tensor.
pub fn align_tensor(
    src: &RgbImage,
    landmarks: &[[f32; 2]; 5],
    size: u32,
    mean: &[f32; 3],
    std: &[f32; 3],
) -> MlResult<Tensor> {
    tensor_from_square(&align_crop(src, landmarks, size)?, mean, std)
}

// ---------------------------------------------------------------------------
// 2×2 linear algebra
//
// Hand-rolled rather than pulled from `nalgebra`: it is three short functions,
// they are the only matrix work in the crate, and a linear-algebra crate is a
// large dependency to ship to a phone for one 2×2 SVD.
// ---------------------------------------------------------------------------

fn invert(m: &Affine) -> Option<Affine> {
    let det = m[0] * m[4] - m[1] * m[3];
    if !det.is_finite() || det.abs() <= f64::EPSILON {
        return None;
    }
    let (a, b, tx, c, d, ty) = (m[0], m[1], m[2], m[3], m[4], m[5]);
    Some([
        d / det,
        -b / det,
        (b * ty - d * tx) / det,
        -c / det,
        a / det,
        (c * tx - a * ty) / det,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    fn apply(m: &Affine, p: [f64; 2]) -> [f64; 2] {
        [
            m[0] * p[0] + m[1] * p[1] + m[2],
            m[3] * p[0] + m[4] * p[1] + m[5],
        ]
    }

    /// Points already on the template must produce the identity.
    #[test]
    fn an_exact_fit_is_the_identity() {
        let m = umeyama(&ARCFACE_TEMPLATE, &ARCFACE_TEMPLATE).unwrap();
        for (i, p) in ARCFACE_TEMPLATE.iter().enumerate() {
            let q = apply(&m, *p);
            assert!(
                approx(q[0], p[0], 1e-6) && approx(q[1], p[1], 1e-6),
                "{i}: {q:?}"
            );
        }
    }

    /// A rotate-scale-translate of the template must be recovered exactly: the
    /// transform family the estimator searches contains the answer.
    #[test]
    fn a_similarity_transform_is_recovered_exactly() {
        let (angle, scale, tx, ty) = (0.4_f64, 2.5_f64, -13.0_f64, 7.5_f64);
        let mut src = ARCFACE_TEMPLATE;
        for p in &mut src {
            let (x, y) = (p[0], p[1]);
            p[0] = scale * (x * angle.cos() - y * angle.sin()) + tx;
            p[1] = scale * (x * angle.sin() + y * angle.cos()) + ty;
        }
        let m = umeyama(&src, &ARCFACE_TEMPLATE).unwrap();
        for (i, p) in src.iter().enumerate() {
            let q = apply(&m, *p);
            let want = ARCFACE_TEMPLATE[i];
            assert!(
                approx(q[0], want[0], 1e-6) && approx(q[1], want[1], 1e-6),
                "{i}: {q:?} != {want:?}"
            );
        }
    }

    /// The fit is least-squares, so a mirrored input must *not* be fitted by
    /// flipping: a reflection would produce a mirror-image face crop, and the
    /// embedder would happily embed it.
    #[test]
    fn a_reflection_is_never_chosen() {
        let mut src = ARCFACE_TEMPLATE;
        for p in &mut src {
            p[0] = 112.0 - p[0];
        }
        let m = umeyama(&src, &ARCFACE_TEMPLATE).unwrap();
        // Positive determinant == orientation preserved.
        assert!(m[0] * m[4] - m[1] * m[3] > 0.0, "{m:?}");
    }

    #[test]
    fn degenerate_landmarks_are_refused_rather_than_dividing_by_zero() {
        let same = [[10.0, 10.0]; 5];
        assert!(umeyama(&same, &ARCFACE_TEMPLATE).is_none());
    }

    #[test]
    fn the_template_scales_with_the_embedder_input() {
        let t = template_for(224);
        assert!(approx(t[0][0], ARCFACE_TEMPLATE[0][0] * 2.0, 1e-9));
        assert_eq!(template_for(112), ARCFACE_TEMPLATE);
    }

    /// Sampling entirely inside a solid image reproduces it; sampling off the
    /// edge fades to the constant border rather than repeating an edge pixel.
    #[test]
    fn the_border_is_constant_black() {
        let src = RgbImage::from_pixel(8, 8, Rgb([200, 100, 50]));
        // Identity: the top-left 4×4 is the image, the rest is off the edge.
        let m: Affine = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0];
        let out = warp_affine(&src, &m, 16).unwrap();
        assert_eq!(*out.get_pixel(0, 0), Rgb([200, 100, 50]));
        assert_eq!(*out.get_pixel(7, 7), Rgb([200, 100, 50]));
        assert_eq!(*out.get_pixel(8, 8), Rgb([0, 0, 0]));
        assert_eq!(*out.get_pixel(15, 0), Rgb([0, 0, 0]));
    }

    /// A half-pixel shift of a two-tone image must land exactly halfway.
    #[test]
    fn bilinear_weights_are_exact_at_a_half_pixel() {
        let mut src = RgbImage::new(2, 1);
        src.put_pixel(0, 0, Rgb([0, 0, 0]));
        src.put_pixel(1, 0, Rgb([100, 100, 100]));
        // Destination x maps to source x + 0.5.
        let m: Affine = [1.0, 0.0, -0.5, 0.0, 1.0, 0.0];
        let out = warp_affine(&src, &m, 1).unwrap();
        assert_eq!(*out.get_pixel(0, 0), Rgb([50, 50, 50]));
    }

    #[test]
    fn a_non_invertible_transform_is_refused() {
        let src = RgbImage::new(4, 4);
        assert!(warp_affine(&src, &[0.0, 0.0, 0.0, 0.0, 0.0, 0.0], 4).is_none());
    }

    /// The whole point: the five landmarks must land on the template, whatever
    /// rotation and scale the face was at in the original.
    #[test]
    fn aligning_puts_the_landmarks_on_the_template() {
        let src = RgbImage::from_pixel(400, 400, Rgb([10, 20, 30]));
        // A face rotated 20° and about a third of the template's scale.
        let (angle, scale, tx, ty) = (0.35_f64, 0.4_f64, 120.0_f64, 90.0_f64);
        let mut landmarks = [[0.0f32; 2]; 5];
        for (i, p) in ARCFACE_TEMPLATE.iter().enumerate() {
            let (x, y) = (p[0], p[1]);
            landmarks[i] = [
                (scale * (x * angle.cos() - y * angle.sin()) + tx) as f32,
                (scale * (x * angle.sin() + y * angle.cos()) + ty) as f32,
            ];
        }
        let mut pts = [[0.0f64; 2]; 5];
        for (i, p) in landmarks.iter().enumerate() {
            pts[i] = [f64::from(p[0]), f64::from(p[1])];
        }
        let m = umeyama(&pts, &template_for(112)).unwrap();
        for (i, p) in pts.iter().enumerate() {
            let q = apply(&m, *p);
            assert!(
                approx(q[0], ARCFACE_TEMPLATE[i][0], 1e-4)
                    && approx(q[1], ARCFACE_TEMPLATE[i][1], 1e-4),
                "{i}: {q:?}"
            );
        }
        assert_eq!(
            align_crop(&src, &landmarks, 112).unwrap().dimensions(),
            (112, 112)
        );
    }

    #[test]
    fn the_aligned_tensor_has_the_embedders_shape() {
        let src = RgbImage::from_pixel(200, 200, Rgb([255, 0, 0]));
        let landmarks = [
            [60.0, 70.0],
            [100.0, 70.0],
            [80.0, 90.0],
            [65.0, 110.0],
            [95.0, 110.0],
        ];
        let t = align_tensor(&src, &landmarks, 112, &[0.5; 3], &[0.5; 3]).unwrap();
        assert_eq!(t.shape, [1, 3, 112, 112]);
        // Red channel saturated → (1.0 - 0.5) / 0.5 == 1.0 in the middle.
        assert!((t.data[112 * 56 + 56] - 1.0).abs() < 1e-5);
    }

    #[test]
    fn non_finite_landmarks_are_refused() {
        let src = RgbImage::new(10, 10);
        let landmarks = [
            [f32::NAN, 0.0],
            [1.0, 1.0],
            [2.0, 2.0],
            [3.0, 3.0],
            [4.0, 4.0],
        ];
        assert!(align_crop(&src, &landmarks, 112).is_err());
    }
}
