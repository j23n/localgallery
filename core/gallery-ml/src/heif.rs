//! HEIC/HEIF decode, behind [`crate::preprocess::ImageDecoder`].
//!
//! iPhones shoot HEIC by default, so on a library shot on a modern phone this
//! is not an edge case — it is most of the library, and until Phase 6 all of it
//! was recorded [`ErrorCode::UnsupportedFormat`] and skipped.
//!
//! # Why pure Rust, when the plan said libheif
//!
//! `_plans/08` recommended vendoring libheif + libde265 and recorded Option C
//! (pure Rust) as "no production-quality pure-Rust HEVC decoder … revisit if
//! that changes". It changed. `heif-oxide` (container) over `rust_h265`
//! (HEVC Main/Main10 4:2:0) decodes what this pipeline needs, and taking it
//! costs nothing the plan was trying to buy:
//!
//! - **Cross-compile.** No build script, no C, no CMake. Both iOS slices build
//!   from `cargo build --target …` with nothing installed. That was the plan's
//!   "riskiest hour" and it is now zero hours; `build_core.sh` is untouched.
//! - **Licence.** MIT OR Apache-2.0, against LGPL-3.0 for libheif and libde265.
//!   The plan flagged LGPL static linking as a documented future App Store
//!   constraint; there is now no constraint to document.
//! - **Doctrine.** Zero `unsafe` in either crate, no SIMD dispatch, no platform
//!   variance — *more* deterministic than the JPEG path, whose resize kernel is
//!   already architecture-selected. Verified: 25 decodes of each fixture are
//!   bit-identical, tiles are decoded on `std::thread::scope` into disjoint
//!   regions.
//! - **Reach.** Linux and Android get a decoder, which Option B (platform
//!   decode through `CGImageSource`) would have denied them.
//!
//! Checked against ImageIO on real files before adopting: an 8-bit 1920×1080
//! HEIC, a grid-tiled 4000×2250, and an `irot`-rotated one all land within
//! RMSE ≈ 1 of ImageIO's decode of the same bytes, which is chroma-upsampling
//! difference, not decode error — HEVC is bit-exact at the YUV level by
//! specification.
//!
//! # What it costs, and what is done about it
//!
//! 1. **It panics on malformed input.** Under an identical 10 705-case
//!    corruption sweep the `image` crate's JPEG and PNG decoders panicked zero
//!    times and this one panicked 1 388. The engine's own `catch_unwind` wraps
//!    the *whole worker scope*, so an unguarded panic here would abort the
//!    entire run — and the row would be re-claimed and abort the next one too.
//!    So [`HeifDecoder::decode`] catches it itself and reports
//!    [`ErrorCode::Decode`] for that one photo, which is exactly what a corrupt
//!    JPEG already does. A C decoder's equivalent failure is a segfault, which
//!    is not catchable at all.
//! 2. **4:2:0 only.** `rust_h265` decodes Main and Main 10, 4:2:0. Every iPhone
//!    photo is 4:2:0; a 4:4:4 file (macOS's own `DefaultDesktop.heic`, for
//!    instance) becomes a `skipped` row stamped with the current
//!    [`crate::preprocess::DECODER_VERSION`] — which is the mechanism
//!    `_plans/08` designed for exactly this, and it re-opens by itself the day
//!    a wider decoder ships.
//! 3. **Maturity.** Both crates are young. That is what
//!    [`crate::preprocess::ImageDecoder`] is for: swapping the backend is an
//!    `impl` and a `DECODER_VERSION` bump, and the bump re-opens the skipped
//!    rows without invalidating one cached embedding.

use std::panic::{catch_unwind, AssertUnwindSafe};

use image::{DynamicImage, RgbImage};

use crate::error::{ErrorCode, MlError, MlResult};
use crate::preprocess::{ImageDecoder, ImageKind, MAX_PIXELS};

/// The HEIC backend.
pub struct HeifDecoder;

pub(crate) static HEIF_DECODER: HeifDecoder = HeifDecoder;

impl ImageDecoder for HeifDecoder {
    fn decode(&self, path: &str, bytes: &[u8], _kind: ImageKind) -> MlResult<DynamicImage> {
        let bad = |detail: String| MlError::Preprocess {
            path: path.to_string(),
            code: ErrorCode::BadImage,
            detail,
        };

        // The container states its own dimensions, so the size guard runs
        // *before* the decoder is handed anything. `decode_oriented` checks the
        // decoded size too, but by then the buffer has been allocated — which
        // is the whole point of a malicious `ispe`.
        if let Some((w, h)) = gallery_meta::media::isobmff::max_declared_extent(bytes) {
            let pixels = u64::from(w) * u64::from(h);
            if pixels == 0 || pixels > MAX_PIXELS {
                return Err(bad(format!("container declares {w}×{h}")));
            }
        }

        // See the panic note on the module. `bytes` is a shared slice, so there
        // is no state for an unwind to leave inconsistent.
        let decoded = catch_unwind(AssertUnwindSafe(|| heif_oxide::decode_bytes(bytes)))
            .map_err(|_| MlError::Preprocess {
                path: path.to_string(),
                code: ErrorCode::Decode,
                detail: "the HEIF decoder panicked on this file".into(),
            })?
            .map_err(|e| MlError::Preprocess {
                path: path.to_string(),
                code: ErrorCode::Decode,
                detail: e.to_string(),
            })?;

        let (w, h) = (decoded.width, decoded.height);
        let expected = (w as usize)
            .checked_mul(h as usize)
            .and_then(|n| n.checked_mul(3))
            .ok_or_else(|| bad(format!("{w}×{h} overflows an RGB buffer")))?;

        let rgb = to_rgb8(&decoded.pixels);
        if rgb.len() != expected {
            return Err(bad(format!(
                "decoder returned {} bytes for {w}×{h}",
                rgb.len()
            )));
        }
        let image = RgbImage::from_raw(w, h, rgb)
            .ok_or_else(|| bad(format!("{w}×{h} is not a usable size")))?;
        Ok(DynamicImage::ImageRgb8(image))
    }

    fn backend_name(&self) -> &'static str {
        "heif-oxide"
    }

    /// **True**, and this is the orientation decision for HEIC.
    ///
    /// HEIC carries rotation twice: `irot`/`imir` in the item properties, and
    /// possibly an EXIF `Orientation` in the Exif item. `heif-oxide` applies the
    /// item transforms itself, so applying EXIF on top would rotate the image a
    /// second time. One decision, made here: **take the container's transform
    /// and ignore EXIF orientation for HEIC.**
    ///
    /// This matters well beyond a sideways thumbnail. Face regions are written
    /// in normalised coordinates of the *oriented* image, so a double rotation
    /// puts every box on the wrong part of every face — silently, because the
    /// crop still looks like a crop.
    fn output_is_oriented(&self) -> bool {
        true
    }
}

/// Flatten the decoder's pixels to 8-bit RGB.
///
/// **10- and 12-bit sources are right-shifted, never tone-mapped.** `heif-oxide`
/// hands deep sources back as 16-bit samples spanning the full `0..=65535`
/// range, and this takes the top 8 bits of each. A tone map is where a
/// platform-specific curve would get back in, and it would make an HDR photo's
/// tags a function of which curve shipped that month.
///
/// Alpha is dropped rather than composited: the pipeline is RGB throughout, and
/// compositing would need a background colour nobody has a principled value for.
fn to_rgb8(pixels: &heif_oxide::Pixels) -> Vec<u8> {
    use heif_oxide::Pixels;
    match pixels {
        Pixels::Rgb8(v) => v.clone(),
        Pixels::Rgba8(v) => v.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect(),
        Pixels::Rgb16(v) => v.iter().map(|s| (s >> 8) as u8).collect(),
        Pixels::Rgba16(v) => v
            .chunks_exact(4)
            .flat_map(|p| [(p[0] >> 8) as u8, (p[1] >> 8) as u8, (p[2] >> 8) as u8])
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bit-depth rule, pinned. A tone map would make these numbers depend
    /// on a curve; a right shift makes them arithmetic.
    #[test]
    fn deep_samples_are_right_shifted_not_tone_mapped() {
        let deep = heif_oxide::Pixels::Rgb16(vec![0, 0x8000, 0xFFFF, 0x0100, 0x01FF, 0x7F00]);
        assert_eq!(to_rgb8(&deep), vec![0x00, 0x80, 0xFF, 0x01, 0x01, 0x7F]);

        // 8-bit sources pass through untouched, and alpha is dropped.
        assert_eq!(
            to_rgb8(&heif_oxide::Pixels::Rgba8(vec![1, 2, 3, 200, 4, 5, 6, 0])),
            vec![1, 2, 3, 4, 5, 6]
        );
        assert_eq!(
            to_rgb8(&heif_oxide::Pixels::Rgb8(vec![9, 8, 7])),
            vec![9, 8, 7]
        );
    }

    /// A container that claims more pixels than the pipeline will ever hold is
    /// refused **without** the decoder being handed the file.
    #[test]
    fn an_absurd_declared_extent_is_refused_before_decode() {
        let mut ipco = Vec::new();
        let mut ispe = vec![0u8, 0, 0, 0];
        ispe.extend_from_slice(&40_000u32.to_be_bytes());
        ispe.extend_from_slice(&40_000u32.to_be_bytes());
        ipco.extend_from_slice(&boxed(b"ispe", &ispe));

        let mut ftyp = b"heic".to_vec();
        ftyp.extend_from_slice(&0u32.to_be_bytes());
        ftyp.extend_from_slice(b"heic");
        let mut file = boxed(b"ftyp", &ftyp);
        let mut meta = vec![0u8, 0, 0, 0];
        meta.extend_from_slice(&boxed(b"iprp", &boxed(b"ipco", &ipco)));
        file.extend_from_slice(&boxed(b"meta", &meta));

        let err = HeifDecoder
            .decode("/a/bomb.heic", &file, ImageKind::Heic)
            .unwrap_err();
        assert!(
            matches!(
                err,
                MlError::Preprocess {
                    code: ErrorCode::BadImage,
                    ..
                }
            ),
            "{err:?}"
        );
    }

    fn boxed(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut out = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        out.extend_from_slice(kind);
        out.extend_from_slice(payload);
        out
    }
}
