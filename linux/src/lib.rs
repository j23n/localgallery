//! LocalGallery Linux host: scan, enrich, index. The GTK shell lives in `main`.

pub mod config;
pub mod decode;
pub mod display;
pub mod faces;
pub mod host;
pub mod ops;
pub mod persist;
pub mod row;
pub mod thumbs;
pub mod time;
pub mod watch;
pub mod xdg_thumb;

#[cfg(feature = "ui")]
pub mod ui;

pub use config::{Config, ConfigLoad};
pub use host::{
    collection_groups, commit_analysis_state, event_folders, find_folder, leaf_tags,
    library_availability, open_library, open_library_with_commit, overlay_sidecars, patch_tree,
    reapply_sidecars, reapply_sidecars_with_commit, scan_input_for_open, CollectionGroup,
    HostError, LibraryAvailability, LibraryState, SnapshotReuse,
};
pub use row::{PhotoRow, UnsupportedPath};
