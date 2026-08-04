//! Folder traversal: the tree, the flat photo list, and the diff against the
//! last scan.
//!
//! A port of `LocalGallery/Services/FolderScanner.swift`, and *only* that.
//! Scan **policy** — light/full/auto resolution, the 48-hour promotion, the
//! dedupe of concurrent requests, the two-phase ordering, and the
//! sidecar-sync / memories / widget steps that follow a scan — stays in
//! `GalleryStore+Scanning.swift`. This crate walks the tree and reports what
//! it found; deciding *when* to walk it is somebody else's job.
//!
//! ```no_run
//! use gallery_scan::{scan, ScanInput};
//! use gallery_vfs::StdVfs;
//!
//! let outcome = scan(&StdVfs, "/photos", &ScanInput::default());
//! println!("{} photos, {} new", outcome.flat_photos.len(), outcome.added_paths.len());
//! ```
//!
//! # What is pinned here rather than decided here
//!
//! The conformance fixtures in `core/fixtures/scan-conformance/` are the spec,
//! generated from the shipping Swift implementation. Several of the behaviours
//! this crate reproduces are bugs — the light-scan blind spot, a standalone
//! video's lowercased filename, videos never getting a sidecar row. They are
//! reproduced deliberately. `tests/scanner_conformance.rs` runs the same four
//! passes the Swift harness ran and compares every field; the module docs on
//! [`scan`] explain each one where it happens.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod classify;
pub mod order;
pub mod path_form;
pub mod scan;

pub use classify::{classify, MediaKind};
pub use order::localized_standard_compare;
pub use scan::{scan, scan_with_hooks, scan_with_progress, ScanInput, ScanOutcome, ScanStats};
