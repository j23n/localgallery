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

uniffi::setup_scaffolding!("GalleryCore");

pub mod tagging;

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
