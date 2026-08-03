//! The face pipeline against the **real** shipped models.
//!
//! Every test here is `#[ignore]`d, for the same reason the model pack is
//! git-ignored: SCRFD-500M and w600k_mbf are 16 MB that nobody should have to
//! download to run `cargo test`. They are not optional in spirit — they are the
//! only tests that can catch a wrong output name, a transposed landmark order,
//! a letterbox that disagrees with the anchor grid, or a threshold that no
//! longer separates anybody. The committed `facepack` proves the plumbing; this
//! file proves the plumbing is connected to something that works.
//!
//! ```sh
//! scripts/build_model_pack/build_pack.py --only-faces \
//!     --out build/model_packs --version mobileclip-s2-v1
//! cargo test -p gallery-ml --test face_real_models -- --ignored --nocapture
//! ```
//!
//! The pack is found at `build/model_packs/mobileclip-s2-v1` relative to the
//! repo root, or wherever `GALLERY_ML_PACK_DIR` points. A test whose pack is
//! missing **fails** rather than passing quietly: an ignored test that silently
//! does nothing is worse than no test, because it reads as coverage.

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use common::fixture;
use gallery_ml::encoder::{ImageEncoder, OrtEncoder, OrtModel};
use gallery_ml::face::align::align_tensor;
use gallery_ml::face::detect::FaceDetector;
use gallery_ml::face::{cosine, quality};
use gallery_ml::pack::normalize;
use gallery_ml::preprocess::decode_oriented;
use gallery_ml::ModelPack;

/// Landmarks recorded from this detector on `face.jpg`, and asserted by
/// `face_golden.rs` as the aligner's input. Restated here so a detector change
/// that moves them fails *this* test rather than silently rewriting the golden.
const FACE_LANDMARKS: [[f32; 2]; 5] = [
    [102.2711, 50.3155],
    [123.243, 51.5941],
    [111.9766, 64.0229],
    [101.3213, 69.4995],
    [122.9366, 70.6163],
];
const FACE_BBOX: [f32; 4] = [90.424, 29.755, 135.534, 89.402];
const FACE_SCORE: f32 = 0.8138;

fn real_pack_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("GALLERY_ML_PACK_DIR") {
        return PathBuf::from(dir);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build/model_packs/mobileclip-s2-v1")
}

fn real_pack() -> ModelPack {
    let dir = real_pack_dir();
    ModelPack::load(&dir).unwrap_or_else(|e| {
        panic!(
            "the real model pack is not at {}: {e}\n\
             build it with `scripts/build_model_pack/build_pack.py --only-faces \
             --out build/model_packs --version mobileclip-s2-v1`, or point \
             GALLERY_ML_PACK_DIR somewhere else",
            dir.display()
        )
    })
}

struct Models {
    pack: ModelPack,
    detector: FaceDetector,
    embedder: OrtEncoder,
}

impl Models {
    fn load() -> Models {
        let pack = real_pack();
        let faces = pack
            .faces()
            .expect("the pack must ship face models")
            .clone();
        let bytes = pack.load_face_models().unwrap();
        let detector = FaceDetector::new(
            Arc::new(OrtModel::new(&bytes.detector, 1).unwrap()),
            faces.detector,
        );
        let embedder = OrtEncoder::new(
            &bytes.embedder,
            &faces.embedder.input_name,
            &faces.embedder.output_name,
            faces.embedder.input_size,
            faces.embedder.embedding_dim,
            1,
        )
        .unwrap();
        Models {
            pack,
            detector,
            embedder,
        }
    }

    fn embed(&self, rgb: &image::RgbImage, landmarks: &[[f32; 2]; 5]) -> Vec<f32> {
        let spec = &self.pack.faces().unwrap().embedder;
        let tensor = align_tensor(rgb, landmarks, spec.input_size, &spec.mean, &spec.std).unwrap();
        normalize(&self.embedder.embed(&tensor).unwrap()).unwrap()
    }

    /// Best face in an image, or `None`.
    fn best(&self, name: &str, rgb: &image::RgbImage) -> Option<gallery_ml::Detection> {
        self.detector.detect(name, rgb).unwrap().into_iter().next()
    }
}

fn decode(name: &str) -> image::RgbImage {
    decode_oriented(name, &fixture(name)).unwrap()
}

/// Re-encode at a different size and JPEG quality: the same identity as far as
/// a person is concerned, a different set of pixels as far as the model is.
fn reencode(rgb: &image::RgbImage, scale: f64, quality: u8) -> image::RgbImage {
    let (w, h) = (
        (f64::from(rgb.width()) * scale) as u32,
        (f64::from(rgb.height()) * scale) as u32,
    );
    let resized = image::imageops::resize(rgb, w, h, image::imageops::FilterType::Triangle);
    let mut bytes = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, quality)
        .encode_image(&image::DynamicImage::ImageRgb8(resized))
        .unwrap();
    decode_oriented("reencoded.jpg", &bytes).unwrap()
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn the_detector_finds_the_fixture_face_where_it_was_recorded() {
    let models = Models::load();
    let rgb = decode("face.jpg");
    let faces = models.detector.detect("face.jpg", &rgb).unwrap();
    assert_eq!(faces.len(), 1, "expected exactly one face, got {faces:?}");

    let face = &faces[0];
    assert!(
        (face.score - FACE_SCORE).abs() < 0.02,
        "score {} drifted from the recorded {FACE_SCORE}",
        face.score
    );
    for (i, (got, want)) in face.bbox.iter().zip(FACE_BBOX).enumerate() {
        assert!(
            (got - want).abs() < 1.5,
            "bbox[{i}] = {got} vs recorded {want}"
        );
    }
    for (i, p) in face.landmarks.iter().enumerate() {
        assert!(
            (p[0] - FACE_LANDMARKS[i][0]).abs() < 1.0 && (p[1] - FACE_LANDMARKS[i][1]).abs() < 1.0,
            "landmark {i} = {p:?} vs recorded {:?}",
            FACE_LANDMARKS[i]
        );
    }
    // The landmark *order* is the contract the aligner depends on, and a
    // detector swap is exactly how it would break.
    assert!(
        face.landmarks[0][0] < face.landmarks[1][0],
        "eyes are swapped"
    );
    assert!(
        face.landmarks[0][1] < face.landmarks[3][1],
        "eye below mouth"
    );

    let q = quality(face, rgb.width(), rgb.height());
    assert!(q > 0.5, "a clear frontal portrait scored {q}");
}

#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn photos_with_no_people_produce_no_faces() {
    let models = Models::load();
    for name in ["gradient.jpg", "stripes.jpg", "meadow.png"] {
        let rgb = decode(name);
        let faces = models.detector.detect(name, &rgb).unwrap();
        assert!(faces.is_empty(), "{name} hallucinated {faces:?}");
    }
}

#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn detection_is_repeatable_to_the_bit() {
    let models = Models::load();
    let rgb = decode("face.jpg");
    let first = models.detector.detect("face.jpg", &rgb).unwrap();
    for _ in 0..3 {
        assert_eq!(models.detector.detect("face.jpg", &rgb).unwrap(), first);
    }
}

// ---------------------------------------------------------------------------
// Embedding, and what the thresholds are worth
// ---------------------------------------------------------------------------

#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn the_embedder_produces_a_unit_512_vector() {
    let models = Models::load();
    let rgb = decode("face.jpg");
    let embedding = models.embed(&rgb, &FACE_LANDMARKS);
    assert_eq!(embedding.len(), 512);
    let norm: f64 = embedding
        .iter()
        .map(|v| f64::from(*v) * f64::from(*v))
        .sum();
    assert!((norm - 1.0).abs() < 1e-5, "|v|^2 = {norm}");
    // Same input, same vector — no scheduling-dependent reductions.
    assert_eq!(models.embed(&rgb, &FACE_LANDMARKS), embedding);
}

/// The property `T_join` is set against: the same person, put through the
/// imaging pipeline the app actually subjects photos to, must stay far above
/// the threshold.
#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn one_identity_survives_the_imaging_pipeline() {
    let models = Models::load();
    let cfg = models.pack.faces().unwrap().clustering;
    let rgb = decode("face.jpg");
    let reference = models.embed(&rgb, &FACE_LANDMARKS);

    // The fixture is 256×256 and its face is 45 px across, so the sweep stops
    // at 0.7: below that the box falls under the pack's 24 px floor and the
    // detector is *supposed* to drop it (see the test below). A real 12 MP
    // photo has an order of magnitude more room.
    let mut worst = 1.0f32;
    for (scale, jpeg_quality) in [(1.0, 60u8), (0.85, 75), (0.7, 90)] {
        let variant = reencode(&rgb, scale, jpeg_quality);
        let Some(face) = models.best("variant", &variant) else {
            panic!("the detector lost the face at scale {scale}, quality {jpeg_quality}");
        };
        let sim = cosine(&reference, &models.embed(&variant, &face.landmarks));
        println!("  scale {scale:>4} q{jpeg_quality:<3} cosine {sim:.4}");
        assert!(
            sim > cfg.auto,
            "scale {scale}, quality {jpeg_quality}: cosine {sim:.4} is below \
             the auto-tag threshold {} — the same photo would not auto-match \
             its own person",
            cfg.auto
        );
        worst = worst.min(sim);
    }
    println!(
        "worst same-identity cosine: {worst:.4} (auto {}, join {})",
        cfg.auto, cfg.join
    );
}

/// The floor exists so a 20-pixel face does not get an embedding that looks
/// like evidence. This is where it bites.
#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn the_pixel_floor_drops_a_face_that_has_become_too_small() {
    let models = Models::load();
    let floor = models.pack.faces().unwrap().detector.min_face_pixels;
    let rgb = decode("face.jpg");

    let full = models.best("face.jpg", &rgb).expect("the full-size face");
    assert!(full.width().min(full.height()) >= floor);

    // Half size puts the 45×60 box at 22×30 — under the floor on its short
    // side, so the detector reports nothing rather than a face made of 22
    // pixels stretched to 112.
    let half = reencode(&rgb, 0.5, 90);
    assert!(
        models.best("half", &half).is_none(),
        "a sub-floor face was kept; the floor is {floor} px"
    );
}

/// The other half: a face and *not that face* must land far below the join
/// threshold, or clustering would fuse the library into one person.
///
/// Two committed fixtures, two real people: `face.jpg` is NASA's portrait of
/// Eileen Collins and `face2.jpg` is scikit-image's `camera()` (CC0). Both are
/// public domain, which is why this can be a plain test instead of one that
/// asks the runner to go and find a face dataset.
#[test]
#[ignore = "needs the real model pack; see the module docs"]
fn distinct_identities_land_far_below_the_join_threshold() {
    let models = Models::load();
    let cfg = models.pack.faces().unwrap().clustering;

    let mut identities: Vec<(&str, Vec<f32>)> = Vec::new();
    for name in ["face.jpg", "face2.jpg"] {
        let rgb = decode(name);
        let face = models
            .best(name, &rgb)
            .unwrap_or_else(|| panic!("no face found in {name}"));
        identities.push((name, models.embed(&rgb, &face.landmarks)));
    }

    let sim = cosine(&identities[0].1, &identities[1].1);
    println!(
        "{} vs {}: {sim:.4} (join {}, margin {:.4})",
        identities[0].0,
        identities[1].0,
        cfg.join,
        cfg.join - sim
    );
    assert!(
        sim < cfg.join,
        "two different people score {sim:.4}, at or above the join threshold {}",
        cfg.join
    );
    // And the margin is not a coincidence of one pair being unusually easy:
    // a threshold that only just holds is a threshold about to stop holding.
    assert!(
        cfg.join - sim > 0.2,
        "cross-identity margin is only {:.4}",
        cfg.join - sim
    );
}

// ---------------------------------------------------------------------------
// Throughput
// ---------------------------------------------------------------------------

/// Faces per second on this machine, for the perf baseline.
///
/// Not an assertion: the numbers are machine-specific. It reports detection
/// (which runs once per photo, whatever is in it) and embedding (which runs
/// once per face) separately, because a library of group shots and a library of
/// landscapes have completely different costs and one number would hide that.
#[test]
#[ignore = "perf probe: slow, machine-specific"]
fn perf_probe_detection_and_embedding() {
    use std::time::Instant;

    let models = Models::load();
    let rgb = decode("face.jpg");
    // A camera-sized photo, so the letterbox resize is honest about its cost.
    let big = image::imageops::resize(&rgb, 4032, 4032, image::imageops::FilterType::Triangle);

    for (label, image) in [("256x256", &rgb), ("4032x4032", &big)] {
        let n = if image.width() > 1000 { 8 } else { 40 };
        let t = Instant::now();
        for _ in 0..n {
            models.detector.detect("perf", image).unwrap();
        }
        let secs = t.elapsed().as_secs_f64();
        println!(
            "detect {label}: {:.1} photos/s ({:.1} ms each)",
            n as f64 / secs,
            secs / n as f64 * 1e3
        );
    }

    let n = 40;
    let t = Instant::now();
    for _ in 0..n {
        models.embed(&rgb, &FACE_LANDMARKS);
    }
    let secs = t.elapsed().as_secs_f64();
    println!(
        "align + embed: {:.1} faces/s ({:.1} ms each)",
        n as f64 / secs,
        secs / n as f64 * 1e3
    );
}
