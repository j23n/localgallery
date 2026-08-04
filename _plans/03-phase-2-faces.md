# Phase 2 — Face detection, embedding, clustering, naming

The core detects faces, embeds them, clusters them locally, and — once the
user names a cluster — writes `People/<Name>` keywords plus
`XMP-mwg-rs:RegionInfo` regions to sidecars. This is exactly the role the
photo-tools schema reserves for "face-detector tools" (§1.5, §2.1), so the
whole ecosystem (photo-tools' `PersonInImage` projection, digiKam,
Lightroom) picks the results up unmodified. LocalGallery already parses
MWG-RS regions (`MetadataReader.parseMWGRegions`) and drives the People UI
from `People/*` tags + `FaceRegion`s, so named results round-trip into the
existing `PeopleStore` with **no reader changes**.

**Exit criterion:** on a fixture library, clusters of the same person form;
naming a cluster in the new review UI writes sidecars; after the sidecar
refresh the person appears in the existing People tab with a face-region
cover crop; digiKam opened on the same tree shows the same people/regions.

## Status

**Done — the whole path, from detection to a named person on the People tab.**

- `gallery-ml::face` — detect / align / embed / quality / cluster, plus
  `FaceEngine` and its queue (`face_work`, `face_scans`, `faces`, `clusters`,
  `cluster_members`, `cluster_merge_proposals`).
- `gallery-meta::regions` + `gallery-meta::faces` — `mwg-rs:RegionInfo` read,
  IoU merge and write; `People/*` fan-out to `digiKam:TagsList` /
  `dc:subject` / `lr:hierarchicalSubject`; the `iptcExt:PersonInImage`
  projection; the `phototools:CoreFacePack` / `CorePeople*` / `CoreRegions`
  ownership sentinel. Registered in the photo-tools schema doc §1.7 and in
  `exiftool_phototools.config`.
- `gallery-ml::face::naming` — `name_cluster` / `rename_person` /
  `unname_cluster` / `ignore_cluster` / `sync_sidecars`, plus the auto-tag pass
  at the end of a run (gated on `ClusteringConfig::auto` **and**
  `min_quality`, and switchable off via `FaceRunOptions::skip_auto_tagging`).
- Workspace tests green including the exiftool oracle, covering
  preservation of digiKam-authored regions, `MetadataReader.parseMWGRegions`
  parity (we write digiKam's Name/Type/Area field order, not exiftool's
  alphabetical one — see the note in `regions::append_region`), idempotence,
  and byte-determinism across independent libraries.
- `gallery-ffi::faces` — `FaceSession` (`enqueue` / `start` / `cancel` /
  `isRunning` / `stats` / `libraryStats` / `resetQueue` / `clusters` /
  `clusterFaces` / `nameCluster` / `unnameCluster` / `ignoreCluster` /
  `renamePerson` / `recluster`), the `FaceProgressListener` foreign trait, and
  the typed `FaceError`. Everything that writes refuses with `AlreadyRunning`
  mid-run; reads stay open. `ClusterSummary` carries ≤4 exemplars, chosen best
  quality first and one per photo where possible, as **normalized MWG
  rectangles** — no pixels cross the boundary. `gallery-ffi::support` holds the
  `RunLock` / `FinishGuard` / `join_unless_current` mechanics, now shared with
  the tagging session rather than duplicated.
- `CacheDb::cluster_face_thumbs` — the ranked, capped, embedding-free read the
  review grid needs, so a cluster card does not drag 512 floats per face across
  a screenful of clusters.
- `Services/FaceService.swift` — mirrors `TaggingService` (session held across
  runs, cancel-before-start, off-actor open/release, root scoping) and shares
  the new `SidecarRefreshCoalescer` with it. Availability is read off
  `TaggingService.pack.hasFaces` (new `ModelPackInfo.hasFaces`) rather than
  re-discovering and re-hashing the pack.
- **UI** — Settings' On-device Tagging section grows a faces sub-block ("Scan
  Faces" + progress/cancel + last-run line), present only for a face-capable
  pack; the People screen grows `PeopleReviewRow` →`PeopleReviewView`
  (cluster grid) → `ClusterReviewView` (faces, Name with contact/library
  suggestions, Not a Person). Crops reuse `PersonThumbnailView` unchanged.
- **Tests** — `FaceSessionTests` (9) over the committed `tests/facepack` and
  face fixtures: full run e2e, exemplar policy, naming → `People/*` + regions
  readable by `MetadataReader.parseXMPBytes`, un-naming removing only ours,
  `AlreadyRunning` for a second start *and* for every write call, root scoping.
  `FaceServiceTests`: availability, eligibility parity with tagging, the
  scan → name → refresh cycle, the review threshold, naming refused mid-run,
  cancel-before-start, refresh coalescing, plus the review-round regressions
  below. `SidecarRefreshCoalescerTests` covers the coalescer's two rules and
  the one-instance-two-engines contract directly.

### Review round: findings fixed

Two independent reviewers reproduced these experimentally. Each fix carries a
named regression test.

**Preservation (the ones that lost data).**

- **A foreign region overlapping ours was deleted.** `is_claimed` asked "does
  *any* claim cover this region", so our claim matched both our box and
  digiKam's box over the same face, and a no-op re-run retracted digiKam's.
  Replaced by `regions::bind_claims`: one claim binds to one region, greedily
  by best IoU. `plan_regions` also looks for *our* box before a foreign one, so
  a file holding both reaches a fixed point instead of alternating.
  (`a_second_tools_box_over_our_own_face_survives_a_no_op_re_run`,
  `un_naming_retracts_our_box_and_leaves_the_other_tools_standing`,
  `one_claim_binds_to_one_region_not_to_every_overlapping_one`.)
- **A write for one person retracted another's name.** The cluster table is
  derived data — a pack swap empties it, a re-detection can lose a face — so a
  request built from it is not the complete truth a replace set claims to be.
  `FaceWriteRequest` grew `Authority`: `gallery-ml` always speaks
  `Partial`, naming the people it can see plus the ones it is deliberately
  retracting (the former name of a cluster being un-named, ignored or renamed).
  A claim for anybody else is left standing.
  (`a_sync_keeps_a_claim_the_cache_can_no_longer_explain`,
  `naming_after_a_pack_swap_preserves_the_names_already_on_disk`, and four
  `Authority` unit tests in `gallery-meta::faces`.)
- **Cluster ids were reused after a face-pack swap.** `reset_face_results`
  deleted the `sqlite_sequence` row for `clusters`; the comment said it
  prevented reuse, and it caused it. Removed — a stale id the UI still holds is
  now a `ClusterNotFound`, which is a correct answer.
  (`resetting_face_results_clears_everything_derived_but_not_the_id_sequence`.)
- **The quality floor gated the counter, not the content.** A below-floor face
  reached disk whenever any other face in the same photo triggered a write.
  Now applied in `build_request`, on every path including a user's
  `name_cluster` — one rule, so the two paths cannot undo each other.
  (`a_below_floor_face_is_left_out_of_a_user_naming_too`; the reasoning is in
  `naming`'s module docs.)
- **Naming ignored the library root.** `face_paths_for_hash` returns every
  queued path for a hash, including rows under a root the app has left, so
  writes were attempted outside the security scope. `SyncScope` threads a root
  prefix through every naming entry point and the run's auto pass; out-of-scope
  paths land in `skipped`. FFI: `nameCluster` / `unnameCluster` /
  `ignoreCluster` / `renamePerson` take `rootPrefix`.
  (`naming_scoped_to_one_root_skips_the_other_roots_copies`,
  `root_scoping_matches_directories_not_string_prefixes`.)
- **`|` was a legal person name.** `Alice|Bob` forged a Lightroom hierarchy
  through `to_lr_path` — one person to digiKam, another to Lightroom. Rejected,
  along with names that are only zero-width/bidi characters. CJK, diacritics,
  RTL and in-word joiners keep working.
  (`person_names_reject_what_would_change_their_identity`,
  `person_names_in_every_script_are_still_names`.)

**Concurrency.**

- **`refuse_while_running` was check-then-act.** `RunLock` grew a gate that
  both `start` and every mutator take (`try_mutate`, non-blocking), so the
  check and the work are one step. (`a_start_cannot_slip_in_beside_a_mutator`,
  `a_mutator_is_refused_while_a_run_is_in_flight`.)
- **Opening a `CacheDb` stomped the other engine's in-flight rows.**
  `from_connection` reclaimed both queues unconditionally; a face session
  opening beside a live tagging run put that run's rows back in the queue.
  Reclaim is now only at run start, where the answer is knowable. A
  `PRAGMA busy_timeout` (5 s) went in at the same time, so the two engines wait
  for each other's write lock instead of failing a photo.
  (`opening_a_second_handle_leaves_the_other_engines_in_flight_rows_alone`,
  `an_abandoned_row_is_reclaimed_at_the_next_run_start`.)
- **`openSession` had no in-flight guard**, in *both* services: two concurrent
  callers each built a session, and the loser's session held the run, so
  `cancel()` reached the wrong one. The open is memoized as a `Task`.
  (`testConcurrentCallersShareOneSession`.)
- **Cross-engine exclusion was cosmetic.** `FaceService.isCoreBusy` is
  `isRunning || tagging.isRunning`, and gates `mutate`, `recluster` and the
  review screen's buttons — the core cannot see the other session's run.
  (`testNamingIsRefusedWhileTheTaggingEngineIsRunning`.)

**App surface.**

- **`clusterFaces` on a dead id returned an empty list**, sending the UI to a
  blank detail screen instead of back to the list. It checks existence first
  and returns `ClusterNotFound`.
- **The review entry point was invisible on a cold launch.** Everything gates
  on `TaggingService.pack`, which stayed nil until Settings ran
  `refreshAvailability()`. `FaceService.ensurePackChecked` (wired by the Store)
  is called from `refreshClusters` and `startScan`.
  (`testRefreshingClustersAsksForThePackToBeCheckedFirst`.)
- **A partly failed naming was silent.** `mutate` cleared `lastError` and
  ignored `report.failed`, so the review screen showed nothing and stayed open.
  Now `FaceServiceError.sidecarWritesFailed(n)`.
  (`testAPartlyFailedNamingSurfacesAnError`.)
- **Failed paths were logged uncapped on the main actor** — a rename can fail
  every photo of a person. Capped at 20 plus a count.
- **The "shared" coalescer was two instances.** One `SidecarRefreshCoalescer`
  is now built by `GalleryStore` and injected into both services, so the 30 s
  rescan window is an app-wide budget rather than one each.
  (`SidecarRefreshCoalescerTests`.)
- **`namedClusters` sorted on size alone** — `sorted(by:)` is not stable, so
  equal-sized groups shuffled between reads. Id breaks the tie
  (`FaceService.biggestFirst`).
  (`testEqualSizedClustersAreOrderedByIdNotByLuck`.)
- **Suggesting an existing person's name implied a merge.** `name_cluster`
  names *this* group; there is no merge. `ClusterReviewView` now says what
  actually happens — the photos join that person everywhere the app shows
  people, and the two groups stay separate here.

**Remaining.**

- **Merge and split.** `merge_proposals` are computed and stored; applying one
  (`merge(a, b)`) and `split(id, face_refs)` are not implemented, and nothing
  surfaces proposals in the UI — offering half of the pair would be worse than
  offering none.
- **Renaming a named person has no UI.** `renamePerson` exists on the session
  and on `FaceService`; the People screens still key off the `People/*` tag and
  no screen calls it.
- **No per-person "recent auto-adds" list.** The risk table wants one as the
  safety valve on auto-tagging; the review screen shows unlabeled clusters
  only.
- **Model pack v2 in production.** The committed `tests/facepack` is
  synthetic; shipping SCRFD-500M + w600k_mbf is a pack build, not code. Until
  then the faces UI only appears for a hand-installed schema-2 pack.
- **Reading clusters costs a full `FaceSession` open.** `FaceService`'s only
  way to the cluster table is through the session, which builds both ONNX
  sessions — so visiting the People tab with a face-capable pack installed
  loads ~16 MB of weights the user may never scan with (off the main actor,
  once per launch, and skipped entirely for a tagging-only pack). A
  cache-only FFI entry point would fix it.
- **The two *runs* are still serialised in the UI, not in the core.** The
  write paths are no longer: `PRAGMA busy_timeout` makes the two connections
  wait for each other, reclaim happens only at run start, and naming is gated
  on both engines (`FaceService.isCoreBusy`). What is left is that Settings
  still disables each run button while the other runs — a face run and a
  tagging run over one library have never been tried together.
- **A name the cache can no longer explain is kept forever.** That is the
  deliberate direction (see `Authority::Partial`), and it has a cost: a person
  who genuinely left a photo — the file was re-edited, the face is gone — stays
  named until something explicitly un-names them, and no UI does that per
  photo. Un-naming or renaming the *cluster* still retracts.
- **Swift-side acceptance:** cover-crop performance with 10–100× more regions,
  and the digiKam cross-check on a real tree. Neither is reachable on the
  synthetic pack — both need the production pack above.

## Non-goals

- Auto-assigning names to new faces of *unreviewed* clusters — matching a
  new face into an already-**named** cluster does auto-tag (that's the
  point), but new identities always require one human naming action.
- Cross-device cluster sync: only *named* results travel (via sidecars);
  unlabeled clusters/embeddings remain per-device cache (standing decision 4).
- Contact linking — stays in Swift (`ContactLinker`), keyed by person name
  exactly as today.

## Pipeline (in `gallery-ml`)

1. **Detection**: SCRFD-500M (or YuNet if the ONNX export is friendlier) on
   a pinned pyramid of the pinned Rust decode. Outputs bbox + 5-point
   landmarks + score; NMS with fixed thresholds.
2. **Alignment**: 5-point similarity transform → 112×112 crop (pure Rust,
   pinned interpolation).
3. **Embedding**: MobileFaceNet/ArcFace-style, 512-d, L2-normalized. Same
   determinism regime as Phase 1 (CPU EP, single-thread intra-op, margins).
4. **Quality score** (detection score × size × frontality proxy) stored per
   face; low-quality faces participate in clustering but are excluded from
   auto-tagging thresholds and cover-crop selection.
5. **Clustering** (plain Rust, deterministic):
   - *Incremental*: each new face joins the nearest **named-or-unlabeled**
     cluster if cosine similarity ≥ `T_join` (named clusters use a higher
     `T_auto` to gate the sidecar write); else seeds a new cluster.
   - *Periodic full pass*: chinese-whispers over the unlabeled faces with a
     **fixed seed and stable iteration order** (sorted by content_hash,
     face_idx) so every device produces the same partition of the same
     inputs. Runs after large ingests; never touches named clusters except
     to propose merges.
   - Merge proposals (two clusters whose centroids exceed `T_merge`) surface
     in the UI rather than auto-merging when either is named.

Storage: `faces` / `clusters` / `cluster_members` tables (overview schema).
All recomputable; content-hash keyed.

## Sidecar writes (in `gallery-meta`) — done

On naming a cluster (and on subsequent auto-matches into named clusters):

- `People/<Name>` appended to the keyword fields (never removing other
  `People/*` entries — the schema's §2.1 contract, now with the core as the
  face-owner), plus the `iptcExt:PersonInImage` projection.
- `XMP-mwg-rs:RegionInfo` regions: normalized center/size rects (match the
  shape `MetadataReader.parseMWGRegions` reads: name, centerX/Y,
  width/height), `Type=Face`, applied-to dimensions from the decoded image.
  Merge with existing regions by geometric overlap (IoU > 0.5 → replace if
  ours, otherwise defer to theirs and add no duplicate) so digiKam-authored
  regions survive.
- Un-naming / renaming a person rewrites affected sidecars accordingly
  (rename = keyword + region Name swap; atomic per file, retried on
  `ConcurrentModification`).

Ownership lives in five new photo-tools fields — `CoreFacePack`,
`CorePeople`, `CorePeopleSubjects`, `CorePeopleHierarchical`, `CoreRegions` —
kept separate from the tagging half's `CoreTags`/`CoreSubjects`/
`CoreHierarchical`/`CoreModelPack` so the two passes do not retract each
other's entries and can both reach a fixed point on the same file. Region
claims are matched by IoU rather than by name, so a region digiKam renames is
still recognisably ours while one digiKam *moves* quietly stops being ours.

## FFI additions — as built

```
FaceSession(cacheDbPath:modelPackDir:)                   // FaceError.ModelsUnavailable
                                                         //   for a tagging-only pack
session.enqueue(paths) / start(progress:rootPrefix:) / cancel() / isRunning()
session.stats() / libraryStats() / resetQueue()
session.clusters() -> [ClusterSummary]                   // id, size, state, name?,
                                                         //   ≤4 exemplar FaceRefs
session.clusterFaces(clusterId:) -> [FaceRef]            // unpaged, best first
session.nameCluster(clusterId:name:rootPrefix:) -> SidecarWriteReport
session.unnameCluster(clusterId:rootPrefix:) / ignoreCluster(clusterId:rootPrefix:)
session.renamePerson(old:new:rootPrefix:) -> SidecarWriteReport
session.recluster() -> ReclusterSummary
```

`FaceRef` is `(path, centerX, centerY, width, height, quality)` — a normalized
MWG rectangle, the shape `FaceRegion` already is, so the app's cover-crop
renderer takes one unchanged. `SidecarWriteReport` is counts plus the failed
paths: the app's response to a write is "rescan", not "walk these files", and a
5 000-photo rename must not hand the main actor a 5 000-element array.

`merge(a, b)` and `split(id, face_refs)` are **not** in the surface — the core
does not implement them.

Deviations from the sketch above: no `page` argument on `cluster_faces` (a
person's cluster is thousands of small records, cheaper to hand over once than
to page); the write calls return the *report*, not the plan (`SidecarWritePlan`
carries three path vectors the app never reads); and every write call refuses
with `AlreadyRunning` mid-run rather than blocking or racing.

Face crops for the UI are **not** shipped over FFI as pixels: Swift crops
from its own thumbnail pipeline using the returned bbox (`ThumbnailView`
already renders arbitrary photos; add a crop overlay/mode).

## App integration (Swift)

- Model pack v2 adds the two face models (manifest versioning from Phase 1
  handles staleness of RAM-side rows — face rows are new tables, unaffected).
- `Services/FaceService.swift` mirroring `TaggingService`: runs after (or
  interleaved with, queue-priority-below) tagging.
- **New UI: People review** — `PeopleReviewRow` on the People screen, shown
  only when there are unlabeled clusters of at least **3 faces** (one- and
  two-face clusters are the tail of any clustering pass and would turn a
  20-card screen into a 400-card one; a cluster appears the moment it grows
  past the bar) → `PeopleReviewView` (cluster grid, biggest first) →
  `ClusterReviewView` (every face, a Name field with suggestions drawn from
  `store.contacts` *and* the library's existing `People/*` tags — no new
  permission, and it degrades to library names when Contacts is denied, plus
  "Not a Person"). One type per file, under `Views/Collections/`. Merge and
  Split are absent; see Status.
- After `name_cluster`/`rename_person`, trigger the sidecar refresh (same
  ingestion path as Phase 1) so `PeopleStore` repopulates through the
  normal scan/merge machinery.
- Person cover selection: `PeopleStore`'s existing face-region cover-photo
  matching keeps working since regions now exist for many more photos —
  verify no perf cliff (it iterates regions; measure on the fixture set).

## Testing

- **Rust**: alignment golden tests (fixture face → pixel-exact 112×112
  hash); clustering determinism (same input set shuffled → identical
  partition); incremental-vs-batch consistency bounds; region-merge IoU
  logic; rename rewrite idempotence.
- **Oracle**: sidecars with regions written by the core → opened in digiKam
  (manual, once per milestone) and parsed by exiftool in CI; fixture
  sidecars authored by digiKam → core preserves their regions and appends
  alongside.
- **Swift integration**: fixture library with known faces (extend
  `generate_test_library.py` to composite a few distinct synthetic faces) →
  enqueue → name → assert `PeopleStore` shows the person after refresh.
- **Determinism**: cluster partitions identical between macOS host and
  simulator runs on the fixture set.

## Risks

| Risk | Mitigation |
|---|---|
| Clustering quality on real libraries (hard lighting/age spread) | Conservative `T_join`; quality gating; Split/Merge UI makes errors cheap; thresholds tunable via model-pack labels file |
| Region write conflicts with digiKam users | IoU-merge policy + preservation tests; core never deletes regions it didn't write |
| Auto-tagging a wrong face into a named cluster (writes to disk) | Higher `T_auto` than `T_join`; quality floor; per-person "recent auto-adds" review list in UI |
| Embedding model bias/quality across demographics | Evaluate on a diverse fixture set before shipping; keep model swappable via pack versioning |
| PeopleStore perf with 10–100× more regions | Measure in acceptance; index by photo id if needed (known-follow-up-style fix, Swift-side) |
