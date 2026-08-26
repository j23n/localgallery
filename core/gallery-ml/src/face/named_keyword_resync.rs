//! REMOVE AFTER this one-shot has shipped and libraries have had a chance to
//! run it (a launch or a face scan).
//!
//! Confirms used to drop the `People/<Name>` keyword when every face on a
//! photo was below the quality floor. Confirm now writes the keyword; this
//! pass re-derives already-named clusters so those photos catch up.
//!
//! Delete, in this order:
//! 1. this file
//! 2. `mod named_keyword_resync` in `face/mod.rs`
//! 3. the block in `FaceEngine::run_inner`
//! 4. `FaceSession::resync_named_keywords_once` in `gallery-ffi`
//! 5. `FaceService.resyncNamedKeywordsOnce` and its call in `refreshClusters`
//! 6. the tests under `REMOVE AFTER: named-keyword-resync` in `face_naming_e2e.rs`
//!
//! The `meta` row can stay. It is one unused key and nothing reads it.

use crate::cache::ClusterState;
use crate::error::MlResult;

use super::engine::FaceEngine;
use super::naming::{SidecarWritePlan, SyncScope};

/// `meta` key. Leave it in the DB when this module goes; do not add a
/// migration just to delete it.
pub const META_KEY: &str = "named_keyword_resync";

const DONE: &str = "1";

impl FaceEngine {
    /// Re-derive every named cluster's sidecars, once per cache.
    ///
    /// No-op after a successful pass. A pass with write failures is not
    /// stamped, so the next launch or run retries.
    pub fn resync_named_keywords_once(
        &self,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        if self.cache().meta(META_KEY)?.as_deref() == Some(DONE) {
            return Ok(SidecarWritePlan::default());
        }

        let mut hashes = Vec::new();
        for cluster in self.cache().clusters()? {
            if cluster.state == ClusterState::Named {
                hashes.extend(self.cache().cluster_hashes(cluster.id)?);
            }
        }

        let plan = self.sync_sidecars(&hashes, tagged_at, &SyncScope::under(root_prefix))?;
        if plan.failed.is_empty() {
            self.cache().set_meta(META_KEY, DONE)?;
        }
        Ok(plan)
    }
}
