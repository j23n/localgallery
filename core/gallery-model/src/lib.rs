//! Value types and stable identity shared by every LocalGallery frontend.
//!
//! Phase 0 contained only `stable_uuid`. Phase 3 adds the types the scanner
//! produces and the wire format they are persisted in — [`photo`] mirrors
//! `PhotoFile`/`PhotoFolder` field for field, [`snapshot`] mirrors
//! `JSONDiskCache<LibrarySnapshot>` key for key, and [`date`] / [`file_url`]
//! exist because Foundation's `Date` and `URL` have encodings that are easy to
//! approximate and expensive to get wrong.

#![forbid(unsafe_code)]

pub mod date;
pub mod file_url;
pub mod photo;
pub mod snapshot;
pub mod stable_uuid;
pub mod swift_json;

pub use date::{AppleDate, CivilDateTime};
pub use photo::{
    FaceRegion, FileUrl, HierarchicalTag, PhotoFile, PhotoFolder, PhotoLocality, SidecarStatus,
    StableId,
};
pub use snapshot::{
    ContentVersion, DownloadStatus, LibrarySnapshot, SidecarCandidate, SnapshotError,
    LIBRARY_SNAPSHOT_VERSION,
};
