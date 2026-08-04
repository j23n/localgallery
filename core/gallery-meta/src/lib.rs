//! XMP sidecar read and write for the gallery core.
//!
//! The core's durable output is a `.xmp` sidecar next to the photo (overview
//! standing decision 4: **the core never rewrites image bytes**). Sidecars are
//! shared property — photo-tools, digiKam, Lightroom and Apple Photos all write
//! into the same file — so the single hard requirement of this crate is:
//!
//! > A read→modify→write cycle preserves every element, attribute and byte the
//! > core does not own.
//!
//! Everything else (formatting fidelity, determinism, tidy diffs) is in service
//! of that. See [`write`] for what "own" means, and
//! `photo-tools/docs/xmp-schema.md` for the field definitions.
//!
//! ```no_run
//! use gallery_meta::{write_tags, TagWriteRequest};
//! use gallery_vfs::StdVfs;
//!
//! let request = TagWriteRequest::new(
//!     ["Objects/Animal/Dog".to_string(), "Scenes/Nature/Forest".to_string()],
//!     "mobileclip-s2-2026.1",
//!     "2026-08-03T10:00:00Z",
//! );
//! let outcome = write_tags(&StdVfs, "/photos/IMG_1234.jpg", &request)?;
//! assert_eq!(outcome.sidecar_path, "/photos/IMG_1234.jpg.xmp");
//! # Ok::<(), gallery_meta::MetaError>(())
//! ```

#![forbid(unsafe_code)]
#![warn(missing_docs)]

mod edit;
pub mod error;
pub mod faces;
pub mod model;
pub mod read;
pub mod regions;
pub mod schema;
pub mod sidecar;
pub mod tags;
pub mod write;
pub mod xml;

pub use error::{MetaError, MetaResult};
pub use faces::{apply_faces, write_faces, AppliedFaces, Authority, FaceWriteRequest};
pub use model::{AppliedDimensions, CoreSentinel, FaceRegion, PhotoToolsFields, SidecarView};
pub use read::read_view;
pub use regions::{bind_claims, Area, FaceRegionWrite, RegionClaim, REGION_MATCH_IOU};
pub use schema::CORE_AGENT;
pub use sidecar::{alt_sidecar_path, sidecar_path};
pub use tags::{normalize_person, person_tag};
pub use write::{apply_tags, write_tags, AppliedTags, TagWriteRequest, WriteOutcome};
