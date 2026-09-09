//! The only crate the apps see.
//!
//! UniFFI proc-macro mode (no UDL). The namespace passed to
//! `setup_scaffolding!` names the generated Swift module, so the bindings land
//! as `GalleryCore.swift` / `GalleryCoreFFI.h` — see `scripts/build_core.sh`.
//!
//! FFI rules: coarse-grained calls only, typed error enums, long work
//! on core-owned threads.
//!
//! Surface:
//!
//! * [`core_version`], [`stable_uuid`].
//! * [`tagging`]: [`TaggingSession`] and its progress listener.
//! * [`faces`]: [`FaceSession`], cluster review, name / rename / merge / split.
//! * [`scanner`]: [`ScannerSession`], [`ProviderProbe`], snapshot IO,
//!   metadata reads. Request/response — see that module for why it is
//!   still an object.
//! * [`library`]: [`LibraryIndex`] plus the memory engine as free
//!   functions over an inputs snapshot; [`MemoryGenerator`] holds the
//!   cancel flag.
//! * [`places`]: Nominatim lookup and Places sidecar writes.
//!
//! Tagging and face sessions share one cache file: [`support`] holds
//! the run-thread mechanics both are built on.

uniffi::setup_scaffolding!("GalleryCore");

pub mod faces;
pub mod heic;
pub mod library;
pub mod places;
pub mod scanner;
mod support;
pub mod tagging;

pub use faces::{
    face_merge_direction, ClusterState, ClusterSummary, FaceAssignKind, FaceAssignmentRecord,
    FaceError, FaceFailure, FaceLibraryStats, FaceMergeCandidate, FaceMergeDecision,
    FacePhotoRecord, FaceProgressListener, FaceRef, FaceRunSummary, FaceSession, FaceStats,
    ReclusterSummary, SidecarWriteReport,
};
pub use heic::{HeicDecodeError, HeicDecoder, HeicPixels};
pub use library::{
    compute_scheduled_memories, generate_memories, memory_cluster_key, memory_country_name,
    scheduled_memory_horizon_days, LibraryIndex, LibraryIndexSummary, LibraryTagSuggestions,
    MemoryContact, MemoryDateEntry, MemoryGenerationInputs, MemoryGenerator, MemoryKind,
    MemoryLeafFolder, MemoryPersonLink, MemoryRecord, ScheduledMemoryRecord, TagSuggestionRecord,
};
pub use places::{
    is_strict_places_prefix, library_watch_refresh_interval_ms, nominatim_lookup, place_from_parts,
    places_needed, places_path, places_still_needed, write_places, GeoError, PlaceWrite,
    PlacesError,
};
pub use scanner::{
    load_snapshot, named_people_without_box, parse_xmp_bytes, probe_snapshot_version,
    read_image_metadata, read_sidecar, read_video_date, save_snapshot, snapshot_version,
    ImageMetadataRecord, ProviderProbe, ScanContentVersion, ScanError, ScanFolderNode,
    ScanLocality, ScanOutcomeRecord, ScanPhoto, ScanProgressListener, ScanRegion, ScanRequest,
    ScanSidecarRow, ScanTag, ScanTimings, ScannerSession, SidecarParseRecord, SidecarViewRecord,
    SnapshotRecord, VfsProviderAttrs, WallClock,
};
pub use tagging::{
    inspect_model_pack, resolve_model_pack, ModelPackInfo, PackResolution, PackSource,
    TaggingError, TaggingFailure, TaggingProgressListener, TaggingRunSummary, TaggingSession,
    TaggingStats,
};

/// Version of the Rust core, for logging and "is the framework I linked the
/// one I just built?" sanity checks.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Rust-side `StableUUID.derive`, rendered lowercase hyphenated.
///
/// The caller passes an already-standardized path string (Swift:
/// `url.standardized.path`) — this function does no normalization of its own.
#[uniffi::export]
pub fn stable_uuid(input: String) -> String {
    gallery_model::stable_uuid::derive(&input).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_version_matches_the_crate() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn stable_uuid_is_lowercase_hyphenated() {
        let rendered = stable_uuid("/library/x.jpg".to_string());
        assert_eq!(rendered.len(), 36);
        assert_eq!(rendered, rendered.to_lowercase());
    }
}
