//! Typed errors for the tagging pipeline.
//!
//! Two levels exist on purpose:
//!
//! * [`MlError`] — a *run-level* failure. The pack would not load, the cache DB
//!   is unusable, the caller cancelled. These abort [`crate::TaggingEngine::run`].
//! * [`ErrorCode`] — a *photo-level* failure, stored in `ml_work.error_code` as
//!   a small stable integer. One bad JPEG must never stop a 20k-photo run, and
//!   the code has to survive a round trip through SQLite, so it is a plain
//!   `i64` discriminant rather than a string.
//!
//! Neither type carries a `Box<dyn Error>`: the FFI layer needs to map these
//! onto a UniFFI enum, and "errors cross the boundary as typed enums, never
//! strings" (overview, FFI rules).

use std::fmt;

use gallery_meta::MetaError;
use gallery_vfs::VfsError;

/// Result alias for this crate.
pub type MlResult<T> = Result<T, MlError>;

/// Why a tagging run could not proceed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MlError {
    /// A file named by the model-pack manifest is missing.
    PackFileMissing {
        /// Path that was expected to exist.
        path: String,
    },
    /// A model-pack file does not hash to what the manifest claims.
    ///
    /// This is the load-bearing check of the determinism doctrine: results are
    /// only comparable across devices if the weights are byte-identical.
    PackHashMismatch {
        /// Manifest-relative file name.
        file: String,
        /// Hex SHA-256 from the manifest.
        expected: String,
        /// Hex SHA-256 actually computed.
        actual: String,
    },
    /// The manifest or the label set is malformed or internally inconsistent.
    PackInvalid {
        /// What was wrong; for logs only.
        detail: String,
    },
    /// SQLite said no.
    Cache {
        /// The rusqlite message; for logs only.
        detail: String,
    },
    /// The inference backend refused to load the model or run it.
    Inference {
        /// Backend message; for logs only.
        detail: String,
    },
    /// A photo could not be turned into a tensor.
    Preprocess {
        /// The image path.
        path: String,
        /// Photo-level classification of the failure.
        code: ErrorCode,
        /// Decoder message; for logs only.
        detail: String,
    },
    /// The filesystem said no.
    Vfs(VfsError),
    /// The sidecar layer said no.
    Meta(MetaError),
    /// The caller set the cancellation flag.
    Cancelled,
}

impl From<VfsError> for MlError {
    fn from(e: VfsError) -> Self {
        MlError::Vfs(e)
    }
}

impl From<MetaError> for MlError {
    fn from(e: MetaError) -> Self {
        MlError::Meta(e)
    }
}

impl From<rusqlite::Error> for MlError {
    fn from(e: rusqlite::Error) -> Self {
        MlError::Cache {
            detail: e.to_string(),
        }
    }
}

impl fmt::Display for MlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MlError::PackFileMissing { path } => write!(f, "model pack file missing: {path}"),
            MlError::PackHashMismatch {
                file,
                expected,
                actual,
            } => write!(
                f,
                "model pack file {file} hashes to {actual}, manifest says {expected}"
            ),
            MlError::PackInvalid { detail } => write!(f, "invalid model pack: {detail}"),
            MlError::Cache { detail } => write!(f, "cache db: {detail}"),
            MlError::Inference { detail } => write!(f, "inference: {detail}"),
            MlError::Preprocess { path, code, detail } => {
                write!(f, "preprocess {path} ({code:?}): {detail}")
            }
            MlError::Vfs(e) => write!(f, "{e}"),
            MlError::Meta(e) => write!(f, "{e}"),
            MlError::Cancelled => write!(f, "cancelled"),
        }
    }
}

impl std::error::Error for MlError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            MlError::Vfs(e) => Some(e),
            MlError::Meta(e) => Some(e),
            _ => None,
        }
    }
}

impl MlError {
    /// The photo-level code to record when this error happened while handling
    /// one specific photo.
    pub fn error_code(&self) -> ErrorCode {
        match self {
            MlError::Preprocess { code, .. } => *code,
            MlError::Vfs(VfsError::NotFound { .. }) => ErrorCode::NotFound,
            MlError::Vfs(_) => ErrorCode::Io,
            MlError::Meta(MetaError::ConcurrentModification { .. }) => ErrorCode::SidecarConflict,
            MlError::Meta(_) => ErrorCode::SidecarWrite,
            MlError::Inference { .. } => ErrorCode::Inference,
            MlError::Cache { .. } => ErrorCode::Cache,
            MlError::Cancelled => ErrorCode::Cancelled,
            MlError::PackFileMissing { .. }
            | MlError::PackHashMismatch { .. }
            | MlError::PackInvalid { .. } => ErrorCode::Pack,
        }
    }
}

/// Stable, persisted classification of a per-photo failure.
///
/// The integer values are written into `ml_work.error_code` and are therefore
/// **append-only**: never renumber, never reuse. Swift renders them; a code it
/// does not know maps to "unknown", not to a crash.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum ErrorCode {
    /// No classification recorded.
    None = 0,
    /// The file disappeared between enqueue and run.
    NotFound = 1,
    /// Read failed (permissions, cloud placeholder, IO error).
    Io = 2,
    /// The extension or magic bytes are not a format v1 decodes.
    UnsupportedFormat = 3,
    /// The bytes are a supported format but did not decode.
    Decode = 4,
    /// The decoded image was degenerate (zero-sized, absurdly large).
    BadImage = 5,
    /// The encoder failed on this tensor.
    Inference = 6,
    /// The sidecar could not be written.
    SidecarWrite = 7,
    /// The cache DB rejected an update for this row.
    Cache = 8,
    /// The model pack is broken (recorded per photo only when discovered late).
    Pack = 9,
    /// The run was cancelled while this photo was in flight.
    Cancelled = 10,
    /// Another program wrote the sidecar between our read and our write.
    ///
    /// Unlike every other code here this one is **retryable** — the row goes
    /// back through the queue's normal `retry_count` path and the next attempt
    /// re-reads and re-merges the other writer's changes.
    SidecarConflict = 11,
}

impl ErrorCode {
    /// The persisted integer.
    pub fn as_i64(self) -> i64 {
        self as i64
    }

    /// Inverse of [`ErrorCode::as_i64`]; unknown values read as [`ErrorCode::None`].
    pub fn from_i64(v: i64) -> ErrorCode {
        match v {
            1 => ErrorCode::NotFound,
            2 => ErrorCode::Io,
            3 => ErrorCode::UnsupportedFormat,
            4 => ErrorCode::Decode,
            5 => ErrorCode::BadImage,
            6 => ErrorCode::Inference,
            7 => ErrorCode::SidecarWrite,
            8 => ErrorCode::Cache,
            9 => ErrorCode::Pack,
            10 => ErrorCode::Cancelled,
            11 => ErrorCode::SidecarConflict,
            _ => ErrorCode::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_round_trip() {
        for code in [
            ErrorCode::None,
            ErrorCode::NotFound,
            ErrorCode::Io,
            ErrorCode::UnsupportedFormat,
            ErrorCode::Decode,
            ErrorCode::BadImage,
            ErrorCode::Inference,
            ErrorCode::SidecarWrite,
            ErrorCode::Cache,
            ErrorCode::Pack,
            ErrorCode::Cancelled,
            ErrorCode::SidecarConflict,
        ] {
            assert_eq!(ErrorCode::from_i64(code.as_i64()), code);
        }
        assert_eq!(ErrorCode::from_i64(9999), ErrorCode::None);
    }

    #[test]
    fn a_sidecar_race_is_classified_as_retryable_not_as_a_write_failure() {
        let e = MlError::Meta(MetaError::ConcurrentModification { path: "/x".into() });
        assert_eq!(e.error_code(), ErrorCode::SidecarConflict);
        assert!(matches!(&e, MlError::Meta(m) if m.is_retryable()));
    }

    #[test]
    fn vfs_not_found_maps_to_its_own_code() {
        let e = MlError::Vfs(VfsError::NotFound { path: "/x".into() });
        assert_eq!(e.error_code(), ErrorCode::NotFound);
    }
}
