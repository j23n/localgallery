# Phase 5 — Face cluster merge/split, and a rename that reaches the UI

The three gaps the Phase-2 plan left open, all in the same area of the code:
`merge_proposals` are computed and stored but nothing can act on one, `split`
does not exist at all, and `FaceSession.renamePerson` has no caller above
`FaceService`.

**Exit criterion:** a user can, from the People tab, merge two clusters the
core proposed (or two they picked), pull a wrongly-grouped face out of a
cluster, and rename an already-named person — each of which rewrites the
affected sidecars and lands in the people rail through the existing light
rescan, with no new read path.

## Non-goals

- No automatic merging. The core proposes; the user decides. Auto-merge on a
  similarity threshold is exactly the operation that, when wrong, writes
  somebody else's name into a stranger's sidecar — the thing
  `ClusteringConfig::auto`'s gate exists to prevent.
- No per-person "recent auto-adds" review list. That is the other Phase-2
  safety valve and it is a separate change (it needs a `named_at`/`auto` flag
  on `cluster_members` that nothing records today).
- No change to detection, embedding, alignment, or the clustering algorithm.
  This phase only edits the *partition* after the fact.

## Current state, established by reading the code

| thing | where | state |
|---|---|---|
| `cluster_merge_proposals (a, b, similarity, proposed_at)` | `cache.rs:213` | written, normalized `a<b`, pruned; `merge_proposals()` reads them; **no consumer** |
| `merge(a,b)` / `split(id, faces)` | — | do not exist |
| `clusters (cluster_id INTEGER PRIMARY KEY AUTOINCREMENT, centroid, dim, size, state, person_name, updated_at)` | `cache.rs:194` | AUTOINCREMENT, so a deleted id is **never reused** — the property the pack-swap review finding made load-bearing |
| `cluster_members (content_hash, face_idx, cluster_id)` | `cache.rs:204` | `ON DELETE CASCADE`, indexed by cluster |
| `rename_person(old, new, …)` | `face/naming.rs:306` | renames **every** cluster carrying `old`; a name nobody carries is an empty plan, not an error |
| `recluster()` | `face/engine.rs:763` | deletes every `Unlabeled` cluster and rebuilds from `unlabeled_faces()`; named and ignored clusters are untouched |
| `FaceRef` | `gallery-ffi/src/faces.rs:397` | path + MWG rect + quality — **no stable face identity crosses the FFI** |
| write-gating | `gallery-ffi/src/faces.rs` | every writer refuses with `AlreadyRunning` during a run; reads stay open |
| `PeopleStore` | `Services/PeopleStore.swift` | *every* persisted key is a person **tag path** (`People/Anna`): `hiddenPeople`, `pinnedPeople`, `featuredPhotoByPerson`, `mePersonPath` |

Two consequences fall straight out of that table and drive the whole design.

### Consequence 1: an unlabeled merge is not durable

`recluster()` throws away the unlabeled partition and recomputes it. A merge of
two *unlabeled* clusters is therefore undone by the next full re-cluster, and
so is a split of one. That is not acceptable for an operation the user
performed deliberately — it is worse than not offering it, because the work
silently reverts.

**Decision: a hand-edited cluster is pinned.** Add `pinned INTEGER NOT NULL
DEFAULT 0` to `clusters` (cache schema v4, additive migration — the existing
`ALTER TABLE` migration path in `cache.rs` already carries schema steps), set
by `merge` and by both sides of a `split`, and read by `recluster()`, which
excludes pinned clusters and their member faces from the pass exactly the way
it already excludes named ones. `unlabeled_faces()` grows the same exclusion.

Pinning rather than naming, because "these two are the same person, I don't
know who" is a legitimate end state and forcing a name to make it stick would
put junk in sidecars.

`unname_cluster` clears `pinned` along with the name — its documented job is
"put this back in play for the full re-cluster pass", and that must keep
meaning what it says.

### Consequence 2: split needs a face identity the FFI does not have

`FaceRef` carries a path and a rectangle. A rectangle is not an identity: two
detections in one photo can overlap, and the app would be selecting faces by
geometry. Add `face_key: String` to `FaceRef` — `"<content-hash-hex>:<idx>"`,
the exact `(content_hash, face_idx)` primary key of `faces`/`cluster_members`,
opaque to Swift. Parsed back in one place in `gallery-ffi`, rejected with
`FaceError::InvalidFaceKey` when malformed, and *not* required to still exist
(a key whose row is gone is skipped, not fatal — the cache moved under a review
screen the user left open).

This is an additive record field; `ClusterSummary.exemplars` gets it for free.

## Design

### `merge(into: i64, from: i64)`

Signature is directional on purpose: `into` survives, `from` disappears. The
UI, not the core, decides direction (see below), so the core needs no policy.

1. Load both clusters; `ClusterNotFound` if either is missing; `InvalidMerge`
   if `into == from`.
2. Read `from`'s members and both clusters' member embeddings **before** any
   write.
3. Re-point every `cluster_members` row of `from` to `into`
   (`set_cluster_member` is already an upsert on the `(hash, idx)` PK).
4. Recompute `into`'s centroid over the union of embeddings
   (`cluster::centroid`), write it with the new size.
5. `pinned = 1` on `into`.
6. Delete `from` (`delete_clusters`), and delete every merge proposal naming
   either id (a proposal against a dead cluster is a dangling row, and one
   against `into` is stale — its similarity was computed against the old
   centroid).
7. Name resolution:
   - both unnamed → result unnamed, pinned.
   - exactly one named → the name survives; it is now claimed by the absorbed
     faces too, so their photos gain the `People/<Name>` keyword and a region.
   - both named, **different** names → `from`'s name is retracted. The
     retraction goes through `SyncScope::retracting(from_name)`, which is a
     *hint*: `sync_sidecars` re-derives each photo's packet from live cache
     state, so a photo that still has another cluster carrying that name keeps
     it. This is the same mechanism `rename_person` relies on and it is already
     tested.
   - both named, **same** name → nothing to retract; this is the "two groups of
     one person" case `rename_person`'s doc comment already anticipates.
8. `sync_sidecars` over the union of both clusters' content hashes, scoped by
   `root_prefix`, returning the usual `SidecarWritePlan`.

Note what is *not* done: the faces of `from` are not re-embedded, re-detected,
or re-scored. A merge is a bookkeeping change plus a sidecar rewrite.

### `split(cluster_id: i64, face_keys: &[(hash, idx)])`

1. `ClusterNotFound` for a missing cluster. Resolve the keys against
   `cluster_members` of *this* cluster; keys not in it are ignored (with a
   count returned, so the app can log a stale-selection case).
2. `InvalidSplit` when the resolved set is empty or is the whole cluster —
   both are no-ops that would otherwise leave an empty or duplicate cluster
   behind.
3. Create a new cluster from the selected embeddings' centroid, `pinned = 1`,
   state `Unlabeled`, **no name** — see the decision below.
4. Move the selected `cluster_members` rows to it; recompute the source's
   centroid and size over what is left; `pinned = 1` on the source too (the
   user asserted something about it).
5. Drop merge proposals touching either id.
6. `sync_sidecars` over the union of both clusters' hashes, retracting the
   source's name if it had one.

**Split-off faces do not keep the name.** The user's gesture means "this is not
that person" — carrying the name across would make split a no-op for the only
reason anyone reaches for it. The sidecar consequence is a retraction on any
photo where the split-off face was the *only* claim to that name, which is
correct, and no change where another face of that person remains, which is also
correct. Both fall out of the re-derivation and neither needs special-casing.

### `mergeProposals()` on the FFI

`Vec<MergeProposal { a: i64, b: i64, similarity: f32 }>`, ids only. The app
already holds `clusters()` and joins locally — sending two `ClusterSummary`
values per proposal would ship the same exemplars several times over on a
library with a chain of similar clusters.

Proposals are computed during a run (`cluster::merge_proposals`) and pruned;
this phase only exposes them. A proposal whose cluster is gone is dropped at
read time as well as by `prune_merge_proposals`, because a merge performed
between the two is exactly the common case.

### Rename

The core call needs no change. What is missing is above it.

**`rename_person(old, new)` where `new` is an existing person's name is an
implicit merge at the name level** — every cluster carrying `old` is relabeled
`new`, and both sets of clusters then answer `clusters_named(new)`. That is
coherent and is what a user asking to rename "Anna" to "Anna Schmidt" (already
present) means. The UI must *say so* rather than silently doing it: a
confirmation that names the photo counts on both sides.

`InvalidName` covers empty, whitespace-only, and any name containing `/`
(which would be a different tag path). Casing is preserved as typed; a
case-only rename ("anna" → "Anna") still rewrites sidecars, which is the point.

### The Swift state migration nobody can skip

`PeopleStore` keys four persisted values by tag path. A rename that does not
migrate them silently loses the user's "me" person, their pins, their hidden
set and their cover photos — the failure is invisible until they look for it.

Add `PeopleStore.renamePerson(from:to:)`, called by the Store *after* the core
call reports success and *before* the rescan:

- `hiddenPeople`: remove old path, insert new (set semantics collapse a
  collision, which is right).
- `featuredPeople`: replace in place, preserving order; de-duplicate if the new
  path is already pinned.
- `featuredPhotoByPerson`: move the entry; **the new name wins** if both exist
  (the user just chose that name).
- `mePersonPath`: rewrite if it matched.

`ContactLinker.personContactLinks` is derived from the tag index and rebuilds
on the next publish, so it needs nothing — but check `PersonLink`'s persistence
key before assuming it; if it is keyed by path it joins the list above.

## Order of work

### 1. Core — schema, merge, split

- `core/gallery-ml/src/cache.rs`: schema v4 (`pinned` column + migration),
  `set_cluster_pinned`, `move_cluster_members(from, into)`,
  `delete_merge_proposals_for(ids)`, `unlabeled_faces()` and `clusters()`
  callers in `recluster` excluding pinned.
- `core/gallery-ml/src/face/naming.rs`: `merge_clusters`, `split_cluster`.
  They belong here and not in `engine.rs` — both end in `sync_sidecars`, and
  `naming.rs` is the half that owns writing to somebody's files.
- `core/gallery-ml/src/error.rs`: `InvalidMerge`, `InvalidSplit`,
  `InvalidFaceKey`.

Tests, in `naming.rs`'s existing style (a `MemVfs` library + the committed
facepack is not needed — these are cache-level operations):

- merge moves members, recomputes the centroid, deletes the source, and the
  surviving id is unchanged;
- a deleted cluster id is never handed out again (AUTOINCREMENT, asserted
  explicitly because a future `WITHOUT ROWID` or migration could break it);
- named + unnamed → absorbed photos gain the keyword and a region;
- named + differently-named → the loser's name is retracted only where no
  other cluster still claims it (two photos, one shared);
- split refuses empty and refuses the whole cluster;
- split of a named cluster retracts the name from the split-off photos and
  leaves the others;
- `recluster()` leaves pinned clusters and their faces alone;
- `unname_cluster` clears `pinned`.

### 2. FFI

- `FaceRef.face_key` (additive).
- `FaceSession.merge_clusters(into:from:)`, `.split_cluster(clusterId:faceKeys:)`
  → `SplitResult { new_cluster_id: i64, ignored_keys: u32, report: SidecarWriteReport }`,
  `.merge_proposals()`.
- `.dismiss_merge_proposal(a:b:)`, so "Not the same" is durable against the
  next read.
- The **writers** go through the same `AlreadyRunning` gate as `name_cluster`;
  the gate is the reason none of them needs to think about the auto-tag pass
  mutating the cluster table underneath it.

  **Correction, made while implementing:** `merge_proposals()` is *not* gated.
  It is a read, and the rule that keeps `clusters()` open during a run — a
  review screen must not go blank for the length of a scan — is the same rule
  here. Gating it would make the "Suggested merges" section vanish mid-run
  while the cluster grid beside it kept rendering, which is the failure mode
  the exemption exists to prevent. Reads stay open; writes refuse.
- `FaceSessionTests` (simulator, real FFI, committed facepack): merge two
  clusters and assert the sidecars on disk; split and assert the retraction;
  both refused mid-run.

### 3. Swift service

`FaceService`: `merge(into:from:)`, `split(cluster:faces:)`,
`mergeProposals()`, each mirroring the existing `name(cluster:as:)` — off-actor
call, `allClusters` refresh, `noteSidecarsWritten` into the shared
`SidecarRefreshCoalescer`. Nothing new in the results path: the light rescan →
`SidecarSyncService` → `reapplySidecarMerges` → `PeopleStore` chain already
carries `People/*` keywords and MWG regions.

### 4. UI

**Merge** surfaces in two places, same sheet:

- `PeopleReviewView` grows a "Suggested merges" section above the cluster grid,
  one row per proposal: two `PersonThumbnailView` exemplar strips, the
  similarity as a plain-language confidence, and *Merge* / *Not the same*.
  "Not the same" deletes the proposal (a new `dismissProposal` on the session —
  otherwise the same suggestion returns after every run).
- `ClusterReviewView` gets "Merge with…" in its toolbar, opening a picker over
  the other clusters (named first, then unlabeled by size).

Direction is decided in the UI, not by the user: **the named cluster survives**;
with two named clusters the one with more faces survives and the sheet says
whose name is being dropped; with none named, the larger survives. The button
label always names the outcome ("Merge into Anna").

**Split** lives inside `ClusterReviewView`, which already renders every face in
a cluster. Add a selection mode (`EditButton`-style toggle → multi-select on
the face grid → "Move to new group"). A confirmation states the retraction in
words when the cluster is named: *"These 4 faces will no longer be tagged
Anna."*

**Rename** goes in `PersonContextMenu`, next to Me/Feature/Link/Hide, as
"Rename Person…" → a text field pre-filled with the current name, with
`FaceService.isRunning` disabling it (the core would refuse anyway; a disabled
control explains why better than an error). Collision with an existing person
is confirmed explicitly: *"Anna Schmidt already exists. Renaming will combine
both (312 photos)."*

The menu is shared by `PersonCard` and the people list, so one change reaches
every entry point. Rename is hidden when `FaceService.isAvailable` is false —
a tagging-only pack has no cluster table to rename in, and the `People/*` tags
in that case came from somebody else's tool.

### 5. Swift tests

- `PeopleStoreTests`: rename migrates all four keys, including the two
  collision cases (pinned twice, cover photo on both sides).
- `FaceServiceTests`: mutations refused while running; `allClusters` refreshed
  after each.

## Risks and open questions

| Risk | Response |
|---|---|
| Pinning makes `recluster()` progressively useless as a user edits | Pinned clusters are still re-*assigned* to by new faces during a run (`cluster::assign` is unaffected); only the wholesale repartition skips them. Settings' "Reset Tagging Data" is the escape hatch — it should clear `pinned` and say so. |
| A merge across a pack change | Cluster ids are per-`face_pack_key`; the review finding that produced that rule stands. Merge inherits it for free by operating only on ids read from the current session. |
| Sidecar churn on a large merge | A 5 000-photo merge writes 5 000 files. `SidecarWriteReport` already returns counts rather than paths for exactly this. The coalescer bounds the rescans, not the writes. |
| Selection staleness | A review screen open across a run can hold face keys the run deleted. Split ignores unknown keys and reports the count rather than failing the whole operation. |
| Two merge proposals forming a chain (a↔b, b↔c) | Merging a+b invalidates the b↔c row; deleting proposals touching either id at merge time is what keeps the list honest. The user re-runs a scan to get fresh proposals against the new centroid. |
