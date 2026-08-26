//! REMOVE AFTER this one-shot has shipped and libraries have had a chance to
//! run it (a launch or a face scan).
//!
//! Dismissals (`Ignored` / `Rejected`) used to live only in the cache. They
//! now write `CoreFaceDecisions` into the sidecar so another machine can
//! reconstruct them. This pass re-derives every dismissed cluster's sidecars
//! once, so already-dismissed faces catch up without the user tapping again.
//!
//! Delete, in this order:
//! 1. this file
//! 2. `mod face_decision_resync` in `face/mod.rs`
//! 3. the block in `FaceEngine::run_inner`
//! 4. `FaceSession::resync_face_decisions_once` in `gallery-ffi`
//! 5. `FaceService.resyncFaceDecisionsOnce` and its call in `refreshClusters`
//! 6. the tests under `REMOVE AFTER: face-decision-resync` in `face_naming_e2e.rs`
//!
//! The `meta` row can stay. It is one unused key and nothing reads it.

use crate::error::MlResult;

use super::engine::FaceEngine;
use super::naming::{SidecarWritePlan, SyncScope};

/// `meta` key. Leave it in the DB when this module goes; do not add a
/// migration just to delete it.
pub const META_KEY: &str = "face_decision_resync";

const DONE: &str = "1";

impl FaceEngine {
    /// Re-derive every ignored/rejected cluster's sidecars, once per cache.
    ///
    /// No-op after a successful pass. A pass with write failures is not
    /// stamped, so the next launch or run retries.
    pub fn resync_face_decisions_once(
        &self,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        if self.cache().meta(META_KEY)?.as_deref() == Some(DONE) {
            return Ok(SidecarWritePlan::default());
        }

        let hashes = self.cache().dismissed_cluster_hashes()?;
        let plan = self.sync_sidecars(&hashes, tagged_at, &SyncScope::under(root_prefix))?;
        if plan.failed.is_empty() {
            self.cache().set_meta(META_KEY, DONE)?;
        }
        Ok(plan)
    }
}
