//! Golden tensors for the pinned preprocessing path.
//!
//! # What a golden hash here actually pins
//!
//! The SHA-256 of the little-endian f32 tensor bytes — so every stage at once:
//! the JPEG/PNG decoder's output, the EXIF orientation transform, the resize
//! kernel and its rounding, the crop origin, the channel order, and the
//! normalization arithmetic. Any of those moving changes the hash.
//!
//! # Policy
//!
//! These constants are **not** free to update. A diff here means the
//! preprocessing changed, which means every embedding cached on every device
//! is now stale and every score has moved. The procedure is:
//!
//! 1. Confirm the change is intended (a dependency bump, a kernel change).
//! 2. Bump [`gallery_ml::PREPROCESS_VERSION`]. That is what invalidates the
//!    embedding cache — the content hash cannot see a preprocessing change.
//! 3. Update these constants in the same commit, and say why in the message.
//!
//! # Architecture scope
//!
//! `fast_image_resize` dispatches on CPU features, so these hashes are pinned
//! to `aarch64`/NEON — every Apple target this program builds for (device,
//! simulator, Mac). An x86-64 port regenerates them; it does not get to
//! silently disagree, because this test would fail first.

mod common;

use common::{fixture, sha256_hex};
use gallery_ml::preprocess::{
    preprocess, read_exif_orientation, tensor_from_rgb, PreprocessConfig, ResizeFilter,
};

/// The config the committed test pack declares. Restated rather than loaded so
/// a change to the pack cannot silently move the goldens.
fn test_pack_config() -> PreprocessConfig {
    PreprocessConfig {
        input_size: 64,
        mean: [0.5, 0.5, 0.5],
        std: [0.5, 0.5, 0.5],
        filter: ResizeFilter::CatmullRom,
    }
}

const GRADIENT_JPG_TENSOR_SHA256: &str =
    "1edfb12c576405e304bde3b56df57d1cfd75cf1acb60929ff1e0b6a1242eea7e";
const STRIPES_JPG_TENSOR_SHA256: &str =
    "97b76d469e1b58dcc9e9dd2b98607c9e755f5cf45a9791eec75eb9f0b4cade4f";
const MEADOW_PNG_TENSOR_SHA256: &str =
    "5e8ff3d5ef8fa39866afd76ea41269e4333a065e39dd496da7820a7727713b32";
/// CLIP-style 224 input over the same JPEG — pins the geometry at the size the
/// real pack will use, not just at the test pack's 64.
const GRADIENT_JPG_224_LANCZOS_SHA256: &str =
    "2a0781e311d345de23bc77ddefa34b909dba04ebff3a3c86b9393ba2906c2878";

fn tensor_sha(name: &str, cfg: &PreprocessConfig) -> String {
    let bytes = fixture(name);
    let tensor = preprocess(name, &bytes, cfg).expect("fixture must preprocess");
    assert_eq!(
        tensor.shape,
        [1, 3, cfg.input_size as usize, cfg.input_size as usize]
    );
    sha256_hex(&tensor.to_le_bytes())
}

#[test]
fn gradient_jpeg_tensor_is_byte_stable() {
    assert_eq!(
        tensor_sha("gradient.jpg", &test_pack_config()),
        GRADIENT_JPG_TENSOR_SHA256
    );
}

#[test]
fn stripes_jpeg_tensor_is_byte_stable() {
    assert_eq!(
        tensor_sha("stripes.jpg", &test_pack_config()),
        STRIPES_JPG_TENSOR_SHA256
    );
}

#[test]
fn meadow_png_tensor_is_byte_stable() {
    assert_eq!(
        tensor_sha("meadow.png", &test_pack_config()),
        MEADOW_PNG_TENSOR_SHA256
    );
}

#[test]
fn clip_sized_tensor_is_byte_stable() {
    let cfg = PreprocessConfig {
        input_size: 224,
        filter: ResizeFilter::Lanczos3,
        ..PreprocessConfig::default()
    };
    assert_eq!(
        tensor_sha("gradient.jpg", &cfg),
        GRADIENT_JPG_224_LANCZOS_SHA256
    );
}

#[test]
fn preprocessing_is_reproducible_within_a_process() {
    let cfg = test_pack_config();
    let a = tensor_sha("gradient.jpg", &cfg);
    let b = tensor_sha("gradient.jpg", &cfg);
    assert_eq!(a, b);
}

#[test]
fn exif_orientation_is_read_from_a_png_exif_chunk() {
    assert_eq!(read_exif_orientation(&fixture("orient_6.png")), Some(6));
    assert_eq!(read_exif_orientation(&fixture("orient_none.png")), None);
}

#[test]
fn exif_orientation_is_actually_applied() {
    // `orient_6.png` and `orient_pre.png` hold the same picture: one as
    // unrotated pixels plus an Orientation=6 tag, the other pre-rotated with
    // no tag. PNG is lossless, so an orientation-aware pipeline must produce
    // *identical* tensors — which is a far stronger statement than "the
    // tensors differ when the tag is present".
    let cfg = test_pack_config();
    assert_eq!(
        tensor_sha("orient_6.png", &cfg),
        tensor_sha("orient_pre.png", &cfg),
        "EXIF orientation 6 was not applied"
    );
    assert_ne!(
        tensor_sha("orient_6.png", &cfg),
        tensor_sha("orient_none.png", &cfg),
        "orientation made no difference — is the tag being read at all?"
    );
}

#[test]
fn a_non_square_source_is_center_cropped_not_squashed() {
    // A 3:1 source must have its left and right margins *cropped away*, not
    // squashed into the square. Paint the outer thirds black and the middle
    // third white: a correct center crop is uniformly white, while an
    // aspect-squashing resize would drag the black in.
    let cfg = PreprocessConfig {
        input_size: 8,
        mean: [0.0; 3],
        std: [1.0; 3],
        filter: ResizeFilter::Box,
    };
    let wide = image::RgbImage::from_fn(24, 8, |x, _| {
        // Black outside the centre third, white inside it.
        if (8..16).contains(&x) {
            image::Rgb([255, 255, 255])
        } else {
            image::Rgb([0, 0, 0])
        }
    });
    let t = tensor_from_rgb("wide", wide, &cfg).unwrap();
    // Every pixel of the crop is inside the white band.
    assert!(
        t.data.iter().all(|v| *v > 0.99),
        "center crop picked up the black margins"
    );
}
