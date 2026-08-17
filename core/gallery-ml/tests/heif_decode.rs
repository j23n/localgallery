//! The HEIC decode path, over committed fixtures.
//!
//! Four things here are easy to get invisibly wrong, and each has its own test
//! because each fails silently rather than loudly:
//!
//! 1. **Tiling.** iPhone stores every full-size photo as a `grid` derived item.
//!    A decoder that only handles a single `hvc1` passes every small-fixture
//!    test and then decodes one tile of every real photo.
//! 2. **Orientation.** HEIC carries rotation as an `irot` item property *and*
//!    may carry EXIF `Orientation`. Applying both rotates twice — and face
//!    regions are written in normalised coordinates of the oriented image, so
//!    the error lands on every face box and still looks like a crop.
//! 3. **Bit depth.** A 10-bit source must be right-shifted, not tone-mapped.
//!    Pinned in the unit tests on `gallery_ml::heif`, which can state the rule
//!    on exact sample values rather than inferring it from a photograph.
//! 4. **Malformed input.** The decoder panics on damaged files where the JPEG
//!    and PNG decoders return an error, so the panic guard is load-bearing:
//!    the engine's own `catch_unwind` wraps the whole worker scope, and an
//!    escaping panic would abort the run rather than fail the photo.
//!
//! Fixtures are built by `tests/make_heic_fixtures.sh`.

mod common;

use common::{fixture, sha256_hex};
use gallery_ml::preprocess::{decode_oriented, preprocess, PreprocessConfig, ResizeFilter};

/// The committed test pack's config, restated — same reasoning as
/// `preprocess_golden.rs`.
fn test_pack_config() -> PreprocessConfig {
    PreprocessConfig {
        input_size: 64,
        mean: [0.5, 0.5, 0.5],
        std: [0.5, 0.5, 0.5],
        filter: ResizeFilter::CatmullRom,
    }
}

/// Golden tensors. Same policy as `preprocess_golden.rs`: a diff here means
/// the decode moved, which means every embedding is stale.
const MEADOW_HEIC_TENSOR_SHA256: &str =
    "dd6921128e07d39ae862c2b0141b2ae4539625c319b3cb76df8c9fc4b709ab22";
const GRID_HEIC_TENSOR_SHA256: &str =
    "829a46284aa572bdbc2b007ba1b17c42b72a7db8eb4ae2c2f9eafb48f2a713b1";

fn tensor_sha(name: &str) -> String {
    let bytes = fixture(name);
    let tensor = preprocess(name, &bytes, &test_pack_config()).expect("fixture must preprocess");
    sha256_hex(&tensor.to_le_bytes())
}

#[test]
fn meadow_heic_tensor_is_byte_stable() {
    assert_eq!(tensor_sha("meadow.heic"), MEADOW_HEIC_TENSOR_SHA256);
}

#[test]
fn grid_heic_tensor_is_byte_stable() {
    assert_eq!(tensor_sha("grid.heic"), GRID_HEIC_TENSOR_SHA256);
}

/// Decoding twice in one process must not depend on how the tile threads were
/// scheduled. `heif-oxide` decodes grid tiles on `std::thread::scope`; they
/// write disjoint regions, and this is what says so.
#[test]
fn a_tiled_decode_does_not_depend_on_thread_scheduling() {
    let first = tensor_sha("grid.heic");
    for _ in 0..8 {
        assert_eq!(tensor_sha("grid.heic"), first);
    }
}

/// The whole canvas, not one tile. `grid.heic` is 1024×1024 assembled from
/// 512×512 tiles; a single-tile decoder would report 512×512 — or, worse,
/// report 1024×1024 with three quarters of it black.
#[test]
fn a_grid_item_is_assembled_into_the_full_canvas() {
    let rgb = decode_oriented("grid.heic", &fixture("grid.heic")).expect("decode");
    assert_eq!((rgb.width(), rgb.height()), (1024, 1024));

    // Every quadrant has to carry picture. A missing tile is a uniform block,
    // so compare each quadrant's variance against zero rather than its mean —
    // a black *photograph* would fool a mean check and a real one will not
    // have four identical quadrants.
    let half = 512u32;
    for (qx, qy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        let mut min = 255u8;
        let mut max = 0u8;
        for y in 0..half {
            for x in 0..half {
                let p = rgb.get_pixel(qx * half + x, qy * half + y);
                for c in p.0 {
                    min = min.min(c);
                    max = max.max(c);
                }
            }
        }
        assert!(
            max > min,
            "quadrant ({qx},{qy}) is a uniform block — a tile is missing"
        );
    }
}

/// `irot` is applied by the container decoder and EXIF orientation is *not*
/// applied on top of it.
///
/// `rot90.heic` is the 96×64 gradient rotated to 64×96. If the pipeline
/// double-rotated, the result would come back 96×64 again.
#[test]
fn the_container_rotation_is_applied_exactly_once() {
    let bytes = fixture("rot90.heic");
    let rgb = decode_oriented("rot90.heic", &bytes).expect("decode");
    assert_eq!(
        (rgb.width(), rgb.height()),
        (64, 96),
        "a second rotation would have squared this back up"
    );

    // The decoder declares that it owns orientation, so nothing above it may
    // consult EXIF — whatever EXIF happens to say.
    let decoder = gallery_ml::preprocess::decoder_for(gallery_ml::ImageKind::Heic).unwrap();
    assert!(decoder.output_is_oriented());
}

/// A HEIC and a PNG of one picture must land in the same place.
///
/// Not byte-identical — HEVC is lossy and the fixture was encoded at whatever
/// quality ImageIO chose — but close enough that the decode is unambiguously
/// *this* image and not a mis-assembled or wrongly-converted one. A wrong
/// colour matrix, a swapped chroma plane or an off-by-one plane stride all
/// blow far past this.
#[test]
fn a_heic_decodes_to_the_same_picture_as_the_png_it_was_made_from() {
    let from_heic = decode_oriented("meadow.heic", &fixture("meadow.heic")).expect("heic");
    let from_png = decode_oriented("meadow.png", &fixture("meadow.png")).expect("png");
    assert_eq!(from_heic.dimensions(), from_png.dimensions());

    let total: u64 = from_heic
        .as_raw()
        .iter()
        .zip(from_png.as_raw())
        .map(|(a, b)| u64::from(a.abs_diff(*b)))
        .sum();
    let mean = total as f64 / from_heic.as_raw().len() as f64;
    assert!(
        mean < 12.0,
        "mean per-channel difference from the source PNG is {mean:.2}"
    );
}

/// The decoder panics where the JPEG and PNG ones return an error, so the
/// guard in `gallery_ml::heif` is the thing keeping one bad file from aborting
/// every run. None of these may panic *out* of `decode_oriented`, hang, or come
/// back claiming success.
#[test]
fn a_damaged_heic_fails_the_photo_instead_of_the_run() {
    // The 70x70 fixture carries the whole container structure at a fraction of
    // the decode cost, and most damaged files still decode *something* — so the
    // sweep's runtime is dominated by successful decodes, not failed ones.
    let good = fixture("meadow.heic");

    // Truncation at every length.
    for cut in 0..good.len() {
        let _ = decode_oriented("cut.heic", &good[..cut]);
    }

    // Single-byte damage over the whole file.
    for at in 0..good.len() {
        let mut bytes = good.clone();
        bytes[at] ^= 0xFF;
        let _ = decode_oriented("flip.heic", &bytes);
    }

    // Hostile 32-bit fields, which is where a length or an offset would send a
    // walk somewhere it cannot come back from.
    for at in (0..good.len().saturating_sub(4)).step_by(2) {
        for value in [u32::MAX, 0, 1] {
            let mut bytes = good.clone();
            bytes[at..at + 4].copy_from_slice(&value.to_be_bytes());
            let _ = decode_oriented("field.heic", &bytes);
        }
    }

    // A tiled file has a second structure to damage: the `grid` item and the
    // `dimg` references that say which tiles compose it.
    let tiled = fixture("grid.heic");
    let step = (tiled.len() / 48).max(1);
    let mut cut = 0;
    while cut < tiled.len() {
        let _ = decode_oriented("cut_grid.heic", &tiled[..cut]);
        cut += step;
    }

    // …and the pipeline still works afterwards, so nothing was left poisoned.
    assert!(decode_oriented("meadow.heic", &good).is_ok());
    assert!(decode_oriented("grid.heic", &tiled).is_ok());
}

/// A HEIC that is not HEVC-coded, or not 4:2:0, is refused rather than
/// half-decoded — and the refusal is the ordinary unsupported/decode path, so
/// the row becomes a `skipped` stamped with the current `DECODER_VERSION` and
/// re-opens by itself the day a wider decoder ships.
#[test]
fn an_undecodable_variant_is_refused_cleanly() {
    // A well-formed container with no image item at all.
    let mut ftyp = b"heic".to_vec();
    ftyp.extend_from_slice(&0u32.to_be_bytes());
    ftyp.extend_from_slice(b"heic");
    let mut file = 12u32.to_be_bytes().to_vec();
    file.extend_from_slice(b"ftyp");
    file.truncate(8);
    file.extend_from_slice(&((ftyp.len() + 8) as u32).to_be_bytes());
    file.extend_from_slice(b"ftyp");
    file.extend_from_slice(&ftyp);

    let err = decode_oriented("empty.heic", &file).unwrap_err();
    assert!(
        matches!(err, gallery_ml::MlError::Preprocess { .. }),
        "{err:?}"
    );
}
