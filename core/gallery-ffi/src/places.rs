//! Reverse-geocoded Places writes. A free function rather than a session:
//! there is no ONNX, no queue, and no run lock — each photo is one
//! read-modify-write of its sidecar.

use gallery_meta::{MetaError, PlaceWriteRequest};
use gallery_vfs::{StdVfs, VfsError};

/// Why a Places write failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlacesError {
    /// The requested path is not a usable `Places/…` tag.
    InvalidTag {
        /// The offending tag.
        tag: String,
        /// Why it was rejected.
        reason: String,
    },
    /// The sidecar changed between read and write. Retryable.
    ConcurrentModification {
        /// Sidecar path.
        path: String,
    },
    /// Filesystem said no.
    Io {
        /// Path that failed.
        path: String,
        /// OS message; for logs only.
        detail: String,
    },
    /// The sidecar could not be parsed or was not XMP.
    Sidecar {
        /// Parser message; for logs only.
        detail: String,
    },
}

impl std::fmt::Display for PlacesError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlacesError::InvalidTag { tag, reason } => {
                write!(f, "invalid place tag {tag:?}: {reason}")
            }
            PlacesError::ConcurrentModification { path } => {
                write!(f, "sidecar changed while writing places: {path}")
            }
            PlacesError::Io { path, detail } => write!(f, "io {path}: {detail}"),
            PlacesError::Sidecar { detail } => write!(f, "sidecar: {detail}"),
        }
    }
}

impl std::error::Error for PlacesError {}

impl From<VfsError> for PlacesError {
    fn from(e: VfsError) -> Self {
        let detail = e.to_string();
        let path = match &e {
            VfsError::NotFound { path }
            | VfsError::PermissionDenied { path }
            | VfsError::NotADirectory { path }
            | VfsError::AlreadyExists { path }
            | VfsError::InvalidPath { path, .. }
            | VfsError::Io { path, .. } => path.clone(),
        };
        PlacesError::Io { path, detail }
    }
}

impl From<MetaError> for PlacesError {
    fn from(e: MetaError) -> Self {
        match e {
            MetaError::Vfs(v) => v.into(),
            MetaError::InvalidTag { tag, reason } => PlacesError::InvalidTag { tag, reason },
            MetaError::ConcurrentModification { path } => {
                PlacesError::ConcurrentModification { path }
            }
            other => PlacesError::Sidecar {
                detail: other.to_string(),
            },
        }
    }
}

/// One reverse-geocoded place, matching photo-tools schema §1.3 / §2.2.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaceWrite {
    /// `Places/<Country>[/<Region>[/<City>[/<Neighborhood>]]]`.
    pub path: String,
    /// `photoshop:Country`.
    pub country: Option<String>,
    /// `photoshop:State`.
    pub state: Option<String>,
    /// `photoshop:City`.
    pub city: Option<String>,
    /// `Iptc4xmpCore:Location`.
    pub sublocation: Option<String>,
    /// ISO 3166-1 alpha-2.
    pub country_code: Option<String>,
}

/// Write a Places tag and the IPTC location fields into `image_path`'s sidecar.
///
/// Returns whether bytes were actually written. A photo that already carries a
/// `Places/*` tag is left alone (`false`), which is how a re-run stays a
/// no-op and how a human/photo-tools placement is preserved.
///
/// Concurrent sidecar writes retry a handful of times: tagging or a face
/// naming can land on the same file during an analysis run.
pub fn write_places(image_path: String, place: PlaceWrite) -> Result<bool, PlacesError> {
    let request = PlaceWriteRequest {
        path: place.path,
        country: place.country,
        state: place.state,
        city: place.city,
        sublocation: place.sublocation,
        country_code: place.country_code,
    };
    let vfs = StdVfs;
    // Three tries: the first collision is a tagging/face write landing in the
    // same second, the second is unlucky, the third is something else.
    let mut last = None;
    for _ in 0..3 {
        match gallery_meta::write_places(&vfs, &image_path, &request) {
            Ok(outcome) => return Ok(outcome.written),
            Err(MetaError::ConcurrentModification { path }) => {
                last = Some(PlacesError::ConcurrentModification { path });
            }
            Err(e) => return Err(e.into()),
        }
    }
    Err(last.unwrap_or(PlacesError::Sidecar {
        detail: "exhausted concurrent-modification retries".into(),
    }))
}
