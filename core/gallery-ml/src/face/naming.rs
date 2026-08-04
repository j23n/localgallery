//! Turning a named cluster into sidecars.
//!
//! Everything above this module stops at the cache DB, which is derived data:
//! delete it and a re-run rebuilds it. Naming is the one thing that is *not*
//! derived — it is a human decision — so this is where it leaves the database
//! and becomes durable, as `People/<Name>` keywords and MWG-RS regions in the
//! photo's `.xmp` (overview standing decision 4: only named results travel).
//!
//! # One rule, three entry points
//!
//! [`FaceEngine::name_cluster`], [`FaceEngine::rename_person`] and
//! [`FaceEngine::unname_cluster`] all do the same two things: change the
//! cluster row, then re-derive the affected *photos'* sidecars from scratch.
//! None of them computes a diff of what to add or remove, because
//! [`gallery_meta::write_faces`] already takes a **replace set per file** and is
//! the only thing that knows what it previously claimed there. So the flow is
//! always:
//!
//! ```text
//! change cluster state ──▶ affected content hashes ──▶ for each hash:
//!     every named face in that photo  (all clusters, not just this one)
//!         ──▶ FaceWriteRequest ──▶ every path with those bytes ──▶ write_faces
//! ```
//!
//! Re-deriving the whole file matters: a photo usually contains more than one
//! person, and a request that named only the cluster being edited would retract
//! everybody else in the frame.
//!
//! # Two paths, one photo
//!
//! Faces are keyed by content hash, sidecars by path, and a library can hold
//! the same bytes twice. [`CacheDb::face_paths_for_hash`] returns every queued
//! path for a hash and all of them are written — the detection is shared, the
//! files are not.
//!
//! The queue outlives any one library root, though, so "every queued path" can
//! include a folder the user has since switched away from — outside the app's
//! security scope, where the write fails. [`SyncScope::root_prefix`] confines a
//! sync to the root in play; paths outside it are **skipped**, not failed, so
//! nothing burns a retry over a file nobody asked about.
//!
//! # Auto-tagging
//!
//! A face that joins an already-named cluster during a run is written out
//! automatically, which is the entire point of naming one. Two gates, both from
//! the pack manifest: the join itself must clear [`ClusteringConfig::auto`]
//! (enforced in [`crate::face::assign`], which holds named clusters to a higher
//! bar than unlabeled ones), and the face's quality must clear
//! [`ClusteringConfig::min_quality`]. A join that clears the first but not the
//! second stays in the cache and shows up in the UI; it does not edit a file.
//! Getting this wrong writes a stranger's name into somebody's photo, so the
//! bar for touching disk is deliberately higher than the bar for grouping.
//!
//! # The quality floor is applied where disk is touched, not where a face joins
//!
//! [`FaceEngine::build_request`] drops every face below
//! [`ClusteringConfig::min_quality`], on **all** paths — the auto pass and a
//! user's `name_cluster` alike. Gating only the auto pass looks more
//! permissive-to-the-user, and is wrong: the request is per *photo*, not per
//! face, so a below-floor face would reach disk the moment any other face in
//! the same photo triggered a write. Worse, the two paths would then disagree
//! about what that photo should say, and each would undo the other's answer —
//! the fixed point the whole sentinel design exists to reach would never
//! arrive. One rule, one answer: the floor is what it takes to be written into
//! somebody's file, whoever started the write. A face under it still shows in
//! the cluster, and raising its quality is a matter of the pack, not of the UI.
//!
//! # Retraction needs a reason
//!
//! `gallery_meta::FaceWriteRequest` is a replace set, and this module cannot
//! honestly produce one: the cluster table is derived data. A face-pack swap
//! empties it; a re-detection can lose a face a previous pack found. A request
//! built from what the cache can see today would then read as "these are the
//! only people here", and retract a name the user typed because a model changed
//! its mind.
//!
//! So every request this module builds is
//! [`gallery_meta::Authority::Partial`]: it speaks for the people it names, and
//! for the names it explicitly lists as retracted — the old name of a cluster
//! being un-named, ignored or renamed. A claim for anybody else is left
//! standing. The cost is a person who genuinely left a photo staying named
//! until something un-names them; the alternative cost is losing names to a
//! model update, which is not recoverable at all.
//!
//! # Idempotence
//!
//! Nothing here decides whether to write. It builds the request and hands it to
//! `write_faces`, which compares the resulting bytes with the file's and
//! reports `written == false` when they match. Re-naming a cluster to the name
//! it already has, or re-running the auto path over unchanged state, therefore
//! touches no mtimes at all — which is what keeps the app's sidecar sync from
//! being woken by a no-op.

use gallery_meta::{write_faces, Area, FaceRegionWrite, FaceWriteRequest};

use super::engine::normalize_root_prefix;

use crate::cache::{ClusterState, NamedFace};
use crate::engine::iso8601_utc_now;
use crate::error::{ErrorCode, MlError, MlResult};

use super::engine::FaceEngine;

/// How many times a sidecar write is retried when another program wrote the
/// file underneath us.
///
/// [`gallery_meta::MetaError::ConcurrentModification`] means nothing was
/// written and a fresh read-modify-write is the correct response. Three
/// attempts covers a digiKam save landing mid-run; a fourth would mean
/// something is writing that file continuously, and reporting the conflict is
/// then more useful than spinning.
pub const SIDECAR_RETRIES: u32 = 3;

/// One sidecar that could not be written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailedWrite {
    /// The photo whose sidecar failed.
    pub path: String,
    /// Stable classification, the same codes the work queues record.
    pub code: ErrorCode,
    /// Message for logs only.
    pub detail: String,
}

/// What a naming operation did.
///
/// Photo paths throughout, not sidecar paths: the app indexes by photo, and
/// `gallery_meta::sidecar_path` derives the other direction for free.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SidecarWritePlan {
    /// Photos whose sidecar bytes changed.
    pub written: Vec<String>,
    /// Photos whose sidecar already said exactly this.
    pub unchanged: Vec<String>,
    /// Photos with nothing to say and no sidecar of ours to correct.
    pub skipped: Vec<String>,
    /// Photos that could not be written.
    pub failed: Vec<FailedWrite>,
}

/// What a sidecar sync is allowed to touch.
///
/// Both fields answer a question the cache DB cannot: it holds rows from every
/// root the app has ever pointed at, and it cannot tell a person it has
/// forgotten from a person who has left the photo.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncScope {
    /// Confine writes to paths under this directory. `None` writes every queued
    /// path for the hash, which is only right when the caller genuinely has no
    /// root (tests, and tools that own the whole filesystem).
    ///
    /// Paths outside land in [`SidecarWritePlan::skipped`].
    pub root_prefix: Option<String>,
    /// Names this operation is deliberately taking back — the former name of a
    /// cluster being un-named, ignored or re-named. Everything else the sidecar
    /// claims and this sync cannot see is left standing; see the module docs.
    pub retracting: Vec<String>,
}

impl SyncScope {
    /// A scope confined to `root`, retracting nothing.
    pub fn under(root: Option<&str>) -> SyncScope {
        SyncScope {
            root_prefix: root.map(|r| r.to_string()),
            retracting: Vec::new(),
        }
    }

    /// The same scope, taking back `name` if there is one to take back.
    fn retracting(mut self, name: Option<String>) -> SyncScope {
        self.retracting.extend(name);
        self
    }

    /// Whether `path` is inside this scope.
    fn covers(&self, path: &str) -> bool {
        match &self.root_prefix {
            Some(root) => path.starts_with(&normalize_root_prefix(root)),
            None => true,
        }
    }
}

impl SidecarWritePlan {
    /// Whether any file on disk changed.
    pub fn touched_disk(&self) -> bool {
        !self.written.is_empty()
    }

    /// Photos considered, in any state.
    pub fn total(&self) -> usize {
        self.written.len() + self.unchanged.len() + self.skipped.len() + self.failed.len()
    }

    fn absorb(&mut self, other: SidecarWritePlan) {
        self.written.extend(other.written);
        self.unchanged.extend(other.unchanged);
        self.skipped.extend(other.skipped);
        self.failed.extend(other.failed);
    }
}

impl FaceEngine {
    /// Attach a person's name to a cluster and write the result to every
    /// affected photo's sidecar.
    ///
    /// The name goes through [`gallery_meta::normalize_person`]: NFC, trimmed,
    /// internal whitespace collapsed, and rejected if it is empty or contains
    /// `/` (which would make it a different tag path, and a different person to
    /// every consumer). Casing is left exactly as typed.
    ///
    /// `tagged_at` is the ISO 8601 UTC stamp for the sentinel; `None` reads the
    /// system clock. Callers that need reproducible bytes pass their own.
    ///
    /// `root_prefix` confines the writes to one library root — see
    /// [`SyncScope`].
    pub fn name_cluster(
        &self,
        cluster_id: i64,
        name: &str,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        let name = gallery_meta::normalize_person(name)?;
        let cluster = self
            .cache()
            .cluster(cluster_id)?
            .ok_or(MlError::ClusterNotFound { id: cluster_id })?;
        // Read the members *before* the state change is irrelevant here — the
        // membership does not move — but do it first anyway so a failure to
        // read leaves the cluster row untouched.
        let hashes = self.cache().cluster_hashes(cluster_id)?;
        if cluster.state != ClusterState::Named || cluster.person_name.as_deref() != Some(&name) {
            self.cache()
                .set_cluster_state(cluster_id, ClusterState::Named, Some(&name))?;
        }
        // Naming a cluster that already carried a *different* name is a rename
        // of this group: the old name is retracted, and saying so explicitly is
        // the only thing that distinguishes it from a name the cache has simply
        // lost sight of.
        let previous = cluster.person_name.filter(|p| *p != name);
        self.sync_sidecars(
            &hashes,
            tagged_at,
            &SyncScope::under(root_prefix).retracting(previous),
        )
    }

    /// Take a cluster's name off and retract it from every affected sidecar.
    ///
    /// The cluster goes back to [`ClusterState::Unlabeled`], which puts it back
    /// in play for the full re-cluster pass — the state it was in before
    /// anybody looked at it.
    pub fn unname_cluster(
        &self,
        cluster_id: i64,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        self.clear_cluster(cluster_id, ClusterState::Unlabeled, tagged_at, root_prefix)
    }

    /// Dismiss a cluster ("not a person") and retract anything it had written.
    ///
    /// [`ClusterState::Ignored`] rather than deleted, so the faces do not come
    /// back as a fresh cluster on every subsequent pass.
    pub fn ignore_cluster(
        &self,
        cluster_id: i64,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        self.clear_cluster(cluster_id, ClusterState::Ignored, tagged_at, root_prefix)
    }

    fn clear_cluster(
        &self,
        cluster_id: i64,
        state: ClusterState,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        let cluster = self
            .cache()
            .cluster(cluster_id)?
            .ok_or(MlError::ClusterNotFound { id: cluster_id })?;
        let hashes = self.cache().cluster_hashes(cluster_id)?;
        if cluster.state != state || cluster.person_name.is_some() {
            self.cache().set_cluster_state(cluster_id, state, None)?;
        }
        // The name this cluster carried is the one thing being taken back.
        self.sync_sidecars(
            &hashes,
            tagged_at,
            &SyncScope::under(root_prefix).retracting(cluster.person_name),
        )
    }

    /// Rename a person everywhere: every cluster carrying `old`, and every
    /// sidecar those clusters reach.
    ///
    /// Several clusters can carry one name — a split, or two groups of the same
    /// person named separately — so this is not "rename cluster N". A name
    /// nobody carries is not an error; it produces an empty plan, which is the
    /// honest answer to "rename somebody who is not here".
    pub fn rename_person(
        &self,
        old: &str,
        new: &str,
        tagged_at: Option<&str>,
        root_prefix: Option<&str>,
    ) -> MlResult<SidecarWritePlan> {
        let old = gallery_meta::normalize_person(old)?;
        let new = gallery_meta::normalize_person(new)?;
        let ids = self.cache().clusters_named(&old)?;
        let mut hashes: Vec<[u8; 32]> = Vec::new();
        for id in &ids {
            hashes.extend(self.cache().cluster_hashes(*id)?);
            if old != new {
                self.cache()
                    .set_cluster_state(*id, ClusterState::Named, Some(&new))?;
            }
        }
        let retracting = (old != new).then(|| old.clone());
        self.sync_sidecars(
            &hashes,
            tagged_at,
            &SyncScope::under(root_prefix).retracting(retracting),
        )
    }

    /// Re-derive and write the sidecars of every photo carrying one of these
    /// content hashes.
    ///
    /// The workhorse behind every entry point above, and the auto-tag path
    /// inside a run. Safe to call with anything: a hash whose photo has no
    /// named faces and no sidecar of ours is skipped rather than given an empty
    /// packet.
    pub fn sync_sidecars(
        &self,
        hashes: &[[u8; 32]],
        tagged_at: Option<&str>,
        scope: &SyncScope,
    ) -> MlResult<SidecarWritePlan> {
        let stamp = match tagged_at {
            Some(s) => s.to_string(),
            None => iso8601_utc_now(),
        };
        // Sorted and deduplicated so a run's writes happen in a fixed order and
        // a photo shared by two edited clusters is written once.
        let mut unique: Vec<[u8; 32]> = hashes.to_vec();
        unique.sort_unstable();
        unique.dedup();

        let mut plan = SidecarWritePlan::default();
        for hash in &unique {
            plan.absorb(self.sync_one_hash(hash, &stamp, scope)?);
        }
        Ok(plan)
    }

    fn sync_one_hash(
        &self,
        hash: &[u8; 32],
        tagged_at: &str,
        scope: &SyncScope,
    ) -> MlResult<SidecarWritePlan> {
        let named = self.cache().named_faces_for_hash(hash)?;
        let paths = self.cache().face_paths_for_hash(hash)?;
        let mut plan = SidecarWritePlan::default();
        if paths.is_empty() {
            return Ok(plan);
        }
        let request = self.build_request(&named, tagged_at, scope);
        let has_content = !request.regions.is_empty() || !request.extra_people.is_empty();

        for path in paths {
            if !scope.covers(&path) {
                // A row from a root the app is no longer inside. Writing it
                // would fail outside the security scope, and failing it would
                // burn a retry on a file nobody asked about.
                plan.skipped.push(path);
                continue;
            }
            if !has_content && !self.sidecar_claims_faces(&path) {
                // Nothing to say and nothing of ours to take back. Writing here
                // would create (or touch) a sidecar to record that we found
                // nobody, on every photo in the library.
                plan.skipped.push(path);
                continue;
            }
            match self.write_with_retry(&path, &request) {
                Ok(true) => plan.written.push(path),
                Ok(false) => plan.unchanged.push(path),
                Err(e) => plan.failed.push(FailedWrite {
                    path,
                    code: e.error_code(),
                    detail: e.to_string(),
                }),
            }
        }
        Ok(plan)
    }

    /// One photo's replace set.
    ///
    /// A face whose stored geometry is degenerate — a zero-area box, or a row
    /// written before the image dimensions were known — contributes its *name*
    /// but no region: the person really is in the photo, and dropping the
    /// keyword because the rectangle is unusable would lose the more valuable
    /// half of the answer.
    fn build_request(
        &self,
        named: &[NamedFace],
        tagged_at: &str,
        scope: &SyncScope,
    ) -> FaceWriteRequest {
        let mut regions = Vec::with_capacity(named.len());
        let mut extra_people = Vec::new();
        let mut size: Option<(u32, u32)> = None;

        for entry in named {
            let face = &entry.face;
            // The image size is read even from a face that will not be written:
            // it describes the *photo*, and `AppliedToDimensions` should not
            // depend on which faces cleared the floor.
            if size.is_none() && face.image_w > 0 && face.image_h > 0 {
                size = Some((face.image_w, face.image_h));
            }
            // The quality floor, applied once, where disk is touched. See the
            // module docs for why the user-initiated path pays it too.
            if face.quality < self.clustering().min_quality {
                continue;
            }
            let corners = [
                f64::from(face.bbox[0]),
                f64::from(face.bbox[1]),
                f64::from(face.bbox[2]),
                f64::from(face.bbox[3]),
            ];
            match Area::from_pixel_box(corners, f64::from(face.image_w), f64::from(face.image_h)) {
                Some(area) => regions.push(FaceRegionWrite {
                    name: entry.person.clone(),
                    area,
                }),
                None => extra_people.push(entry.person.clone()),
            }
        }

        let mut request = FaceWriteRequest::new(regions, self.face_pack_key(), tagged_at)
            .speaking_partially(scope.retracting.iter().cloned());
        request.extra_people = extra_people;
        request.image_size = size;
        request
    }

    /// Whether this photo's sidecar carries a face claim of ours.
    ///
    /// Cheap enough to do per photo (a sidecar is a couple of kilobytes) and it
    /// is what keeps a run from writing a sentinel-only packet next to every
    /// photo with no recognised faces in it.
    fn sidecar_claims_faces(&self, path: &str) -> bool {
        let sidecar = gallery_meta::sidecar_path(path);
        let Ok(bytes) = self.vfs().read(&sidecar) else {
            return false;
        };
        gallery_meta::read_view(&bytes)
            .map(|v| v.core.has_faces())
            .unwrap_or(false)
    }

    /// `Ok(true)` when bytes were written.
    fn write_with_retry(&self, path: &str, request: &FaceWriteRequest) -> MlResult<bool> {
        let mut attempt = 0;
        loop {
            match write_faces(self.vfs(), path, request) {
                Ok(outcome) => return Ok(outcome.written),
                Err(e) if e.is_retryable() && attempt + 1 < SIDECAR_RETRIES => {
                    attempt += 1;
                }
                Err(e) => return Err(MlError::Meta(e)),
            }
        }
    }
}
