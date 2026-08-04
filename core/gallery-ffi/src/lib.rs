//! The only crate the apps see.
//!
//! UniFFI proc-macro mode (no UDL). The namespace passed to
//! `setup_scaffolding!` names the generated Swift module, so the bindings land
//! as `GalleryCore.swift` / `GalleryCoreFFI.h` — see `scripts/build_core.sh`.
//!
//! FFI rules (from `_plans/00-rust-core-overview.md`): coarse-grained calls
//! only, typed error enums, long work on core-owned threads.
//!
//! Surface:
//!
//! * Phase 0 — [`core_version`], [`stable_uuid`].
//! * Phase 1 — [`tagging`]: [`TaggingSession`] and its progress listener.
//! * Phase 2 — [`faces`]: [`FaceSession`], its progress listener, and the
//!   cluster-review calls (`clusters` / `cluster_faces` / `name_cluster` /
//!   `rename_person` / `unname_cluster` / `ignore_cluster` / `recluster`).
//! * Phase 3 — [`scanner`]: [`ScannerSession`], the [`ProviderProbe`] Swift
//!   implements, the snapshot IO, and the metadata read path that replaced
//!   `MetadataReader`. Unlike the two sessions above it is request/response —
//!   see that module's docs for why it is still an object.
//! * Phase 4 — [`library`]: [`LibraryIndex`] (the photo table, the sorted
//!   order, the search corpus and the tag buckets) plus the memory engine as
//!   free functions over an inputs snapshot, with [`MemoryGenerator`] carrying
//!   the one piece of state a generation needs — its cancel flag.
//!
//! The two sessions are siblings sharing one cache file: [`support`] holds the
//! run-thread mechanics both are built on.

uniffi::setup_scaffolding!("GalleryCore");

pub mod faces;
pub mod library;
pub mod scanner;
mod support;
pub mod tagging;

pub use faces::{
    ClusterState, ClusterSummary, FaceError, FaceFailure, FaceLibraryStats, FaceProgressListener,
    FaceRef, FaceRunSummary, FaceSession, FaceStats, ReclusterSummary, SidecarWriteReport,
};
pub use library::{
    compute_scheduled_memories, generate_memories, memory_cluster_key, memory_country_name,
    scheduled_memory_horizon_days, LibraryIndex, LibraryIndexSummary, LibraryTagSuggestions,
    MemoryContact, MemoryDateEntry, MemoryGenerationInputs, MemoryGenerator, MemoryKind,
    MemoryLeafFolder, MemoryPersonLink, MemoryRecord, ScheduledMemoryRecord, TagSuggestionRecord,
};
pub use scanner::{
    load_snapshot, parse_xmp_bytes, probe_snapshot_version, read_image_metadata, read_video_date,
    save_snapshot, snapshot_version, ImageMetadataRecord, ProviderProbe, ScanContentVersion,
    ScanError, ScanFolderNode, ScanLocality, ScanOutcomeRecord, ScanPhoto, ScanProgressListener,
    ScanRegion, ScanRequest, ScanSidecarRow, ScanTag, ScanTimings, ScannerSession,
    SidecarParseRecord, SnapshotRecord, VfsProviderAttrs, WallClock,
};
pub use tagging::{
    inspect_model_pack, ModelPackInfo, TaggingError, TaggingFailure, TaggingProgressListener,
    TaggingRunSummary, TaggingSession, TaggingStats,
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
