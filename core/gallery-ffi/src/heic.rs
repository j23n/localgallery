//! Host HEIC decode. The software path in `gallery-ml` is a full HEVC
//! decode in pure Rust; on an iPhone that is several seconds per photo.
//! ImageIO is hardware and ~50–200 ms, so the app installs this on both
//! sessions. Tests and `cargo test` leave it unset.

use std::sync::Arc;

use gallery_ml::{rgb_from_packed, ErrorCode, HostHeicDecoder, MlError, MlResult, RgbImage};

/// Why the host could not decode a HEIC.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum HeicDecodeError {
    /// ImageIO (or the host decoder) refused the file.
    Failed {
        /// Decoder message; for logs only.
        detail: String,
    },
}

impl std::fmt::Display for HeicDecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HeicDecodeError::Failed { detail } => write!(f, "heic decode failed: {detail}"),
        }
    }
}

impl std::error::Error for HeicDecodeError {}

/// Packed RGB8 pixels from a host decoder.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeicPixels {
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
    /// `width * height * 3` bytes, RGB order, already oriented.
    pub rgb: Vec<u8>,
}

/// Platform HEIC decoder the app implements (ImageIO on iOS).
#[uniffi::export(with_foreign)]
pub trait HeicDecoder: Send + Sync {
    /// Decode `path` to oriented RGB. The implementation opens the file
    /// itself — do not call back into the core.
    fn decode(&self, path: String) -> Result<HeicPixels, HeicDecodeError>;
}

/// Adapts a UniFFI foreign trait onto [`HostHeicDecoder`].
pub(crate) struct HeicDecoderAdapter(pub Arc<dyn HeicDecoder>);

impl HostHeicDecoder for HeicDecoderAdapter {
    fn decode(&self, path: &str) -> MlResult<RgbImage> {
        let pixels = self.0.decode(path.to_string()).map_err(|e| {
            let detail = match e {
                HeicDecodeError::Failed { detail } => detail,
            };
            MlError::Preprocess {
                path: path.to_string(),
                code: ErrorCode::Decode,
                detail,
            }
        })?;
        match rgb_from_packed(pixels.width, pixels.height, pixels.rgb) {
            Ok(img) => Ok(img),
            Err(MlError::Preprocess { code, detail, .. }) => Err(MlError::Preprocess {
                path: path.to_string(),
                code,
                detail,
            }),
            Err(e) => Err(e),
        }
    }
}
