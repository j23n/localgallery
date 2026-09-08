//! Product policy both apps share: Scan Photos order, pack roots, Places
//! eligibility, watch mute, sidecar refresh.
//!
//! Engines and XMP stay in the crates below this one. The GTK / SwiftUI
//! shells hop progress and draw chrome.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod analysis;
pub mod eligibility;
pub mod pack;
pub mod people;
pub mod places;
pub mod refresh;
pub mod watch;

pub use analysis::{
    progress_title, readiness_blurb, run_analysis, AnalysisPhase, AnalysisProgress,
    AnalysisSummary, ProgressFn,
};
pub use eligibility::{is_ml_eligible, is_places_candidate, places_needed};
pub use pack::{
    data_pack_root, default_roots, discover_pack, ml_enabled, resolve_in, PackRoots, PackStatus,
};
pub use places::{run_places, PlacesSummary};
pub use refresh::{refresh_plan, SidecarRefreshPlan};
pub use watch::{should_note, REFRESH_INTERVAL};
