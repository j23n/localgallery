//! The pinned decode → orient → resize → tensor path.
//!
//! This module is the reason the determinism doctrine (overview §5) is
//! achievable at all. Two devices only agree on tags if they agree on the
//! *pixels* they fed the encoder, and the single largest source of
//! disagreement in a photo pipeline is the decoder: `CGImageSource`,
//! `BitmapFactory` and libjpeg-turbo all produce subtly different RGB for the
//! same JPEG. So **no platform decoder is ever used here** — everything is
//! pure Rust, from crates pinned to exact versions in `Cargo.toml`.
//!
//! # The pipeline, in order
//!
//! 1. **Sniff** the format from magic bytes, not the extension. A `.jpg` that
//!    is really a PNG decodes fine; a `.jpg` that is really HEIC must fail
//!    loudly rather than half-decode.
//! 2. **Decode** with `image` 0.25.10 (`zune-jpeg` for JPEG, `png` for PNG).
//! 3. **Orient** using the EXIF `Orientation` tag read by `kamadak-exif`.
//!    Readers disagree about whether a decoder should self-apply orientation;
//!    ours does not, so we apply it explicitly and identically everywhere.
//! 4. **Resize** the shortest side to the model's input size with
//!    `fast_image_resize`, then **center-crop** a square. This is the
//!    `Resize(N, BICUBIC)` + `CenterCrop(N)` order that open_clip/torchvision
//!    use, so an encoder exported from those stacks sees the transform it was
//!    trained with. Crop-then-resize would be one pass cheaper and *almost*
//!    the same — the difference is the kernel footprint at the crop border —
//!    but "almost" is not a word this pipeline gets to use.
//! 5. **Normalize** to CHW `f32` with the mean/std from the pack manifest.
//!
//! # Golden hashes and CPU extensions
//!
//! `tests/preprocess_golden.rs` pins the SHA-256 of the tensor bytes for
//! committed fixtures. `fast_image_resize` auto-selects SIMD kernels, so those
//! hashes are **architecture-specific**: they hold across every Apple target
//! (device, simulator and Mac are all `aarch64`/NEON) and would need
//! regenerating for an x86-64 build. Forcing scalar kernels would make them
//! universal, but `Resizer::set_cpu_extensions` is `unsafe` and this crate is
//! `#![forbid(unsafe_code)]`. That trade is deliberate and it is exactly what
//! the doctrine's "decision-identical, not bit-identical" clause buys: pixel
//! drift between architectures is absorbed by the tagger's hysteresis margin
//! (see [`crate::tagger`]), which is sized far larger than a rounding step.

use fast_image_resize::images::{Image as FirImage, ImageRef};
use fast_image_resize::{FilterType, PixelType, ResizeAlg, ResizeOptions, Resizer};
use image::metadata::Orientation;
use image::{DynamicImage, ImageFormat, RgbImage};
use serde::{Deserialize, Serialize};

use crate::error::{ErrorCode, MlError, MlResult};

/// Bumped whenever a change in this module moves pixels.
///
/// Stored alongside cached embeddings so a preprocessing change invalidates
/// them: the embedding cache is keyed by content hash, and the content hash
/// says nothing about how we turned those bytes into a tensor.
pub const PREPROCESS_VERSION: u32 = 1;

/// A decoded image is refused past this many pixels.
///
/// 120 MP is comfortably above any phone camera and any stitched panorama a
/// phone produces, and well below the point where a malformed header can talk
/// us into a multi-gigabyte allocation. Four workers each holding a 120 MP RGB
/// buffer is already 1.4 GB, which is why this is not larger.
const MAX_PIXELS: u64 = 120_000_000;

/// The *resize destination* is refused past this many pixels.
///
/// [`MAX_PIXELS`] bounds the decoded source, and that is not enough on its own:
/// [`shortest_side_to`] scales the **long** side by `n / min(w, h)`, so an
/// extreme aspect ratio explodes the destination even though the source is
/// tiny. A 257-byte 3000×3 PNG decodes to 9 000 pixels and would resize to
/// 224 000×224 — 0.15 GB — and a 65535×2 header asks for 4.9 GB. Both are
/// rejected here as [`ErrorCode::BadImage`], so the photo is *failed*, not the
/// process.
///
/// 16 MP of destination allows an aspect ratio of roughly 320:1 at a 224 px
/// input, which no photograph reaches and no panorama needs.
const MAX_RESIZE_PIXELS: u64 = 16_000_000;

/// The image formats v1 decodes.
///
/// HEIC is the conspicuous gap: iPhones shoot it by default. It needs
/// libheif/libde265 (C, LGPL, non-trivial to cross-compile) or a pure-Rust
/// decoder that does not exist at production quality yet, and the determinism
/// doctrine forbids reaching for `CGImageSource`. Until then HEIC photos are
/// recorded as [`ErrorCode::UnsupportedFormat`] and skipped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageKind {
    /// JFIF/EXIF JPEG.
    Jpeg,
    /// PNG.
    Png,
}

impl ImageKind {
    fn format(self) -> ImageFormat {
        match self {
            ImageKind::Jpeg => ImageFormat::Jpeg,
            ImageKind::Png => ImageFormat::Png,
        }
    }
}

/// Extensions the engine will even open. Lowercase, no dot.
///
/// Checked before the file is read, so a 4 GB video is not streamed through
/// SHA-256 only to be rejected by the sniffer.
pub const SUPPORTED_EXTENSIONS: &[&str] = &["jpg", "jpeg", "jpe", "png"];

/// Whether `path`'s extension is one this crate will attempt.
pub fn extension_supported(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rsplit_once('.') {
        Some((_, ext)) => {
            let ext = ext.to_ascii_lowercase();
            SUPPORTED_EXTENSIONS.contains(&ext.as_str())
        }
        None => false,
    }
}

/// Identify `bytes` by magic number.
pub fn sniff(bytes: &[u8]) -> Option<ImageKind> {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(ImageKind::Jpeg);
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(ImageKind::Png);
    }
    None
}

/// Which resize kernel a pack was built against.
///
/// Serialized in the manifest so the pack, not the code, decides — an encoder
/// exported from open_clip wants `CatmullRom` (PIL's `BICUBIC` is the `a=-0.5`
/// cubic), while a pack built with a Lanczos preprocessing chain says so.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResizeFilter {
    /// Box / area average.
    Box,
    /// Triangle.
    Bilinear,
    /// Cubic with `a = -0.5` — what PIL and torchvision call `BICUBIC`, and
    /// therefore what an open_clip-exported encoder was trained against.
    #[default]
    CatmullRom,
    /// Mitchell-Netravali.
    Mitchell,
    /// Lanczos, 3 lobes.
    Lanczos3,
}

impl ResizeFilter {
    fn to_fir(self) -> FilterType {
        match self {
            ResizeFilter::Box => FilterType::Box,
            ResizeFilter::Bilinear => FilterType::Bilinear,
            ResizeFilter::CatmullRom => FilterType::CatmullRom,
            ResizeFilter::Mitchell => FilterType::Mitchell,
            ResizeFilter::Lanczos3 => FilterType::Lanczos3,
        }
    }
}

/// Everything the tensor build needs, all of it from the model-pack manifest.
#[derive(Debug, Clone, PartialEq)]
pub struct PreprocessConfig {
    /// Square model input edge, in pixels.
    pub input_size: u32,
    /// Per-channel mean, in `[0, 1]` space (applied after `/255`).
    pub mean: [f32; 3],
    /// Per-channel standard deviation.
    pub std: [f32; 3],
    /// Resize kernel.
    pub filter: ResizeFilter,
}

impl Default for PreprocessConfig {
    /// The CLIP defaults, so tests and tools do not have to restate them.
    fn default() -> Self {
        PreprocessConfig {
            input_size: 224,
            mean: [0.481_454_66, 0.457_827_5, 0.408_210_73],
            std: [0.268_629_54, 0.261_302_6, 0.275_777_1],
            filter: ResizeFilter::CatmullRom,
        }
    }
}

/// A `1 × 3 × H × W` f32 tensor in CHW order — the encoder's input.
#[derive(Debug, Clone, PartialEq)]
pub struct Tensor {
    /// Row-major `[1, 3, H, W]` values.
    pub data: Vec<f32>,
    /// `[1, 3, H, W]`.
    pub shape: [usize; 4],
}

impl Tensor {
    /// Little-endian IEEE-754 bytes, in `data` order.
    ///
    /// This is what the golden tests hash. Little-endian is not a portability
    /// hazard here (every target we build for is LE) but it is stated
    /// explicitly so a big-endian port cannot silently produce a different
    /// golden.
    pub fn to_le_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.data.len() * 4);
        for v in &self.data {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }
}

/// Decode `bytes` and produce the model input tensor.
///
/// `path` is only used to label errors.
pub fn preprocess(path: &str, bytes: &[u8], cfg: &PreprocessConfig) -> MlResult<Tensor> {
    tensor_from_rgb(path, decode_oriented(path, bytes)?, cfg)
}

/// Steps 1–3 of the pipeline: sniff, decode, apply EXIF orientation.
///
/// Split out from [`preprocess`] because the face pipeline needs the *oriented
/// full-resolution pixels* twice — once letterboxed for the detector, then
/// again at original scale to cut the aligned crops out of — and decoding a
/// 12 MP JPEG twice per photo is the most expensive thing this crate could do
/// by accident. Every caller sees the same bytes, so the determinism story is
/// unchanged: this *is* the pinned path, just named.
pub fn decode_oriented(path: &str, bytes: &[u8]) -> MlResult<RgbImage> {
    let kind = sniff(bytes).ok_or_else(|| MlError::Preprocess {
        path: path.to_string(),
        code: ErrorCode::UnsupportedFormat,
        detail: "not a JPEG or PNG (magic bytes)".into(),
    })?;

    let decoded = image::load_from_memory_with_format(bytes, kind.format()).map_err(|e| {
        MlError::Preprocess {
            path: path.to_string(),
            code: ErrorCode::Decode,
            detail: e.to_string(),
        }
    })?;

    let pixels = u64::from(decoded.width()) * u64::from(decoded.height());
    if pixels == 0 || pixels > MAX_PIXELS {
        return Err(MlError::Preprocess {
            path: path.to_string(),
            code: ErrorCode::BadImage,
            detail: format!(
                "{}×{} is not a usable size",
                decoded.width(),
                decoded.height()
            ),
        });
    }

    Ok(apply_orientation(decoded, read_exif_orientation(bytes)).into_rgb8())
}

/// The EXIF `Orientation` value (1–8), or `None` when absent/unreadable.
///
/// Read with `kamadak-exif` rather than the decoder's own metadata hook so the
/// answer is identical for JPEG and for PNG's `eXIf` chunk, and so a decoder
/// upgrade cannot quietly start auto-rotating underneath us.
pub fn read_exif_orientation(bytes: &[u8]) -> Option<u8> {
    let mut cursor = std::io::Cursor::new(bytes);
    let reader = exif::Reader::new().read_from_container(&mut cursor).ok()?;
    let field = reader.get_field(exif::Tag::Orientation, exif::In::PRIMARY)?;
    let value = field.value.get_uint(0)?;
    u8::try_from(value).ok().filter(|v| (1..=8).contains(v))
}

fn apply_orientation(mut img: DynamicImage, exif_orientation: Option<u8>) -> DynamicImage {
    let orientation = exif_orientation
        .and_then(Orientation::from_exif)
        .unwrap_or(Orientation::NoTransforms);
    img.apply_orientation(orientation);
    img
}

/// Resize + center-crop + normalize an already-oriented RGB image.
///
/// Split out from [`preprocess`] so tests can drive the geometry without
/// producing an encoded fixture for every case. Takes the image **by value**:
/// `fast_image_resize` wants an owned buffer, and cloning one first doubled the
/// peak resident bytes of every decode for nothing.
pub fn tensor_from_rgb(path: &str, rgb: RgbImage, cfg: &PreprocessConfig) -> MlResult<Tensor> {
    let n = cfg.input_size;
    if n == 0 {
        return Err(MlError::PackInvalid {
            detail: "input_size is 0".into(),
        });
    }

    let (w, h) = (rgb.width(), rgb.height());
    let (rw, rh) = shortest_side_to(w, h, n);

    // The destination, not the source, is the allocation an absurd aspect ratio
    // blows up. See [`MAX_RESIZE_PIXELS`].
    if u64::from(rw) * u64::from(rh) > MAX_RESIZE_PIXELS {
        return Err(MlError::Preprocess {
            path: path.to_string(),
            code: ErrorCode::BadImage,
            detail: format!("{w}×{h} would resize to {rw}×{rh}, past the destination cap"),
        });
    }

    let src = FirImage::from_vec_u8(w, h, rgb.into_raw(), PixelType::U8x3).map_err(|e| {
        MlError::Preprocess {
            path: path.to_string(),
            code: ErrorCode::BadImage,
            detail: e.to_string(),
        }
    })?;
    let mut dst = FirImage::new(rw, rh, PixelType::U8x3);
    let options = ResizeOptions::new()
        .resize_alg(ResizeAlg::Convolution(cfg.filter.to_fir()))
        // The source is RGB with no alpha channel; premultiplication would be
        // a no-op that costs a full pass.
        .use_alpha(false);
    Resizer::new()
        .resize(&src, &mut dst, &options)
        .map_err(|e| MlError::Preprocess {
            path: path.to_string(),
            code: ErrorCode::BadImage,
            detail: e.to_string(),
        })?;

    let resized = dst.into_vec();
    let (ox, oy) = center_crop_origin(rw, rh, n);

    let n_usize = n as usize;
    let data = planar_normalize(
        &resized,
        rw as usize * 3,
        ox as usize,
        oy as usize,
        n_usize,
        &cfg.mean,
        &cfg.std,
    );

    Ok(Tensor {
        data,
        shape: [1, 3, n_usize, n_usize],
    })
}

/// Cut an `n × n` window out of an interleaved RGB buffer and write it as a
/// normalized CHW `f32` plane stack.
///
/// The one place `(value / 255 - mean) / std` is spelled out. Every tensor this
/// crate builds — tagging crop, detector letterbox, aligned face — goes through
/// here, so "the goldens moved" can only ever mean one arithmetic change.
fn planar_normalize(
    src: &[u8],
    row_stride: usize,
    ox: usize,
    oy: usize,
    n: usize,
    mean: &[f32; 3],
    std: &[f32; 3],
) -> Vec<f32> {
    let plane = n * n;
    let mut data = vec![0.0f32; 3 * plane];
    for y in 0..n {
        let src_row = (oy + y) * row_stride + ox * 3;
        for x in 0..n {
            let i = src_row + x * 3;
            let o = y * n + x;
            for c in 0..3 {
                let v = f32::from(src[i + c]) / 255.0;
                data[c * plane + o] = (v - mean[c]) / std[c];
            }
        }
    }
    data
}

/// A square detector input plus the geometry to undo it.
#[derive(Debug, Clone, PartialEq)]
pub struct Letterboxed {
    /// `1 × 3 × size × size`, normalized.
    pub tensor: Tensor,
    /// Factor the source was multiplied by. Divide a detection's coordinates by
    /// this to get back to original-image pixels.
    pub scale: f64,
    /// Occupied region of the canvas, in canvas pixels. Everything outside is
    /// the zero pad.
    pub content: (u32, u32),
}

/// Resize `rgb` to fit inside `size × size` preserving aspect ratio, pad the
/// remainder with black, and normalize.
///
/// **Top-left aligned**, not centered, matching insightface's `SCRFD.detect` —
/// the detector's anchor grid is what it is, and a pack built against one
/// padding convention is not interchangeable with the other. The pad value is
/// 0 *before* normalization (i.e. black pixels), so the padded region carries
/// whatever `(0 - mean) / std` is, exactly as it would in the reference
/// pipeline.
///
/// Only one `scale` is used for both axes even though the rounded destination
/// size makes the realized x- and y- scales differ by a fraction of a pixel.
/// That is the reference implementation's behaviour too, and the residual is
/// under half a pixel in the 640-pixel frame — an order of magnitude below the
/// landmark precision anything downstream relies on.
pub fn letterbox(
    path: &str,
    rgb: &RgbImage,
    size: u32,
    mean: &[f32; 3],
    std: &[f32; 3],
    filter: ResizeFilter,
) -> MlResult<Letterboxed> {
    let bad = |detail: String| MlError::Preprocess {
        path: path.to_string(),
        code: ErrorCode::BadImage,
        detail,
    };
    if size == 0 {
        return Err(MlError::PackInvalid {
            detail: "detector input_size is 0".into(),
        });
    }
    let (w, h) = (rgb.width(), rgb.height());
    if w == 0 || h == 0 {
        return Err(bad(format!("{w}×{h} is not a usable size")));
    }

    let scale = (f64::from(size) / f64::from(w)).min(f64::from(size) / f64::from(h));
    let nw = ((f64::from(w) * scale).round() as u32).clamp(1, size);
    let nh = ((f64::from(h) * scale).round() as u32).clamp(1, size);

    let src = ImageRef::new(w, h, rgb.as_raw(), PixelType::U8x3).map_err(|e| bad(e.to_string()))?;
    let mut dst = FirImage::new(nw, nh, PixelType::U8x3);
    let options = ResizeOptions::new()
        .resize_alg(ResizeAlg::Convolution(filter.to_fir()))
        .use_alpha(false);
    Resizer::new()
        .resize(&src, &mut dst, &options)
        .map_err(|e| bad(e.to_string()))?;

    let n = size as usize;
    let mut canvas = vec![0u8; n * n * 3];
    let resized = dst.into_vec();
    for y in 0..nh as usize {
        let from = y * nw as usize * 3;
        let to = y * n * 3;
        canvas[to..to + nw as usize * 3].copy_from_slice(&resized[from..from + nw as usize * 3]);
    }

    Ok(Letterboxed {
        tensor: Tensor {
            data: planar_normalize(&canvas, n * 3, 0, 0, n, mean, std),
            shape: [1, 3, n, n],
        },
        scale,
        content: (nw, nh),
    })
}

/// Normalize an already-square RGB buffer into a model input tensor.
///
/// Used by the face aligner, which produces its `112 × 112` pixels by warping
/// rather than by resizing and cropping.
pub fn tensor_from_square(rgb: &RgbImage, mean: &[f32; 3], std: &[f32; 3]) -> MlResult<Tensor> {
    let n = rgb.width() as usize;
    if rgb.width() != rgb.height() || n == 0 {
        return Err(MlError::PackInvalid {
            detail: format!(
                "{}×{} is not a square tensor source",
                rgb.width(),
                rgb.height()
            ),
        });
    }
    Ok(Tensor {
        data: planar_normalize(rgb.as_raw(), n * 3, 0, 0, n, mean, std),
        shape: [1, 3, n, n],
    })
}

/// Scale `(w, h)` so the shorter side is exactly `n`, rounding half away from
/// zero, and never letting either side fall below `n` (a 1-pixel rounding-down
/// would make the center crop impossible).
fn shortest_side_to(w: u32, h: u32, n: u32) -> (u32, u32) {
    let scale = f64::from(n) / f64::from(w.min(h));
    let rw = (f64::from(w) * scale).round().max(f64::from(n)) as u32;
    let rh = (f64::from(h) * scale).round().max(f64::from(n)) as u32;
    (rw, rh)
}

/// Top-left corner of the centered `n × n` crop.
///
/// Floor division, matching torchvision's `center_crop`, so an odd leftover
/// pixel lands on the bottom/right.
fn center_crop_origin(w: u32, h: u32, n: u32) -> (u32, u32) {
    ((w.saturating_sub(n)) / 2, (h.saturating_sub(n)) / 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: u32, h: u32, px: [u8; 3]) -> RgbImage {
        RgbImage::from_fn(w, h, |_, _| image::Rgb(px))
    }

    #[test]
    fn extensions_are_matched_case_insensitively() {
        assert!(extension_supported("/a/b/IMG_1.JPG"));
        assert!(extension_supported("/a/b/IMG_1.jpeg"));
        assert!(extension_supported("/a/b/x.png"));
        assert!(!extension_supported("/a/b/x.heic"));
        assert!(!extension_supported("/a/b/x.mov"));
        assert!(!extension_supported("/a/b/noextension"));
        // A dot in a directory name must not be mistaken for the extension.
        assert!(!extension_supported("/a.jpg/b"));
    }

    #[test]
    fn sniffing_beats_the_extension() {
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), Some(ImageKind::Jpeg));
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\n\x00"), Some(ImageKind::Png));
        // The HEIC brand box — the known gap. It must sniff as unsupported,
        // not fall through to the JPEG decoder.
        assert_eq!(sniff(b"\x00\x00\x00\x18ftypheic"), None);
        assert_eq!(sniff(b""), None);
    }

    #[test]
    fn shortest_side_scaling_never_undershoots() {
        assert_eq!(shortest_side_to(400, 200, 100), (200, 100));
        assert_eq!(shortest_side_to(200, 400, 100), (100, 200));
        assert_eq!(shortest_side_to(100, 100, 100), (100, 100));
        // 333 → 100 scales the other side to 99.99…; clamping keeps it at 100.
        let (w, h) = shortest_side_to(333, 334, 100);
        assert!(w >= 100 && h >= 100, "{w}×{h}");
    }

    #[test]
    fn crop_origin_is_centered_and_floored() {
        assert_eq!(center_crop_origin(200, 100, 100), (50, 0));
        assert_eq!(center_crop_origin(101, 100, 100), (0, 0));
        assert_eq!(center_crop_origin(103, 100, 100), (1, 0));
    }

    #[test]
    fn tensor_shape_and_normalization() {
        let cfg = PreprocessConfig {
            input_size: 4,
            mean: [0.5, 0.5, 0.5],
            std: [0.5, 0.5, 0.5],
            filter: ResizeFilter::Bilinear,
        };
        let t = tensor_from_rgb("x", solid(16, 16, [255, 0, 128]), &cfg).unwrap();
        assert_eq!(t.shape, [1, 3, 4, 4]);
        assert_eq!(t.data.len(), 48);
        // (1.0 - 0.5) / 0.5 == 1.0 for the saturated red channel.
        assert!((t.data[0] - 1.0).abs() < 1e-5, "{}", t.data[0]);
        // (0.0 - 0.5) / 0.5 == -1.0 for green.
        assert!((t.data[16] + 1.0).abs() < 1e-5, "{}", t.data[16]);
        assert_eq!(t.to_le_bytes().len(), 48 * 4);
    }

    #[test]
    fn channels_are_planar_not_interleaved() {
        let cfg = PreprocessConfig {
            input_size: 2,
            mean: [0.0, 0.0, 0.0],
            std: [1.0, 1.0, 1.0],
            filter: ResizeFilter::Box,
        };
        let t = tensor_from_rgb("x", solid(8, 8, [255, 0, 0]), &cfg).unwrap();
        // Plane 0 all 1.0, planes 1 and 2 all 0.0.
        assert!(t.data[0..4].iter().all(|v| (*v - 1.0).abs() < 1e-5));
        assert!(t.data[4..12].iter().all(|v| v.abs() < 1e-5));
    }

    #[test]
    fn unsupported_bytes_are_classified_not_decoded() {
        let err = preprocess("/a/x.jpg", b"GIF89a", &PreprocessConfig::default()).unwrap_err();
        assert!(
            matches!(
                err,
                MlError::Preprocess {
                    code: ErrorCode::UnsupportedFormat,
                    ..
                }
            ),
            "{err:?}"
        );
    }

    /// A decode bomb: a handful of bytes on disk, a source well inside
    /// [`MAX_PIXELS`], and a resize destination that would allocate gigabytes.
    #[test]
    fn an_absurd_aspect_ratio_is_refused_rather_than_allocated() {
        // 3000×3 is 9 000 source pixels — 257 bytes as a PNG — but the shortest
        // side is 3, so scaling it to 224 asks for 224 000×224 ≈ 0.15 GB.
        let mut png = Vec::new();
        image::DynamicImage::ImageRgb8(solid(3000, 3, [1, 2, 3]))
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        assert!(png.len() < 4096, "fixture is {} bytes", png.len());

        let err = preprocess("/a/bomb.png", &png, &PreprocessConfig::default()).unwrap_err();
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

    #[test]
    fn a_wide_but_sane_panorama_still_passes() {
        // 20 000×2 000 is a real stitched panorama: 4 480×224 out, well inside
        // the cap. The bomb guard must not take this with it.
        let cfg = PreprocessConfig {
            input_size: 8,
            ..PreprocessConfig::default()
        };
        assert!(tensor_from_rgb("pan", solid(2000, 200, [9, 9, 9]), &cfg).is_ok());
    }

    #[test]
    fn truncated_jpeg_is_a_decode_failure() {
        let err = preprocess(
            "/a/x.jpg",
            &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10],
            &PreprocessConfig::default(),
        )
        .unwrap_err();
        assert!(
            matches!(
                err,
                MlError::Preprocess {
                    code: ErrorCode::Decode,
                    ..
                }
            ),
            "{err:?}"
        );
    }
}
