//! Reverse-geocoded Places writes and the path/eligibility rules.
//!
//! A free function rather than a session: there is no ONNX, no queue, and no
//! run lock — each photo is one read-modify-write of its sidecar.

use gallery_meta::{MetaError, PlaceWriteRequest};
use gallery_vfs::{StdVfs, VfsError};

/// Why a Places write failed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
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
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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
/// finished `Places/*` tag is left alone (`false`). A *strict prefix*
/// (`Places/France` → `Places/France/…/Paris`) is upgraded.
///
/// Concurrent sidecar writes retry a handful of times: tagging or a face
/// naming can land on the same file during an analysis run.
#[uniffi::export]
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

/// `Places/<Country>/…` from already-normalized fields. Duplicate levels
/// collapse. `None` when every field is empty.
#[uniffi::export]
pub fn place_from_parts(
    country: Option<String>,
    state: Option<String>,
    city: Option<String>,
    sublocation: Option<String>,
    country_code: Option<String>,
) -> Option<PlaceWrite> {
    gallery_meta::place_from_parts(
        country.as_deref(),
        state.as_deref(),
        city.as_deref(),
        sublocation.as_deref(),
        country_code.as_deref(),
    )
    .map(|r| PlaceWrite {
        path: r.path,
        country: r.country,
        state: r.state,
        city: r.city,
        sublocation: r.sublocation,
        country_code: r.country_code,
    })
}

/// Nested Places path, missing levels collapsed.
#[uniffi::export]
pub fn places_path(
    country: Option<String>,
    state: Option<String>,
    city: Option<String>,
    sublocation: Option<String>,
) -> Option<String> {
    gallery_meta::places_path(
        country.as_deref(),
        state.as_deref(),
        city.as_deref(),
        sublocation.as_deref(),
    )
}

/// `Places/France` is a strict prefix of `Places/France/Île-de-France/Paris`.
#[uniffi::export]
pub fn is_strict_places_prefix(existing: String, newer: String) -> bool {
    gallery_meta::is_strict_places_prefix(&existing, &newer)
}

/// No finished city-depth Places tag in `tags`.
#[uniffi::export]
pub fn places_still_needed(tags: Vec<String>) -> bool {
    gallery_meta::places_still_needed(tags)
}
