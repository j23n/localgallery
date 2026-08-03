//! Golden tensors and geometry for the face alignment path.
//!
//! # What the golden hash pins
//!
//! The SHA-256 of the little-endian `f32` bytes of the aligned `112 × 112`
//! tensor — so the entire chain at once: the JPEG decode, the Umeyama fit from
//! five landmarks, the inverse-mapped bilinear warp, the `u8` rounding, and the
//! mean/std normalization. Any of those moving changes the hash.
//!
//! # Policy
//!
//! Same as `preprocess_golden.rs`, and for the same reason: a diff here means
//! every face embedding cached on every device is stale.
//!
//! 1. Confirm the change is intended.
//! 2. Bump [`gallery_ml::ALIGN_VERSION`]. That is what invalidates the face
//!    rows — the content hash cannot see an alignment change.
//! 3. Update the constant in the same commit, and say why in the message.
//!
//! # Why the landmarks are hard-coded
//!
//! They came from a real SCRFD-500M detection on this exact committed fixture,
//! recorded once and frozen here. Hard-coding them is deliberate: this file
//! tests the *aligner*, and making it depend on the detector would mean a
//! detector change silently rewriting the aligner's golden. The
//! `#[ignore]`d tests in `face_real_models.rs` are where the detector's own
//! output is checked, and they assert these same numbers — so the two stay
//! tied together without either owning the other.
//!
//! # Architecture scope
//!
//! Unlike the preprocessing goldens, nothing here goes through
//! `fast_image_resize`: the warp is this crate's own scalar `f64` loop. So this
//! hash is **not** architecture-specific, and an x86-64 port must reproduce it
//! exactly.

mod common;

use common::{fixture, sha256_hex};
use gallery_ml::face::align::{align_crop, align_tensor, template_for, umeyama};
use gallery_ml::preprocess::decode_oriented;

/// `face.jpg` is `skimage.data.astronaut()` (NASA, public domain) at 256×256.
const FACE_FIXTURE: &str = "face.jpg";

/// Landmarks SCRFD-500M produced for [`FACE_FIXTURE`]: left eye, right eye,
/// nose, left mouth corner, right mouth corner, in image pixels.
const FACE_LANDMARKS: [[f32; 2]; 5] = [
    [102.2711, 50.3155],
    [123.243, 51.5941],
    [111.9766, 64.0229],
    [101.3213, 69.4995],
    [122.9366, 70.6163],
];

/// The face's bounding box in the same detection, for the geometry checks.
const FACE_BBOX: [f32; 4] = [90.424, 29.755, 135.534, 89.402];

/// SHA-256 of the aligned 112×112 tensor's little-endian f32 bytes, under the
/// ArcFace normalization (`mean = std = 0.5`, i.e. `[-1, 1]`).
const FACE_ALIGNED_112_SHA256: &str =
    "153be12698da02a83338ca2afa7a1f65e23b8f5a17ab5250e1e91c866452c73c";

/// SHA-256 of the raw `u8` RGB bytes of the same crop, before normalization.
///
/// Pinned separately so a failure says *which* half moved: the warp, or the
/// arithmetic that turns its pixels into a tensor.
const FACE_ALIGNED_112_RGB_SHA256: &str =
    "c5f9af04fb29e7125c1e4da2d3b144146d6b1d12de9cba95896a0b5ee42736fa";

fn face_image() -> image::RgbImage {
    decode_oriented(FACE_FIXTURE, &fixture(FACE_FIXTURE)).expect("fixture must decode")
}

#[test]
fn the_aligned_face_crop_is_byte_stable() {
    let crop = align_crop(&face_image(), &FACE_LANDMARKS, 112).unwrap();
    assert_eq!(crop.dimensions(), (112, 112));
    assert_eq!(sha256_hex(crop.as_raw()), FACE_ALIGNED_112_RGB_SHA256);
}

#[test]
fn the_aligned_face_tensor_is_byte_stable() {
    let tensor = align_tensor(&face_image(), &FACE_LANDMARKS, 112, &[0.5; 3], &[0.5; 3]).unwrap();
    assert_eq!(tensor.shape, [1, 3, 112, 112]);
    assert_eq!(sha256_hex(&tensor.to_le_bytes()), FACE_ALIGNED_112_SHA256);
}

/// The transform `skimage.transform.SimilarityTransform` produces for
/// [`FACE_LANDMARKS`] — which is what insightface's `estimate_norm` calls, and
/// therefore what the embedder's training crops were made with.
///
/// This is the cross-implementation parity contract: our closed-form 2-D
/// Umeyama has to agree with the reference stack, not merely be self-consistent.
const REFERENCE_TRANSFORM: [f64; 6] = [
    1.759_691_74,
    0.087_203_39,
    -147.012_404,
    -0.087_203_39,
    1.759_691_74,
    -26.012_076,
];

/// Our fit must be the reference stack's fit.
///
/// The tolerance is 1e-4, which is three orders of magnitude tighter than the
/// residual below — the two implementations agree to the precision the
/// landmarks were recorded at (4 decimal places), and the remaining difference
/// is that rounding, not the estimator.
#[test]
fn the_fit_matches_the_reference_implementation() {
    let src = FACE_LANDMARKS.map(|p| [f64::from(p[0]), f64::from(p[1])]);
    let m = umeyama(&src, &template_for(112)).unwrap();
    for i in 0..6 {
        assert!(
            (m[i] - REFERENCE_TRANSFORM[i]).abs() < 1e-4,
            "coefficient {i}: {} vs reference {}",
            m[i],
            REFERENCE_TRANSFORM[i]
        );
    }
}

/// A real face is not the template: five points fitted with four parameters
/// leaves a residual, and this pins how big it is allowed to get.
///
/// It is not a tolerance to relax when something drifts. A fit whose residual
/// grows means the landmarks moved or the estimator stopped minimizing, and
/// both change every embedding downstream. Measured: RMS 4.99 px, worst point
/// 6.7 px, on a face whose interocular distance is 21 px — the template's mouth
/// is wider and lower than this subject's.
#[test]
fn the_fit_residual_stays_where_it_was_measured() {
    let src = FACE_LANDMARKS.map(|p| [f64::from(p[0]), f64::from(p[1])]);
    let template = template_for(112);
    let m = umeyama(&src, &template).unwrap();
    let mut sum_sq = 0.0;
    let mut worst: f64 = 0.0;
    for (i, p) in src.iter().enumerate() {
        let x = m[0] * p[0] + m[1] * p[1] + m[2];
        let y = m[3] * p[0] + m[4] * p[1] + m[5];
        let d = (x - template[i][0]).hypot(y - template[i][1]);
        sum_sq += d * d;
        worst = worst.max(d);
    }
    let rms = (sum_sq / 5.0).sqrt();
    assert!(rms < 5.5, "fit RMS residual {rms:.3} px");
    assert!(worst < 8.0, "worst landmark residual {worst:.3} px");
}

/// The crop must actually contain the face, not a plausible-looking region
/// somewhere else — a sign error in the inverse map produces exactly that and
/// would otherwise only show up as bad clustering.
#[test]
fn the_crop_covers_the_detected_face() {
    let image = face_image();
    let crop = align_crop(&image, &FACE_LANDMARKS, 112).unwrap();

    // Sample the source at the nose landmark and the crop at the template's
    // nose position. The warp resamples, so this is a colour-neighbourhood
    // check rather than an equality.
    let nose = FACE_LANDMARKS[2];
    let source = *image.get_pixel(nose[0] as u32, nose[1] as u32);
    let template = template_for(112)[2];
    let mapped = *crop.get_pixel(template[0] as u32, template[1] as u32);
    for c in 0..3 {
        let delta = i32::from(source[c]) - i32::from(mapped[c]);
        assert!(
            delta.abs() < 24,
            "channel {c}: source {:?} vs crop {:?}",
            source,
            mapped
        );
    }

    // And the crop is not black: a warp that mapped everything off the edge
    // would still be 112×112 and would still hash stably.
    let mean: f64 =
        crop.as_raw().iter().map(|v| f64::from(*v)).sum::<f64>() / crop.as_raw().len() as f64;
    assert!(mean > 20.0, "aligned crop is nearly black (mean {mean:.1})");
}

/// Scaling the template must scale the crop, not re-frame it.
#[test]
fn a_larger_embedder_input_produces_the_same_framing() {
    let image = face_image();
    let small = align_crop(&image, &FACE_LANDMARKS, 112).unwrap();
    let large = align_crop(&image, &FACE_LANDMARKS, 224).unwrap();
    assert_eq!(large.dimensions(), (224, 224));
    // Corresponding pixels (2× apart) should be close: same framing, finer
    // sampling.
    for (x, y) in [(20u32, 20u32), (56, 56), (90, 30)] {
        let a = small.get_pixel(x, y);
        let b = large.get_pixel(x * 2, y * 2);
        for c in 0..3 {
            let delta = i32::from(a[c]) - i32::from(b[c]);
            assert!(delta.abs() < 32, "({x},{y}) channel {c}: {a:?} vs {b:?}");
        }
    }
}

/// The detection this file's landmarks came from, restated so the numbers are
/// checkable against the fixture rather than merely present.
#[test]
fn the_recorded_detection_is_self_consistent() {
    let image = face_image();
    assert_eq!(image.dimensions(), (256, 256));
    for p in FACE_LANDMARKS {
        assert!(
            p[0] >= FACE_BBOX[0] && p[0] <= FACE_BBOX[2],
            "landmark {p:?} is outside the recorded box"
        );
        assert!(p[1] >= FACE_BBOX[1] && p[1] <= FACE_BBOX[3]);
    }
    // Eyes above nose above mouth, and the left eye left of the right eye:
    // the ordering contract the ArcFace template depends on.
    assert!(FACE_LANDMARKS[0][0] < FACE_LANDMARKS[1][0]);
    assert!(FACE_LANDMARKS[0][1] < FACE_LANDMARKS[2][1]);
    assert!(FACE_LANDMARKS[2][1] < FACE_LANDMARKS[3][1]);
}
