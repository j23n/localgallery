//! LocalGallery Linux host: scan, enrich, index. The GTK shell lives in `main`.

pub mod config;
pub mod decode;
pub mod display;
pub mod faces;
pub mod host;
pub mod watch;
pub mod xdg_thumb;

#[cfg(feature = "ui")]
pub mod ui;

pub use config::Config;
pub use host::{
    collection_groups, event_folders, find_folder, leaf_tags, library_availability, patch_tree,
    reapply_sidecars, CollectionGroup, HostError, LibraryAvailability, LibraryState,
};
