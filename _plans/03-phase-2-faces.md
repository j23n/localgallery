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

## Sidecar writes (in `gallery-meta`)

On naming a cluster (and on subsequent auto-matches into named clusters):

- `People/<Name>` appended to the keyword fields (never removing other
  `People/*` entries — the schema's §2.1 contract, now with the core as the
  face-owner).
- `XMP-mwg-rs:RegionInfo` regions: normalized center/size rects (match the
  shape `MetadataReader.parseMWGRegions` reads: name, centerX/Y,
  width/height), `Type=Face`, applied-to dimensions from the decoded image.
  Merge with existing regions by geometric overlap (IoU > 0.5 → replace,
  else append) so digiKam-authored regions survive.
- Un-naming / renaming a person rewrites affected sidecars accordingly
  (rename = keyword + region Name swap; batched, atomic per file).

## FFI additions

```
faces_open(cache_db_path, model_pack_dir) -> FaceSession
session.enqueue(paths) / start(progress) / cancel()      // same shape as tagging
session.clusters() -> Vec<ClusterSummary>                // id, size, state, name?,
                                                         //   exemplar (path + bbox) list
session.cluster_faces(id, page) -> Vec<FaceRef>
session.name_cluster(id, name) -> SidecarWritePlan       // core writes, returns touched paths
session.ignore_cluster(id) / merge(a, b) / split(id, face_refs)
session.rename_person(old, new) -> touched paths
```

Face crops for the UI are **not** shipped over FFI as pixels: Swift crops
from its own thumbnail pipeline using the returned bbox (`ThumbnailView`
already renders arbitrary photos; add a crop overlay/mode).

## App integration (Swift)

- Model pack v2 adds the two face models (manifest versioning from Phase 1
  handles staleness of RAM-side rows — face rows are new tables, unaffected).
- `Services/FaceService.swift` mirroring `TaggingService`: runs after (or
  interleaved with, queue-priority-below) tagging.
- **New UI: People review** — entry point on the People screen ("N new
  people to review"): cluster grid → cluster detail (faces, exemplars) →
  actions: Name (TextField + contact-name suggestions from existing
  `ContactsService`), Merge, Ignore, Split. One type per file, under
  `Views/Collections/`.
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
