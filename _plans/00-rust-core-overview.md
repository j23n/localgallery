# Rust core: overview & standing decisions

Extract a shared Rust core from LocalGallery that future Linux / macOS /
Android apps reuse, and add on-device ML (photo tagging in the photo-tools
taxonomy, face recognition) that produces identical results on every device.

Phases (each ships independently; each has its own plan file):

| Phase | File | Delivers | Status |
|---|---|---|---|
| 0 | `01-phase-0-toolchain-spike.md` | Rust workspace, UniFFI → Swift, XCFramework build, StableUUID parity proof | shipped |
| 1 | `02-phase-1-ml-tagging.md` | On-device tagging → XMP sidecars (additive; no existing Swift rewritten) | shipped |
| 2 | `03-phase-2-faces.md` | Face detect/embed/cluster + naming UI → `People/*` + MWG-RS regions | shipped |
| 3 | `04-phase-3-scanner-metadata.md` | `MetadataReader` + `FolderScanner` move into core behind a VFS trait | shipped — both Swift types deleted |
| 4 | `05-phase-4-indexes-memories.md` | Search/tag indexes + MemoryEngine port; Swift engine deleted | shipped — `SearchIndex`, `TagIndex`, `MemoryEngine` + its 4 extensions deleted |
| 5 | `07-face-editing-and-rename.md` | Cluster merge/split, merge proposals surfaced, rename-person UI | planned |
| 6 | `08-heic-support.md` | HEIC embedded XMP, then HEVC decode for tagging + faces | planned |
| 7 | `09-bundled-model-pack.md` | Ship the model pack in the app bundle; import becomes an override | planned |
| 8 | `10-widget-timezone-fix.md` | Fix the pinned memory-id / widget-horizon timezone bug | shipped — ids name the local day; both memories fixtures regenerated |

Phases 5–8 are the follow-ups the extraction deliberately deferred, not a
second extraction: 5 and 8 finish behaviours the earlier phases left
half-built, 6 closes the one format gap that costs a modern iPhone library most
of its photos, and 7 is distribution. They are independent of each other and
can ship in any order; 8 was the smallest and the only one that fixed a bug
users could hit today.

With Phase 4 the extraction is **complete for the behaviours it set out to
move**: no ordering, matching, or memory-selection rule is implemented twice.
What remains in Swift under `Services/` is either platform-bound (Foundation
file IO, file-provider XPC, thumbnails, contacts, widgets) or policy the core
was deliberately not given (scan kinds and dedupe, the once-a-day memory gate,
sidecar refresh coalescing). The two Phase-4 bridges — `CoreLibraryIndex` and
`CoreMemories` — hold no rules of their own: an object table, a memo, an
off-main hop, and a cancel flag.

**Sequencing rule: Phase 1 before any extraction of existing behavior.** It
proves the toolchain and sidecar contract on a purely additive feature; if the
Rust bet fails, nothing that works today is lost.

**Performance baseline:** `06-performance-baseline.md` — measured 20k-photo
numbers (2026-08-03), three known bottlenecks with root causes, and the perf
gates Phases 3–4 must meet (scan probe serialization, `LibrarySnapshot`
sidecar-manifest field, MemoryEngine architecture rules for the port).

## Standing decisions (agreed 2026-08-02)

1. **Derived-data cache = SQLite** (`rusqlite`, bundled sqlite). One DB,
   `gallery-cache.sqlite`, owned exclusively by the Rust core. Holds ML work
   queue, embeddings, face detections, clusters. Everything in it is
   recomputable — never treated as truth, never synced.
2. **Library snapshot stays JSON.** The Rust core reads/writes the existing
   `LibrarySnapshot` JSON shape byte-compatibly (Phase 3). No SQLite migration
   for library state; revisit only if 100k-photo load times hurt.
3. **Device + simulator slices.** Build targets: `aarch64-apple-darwin`
   (tests) + `aarch64-apple-ios` + `aarch64-apple-ios-sim`. Android
   (`cargo-ndk`) is deferred but the design must not preclude it. Folder-
   management / security-scope work beyond what exists stays out of scope
   for the core port.
4. **Sidecars are the portable truth.** Durable results (tags, people, face
   regions) are written to `IMG_1234.jpg.xmp` sidecars per the photo-tools
   schema (`photo-tools/docs/xmp-schema.md`). The core **never rewrites image
   bytes**. Derived-but-recomputable data (embeddings, unlabeled clusters,
   thumbnails) stays in the local cache DB.
5. **Determinism doctrine: decision-identical, not bit-identical.** Same
   pinned model weights (SHA-256-verified), preprocessing done entirely in
   Rust (pinned decode + resize — never platform decoders), CPU execution
   provider only, thresholds applied with a margin so within-epsilon float
   drift never flips a tag. Results are keyed by **content hash** and
   published to sidecars, so the common cross-device case *reads* rather than
   recomputes.
6. **Core lives in-repo** at `core/` (a Cargo workspace) for velocity.
   Extraction to its own repo happens when a second app exists; nothing in
   the app may reach into crate internals — only the FFI surface — so the
   move stays mechanical.

## Workspace layout

```
core/
  Cargo.toml            # workspace
  gallery-model/        # types, stable IDs, serde for LibrarySnapshot JSON
  gallery-vfs/          # filesystem trait + std-fs impl (desktop/tests)
  gallery-meta/         # EXIF/XMP read, sidecar merge precedence, sidecar WRITE
  gallery-scan/         # scanner + snapshot store            (Phase 3)
  gallery-index/        # search + tag indexes                (Phase 4)
  gallery-memories/     # MemoryEngine port                   (Phase 4)
  gallery-ml/           # decode/preprocess/inference/cluster (Phases 1–2)
  gallery-ffi/          # UniFFI surface; the only crate the apps see
scripts/build_core.sh   # cargo build → uniffi-bindgen → GalleryCore.xcframework
build/core/             # xcframework + generated Swift (git-ignored)
```

## FFI rules (apply to every phase)

- **UniFFI, proc-macro mode** (`#[uniffi::export]`, no UDL files). Swift
  bindings now; Kotlin comes free later.
- **Coarse-grained calls only.** Never per-photo FFI chatter against a
  100k-photo library. Batch results; progress via a callback trait invoked at
  most a few times per second.
- **VFS is handle-based, not path-based** (`list(dir) -> [Entry]`,
  `open(entry) -> ReadHandle`), so Android SAF (`content://`, fds) fits later
  without a rewrite. On iOS/simulator the impl is a thin wrapper over paths;
  security-scope start/stop stays in Swift, outside the core.
- Long work runs on core-owned threads; the FFI exposes start/cancel/progress.
  Cancellation must actually stop file IO and inference between items.
- Errors cross the boundary as typed enums, never strings.

## Cache DB (SQLite) — shared schema, grown per phase

Location: app support dir, path injected from Swift (mirrors the
`GalleryPaths` no-defaults rule). Single writer (the core); WAL mode.

```sql
-- Phase 1
CREATE TABLE meta         (key TEXT PRIMARY KEY, value TEXT);         -- schema_version, model_pack
CREATE TABLE ml_work      (content_hash BLOB PRIMARY KEY, rel_path TEXT,
                           state INTEGER, model_pack TEXT, updated_at INTEGER);
CREATE TABLE embeddings   (content_hash BLOB, model TEXT, dim INTEGER,
                           vec BLOB, PRIMARY KEY (content_hash, model));
-- Phase 2
CREATE TABLE faces        (content_hash BLOB, face_idx INTEGER, bbox BLOB,
                           landmarks BLOB, quality REAL, embedding BLOB,
                           PRIMARY KEY (content_hash, face_idx));
CREATE TABLE clusters     (cluster_id INTEGER PRIMARY KEY, centroid BLOB,
                           state INTEGER /* unlabeled|named|ignored */,
                           person_name TEXT);
CREATE TABLE cluster_members (cluster_id INTEGER, content_hash BLOB,
                           face_idx INTEGER,
                           PRIMARY KEY (content_hash, face_idx));
```

`content_hash` = SHA-256 of file bytes (not the path-based `StableUUID`), so
renames/moves don't recompute and results are shareable across devices.

## Model packs

- A model pack = manifest JSON (`version`, per-model `url` + `sha256` + file
  size) + the ONNX files. Swift downloads (URLSession) into
  `Application Support/ModelPacks/<version>/` and hands the directory to the
  core; the core verifies hashes before loading. Networking stays out of Rust.
- Every persisted result records the model-pack version; a pack upgrade marks
  affected `ml_work` rows stale rather than wiping them.
- Inference: ONNX Runtime via the `ort` crate, **CPU EP only**, fixed
  single-threaded intra-op per image (parallelism is across images), pinned
  `ort`/onnxruntime version. Fallback if cross-compiling onnxruntime becomes a
  tarpit: `tract` (pure Rust, slower) — the `gallery-ml` inference trait must
  keep this swap possible.

## Interop obligations (photo-tools ecosystem)

- Follow `photo-tools/docs/xmp-schema.md`: keyword fields (§1.1), casing
  (§3), sidecar naming `IMG_1234.jpg.xmp` suffix-preserved (§1.4), sentinel
  mechanics (§1.6).
- Face work takes the role the schema reserves for "face-detector tools":
  the core (not photo-tools) owns `People/*` keywords and
  `XMP-mwg-rs:RegionInfo`.
- Sidecar writes are read-modify-write and must preserve every field the core
  doesn't own (mirror of photo-tools preserving `People/*`).
- Coordinate a version entry in the schema doc (§5) declaring the new agent
  and any new sentinel field before Phase 1 ships.

## Cross-cutting risks

| Risk | Mitigation |
|---|---|
| XMP writer correctness (no exiftool on iOS) | Sidecar-only writes; exiftool + photo-tools reader as CI oracles (Phase 1 plan §Testing) |
| Path/Unicode parity for StableUUID (APFS NFD vs NFC) | Test vectors include decomposed names; settled in Phase 0 |
| FFI chattiness at 100k photos | Batch APIs, measured in Phase 3 acceptance |
| onnxruntime cross-compile pain | `tract` escape hatch behind the inference trait |
| Float drift flipping tags across archs | Threshold margins + content-hash result sharing (doctrine §5) |
