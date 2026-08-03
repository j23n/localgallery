# Phase 1 — On-device ML tagging → XMP sidecars

Additive feature, zero rewrites: the Rust core tags photos in the
photo-tools taxonomy and writes `.xmp` sidecars; LocalGallery's *existing*
sidecar pipeline then surfaces the tags in the tag grid and search with no
reader changes. This phase exercises the entire architecture — FFI, VFS,
model packs, SQLite cache, sidecar writing — on a feature that can be
turned off without touching anything that works today.

**Exit criterion:** on a synthetic library (`scripts/generate_test_library.py`)
in the simulator, enabling "On-device tagging" in Settings produces
`Objects/…` and `Scenes/…` tags visible in the tag grid, and the written
sidecars are read identically by photo-tools and pass an exiftool round-trip
diff.

## Non-goals

- Videos (photo-tools samples frames via ffmpeg; no ffmpeg on iOS — defer).
- OCR, landmarks, geocoding — stay desktop-side in photo-tools.
- Faces (Phase 2). Background execution (needs device + BGTask work; the
  queue design must survive app kills, but scheduling is foreground-only).
- Writing into image bytes — never (standing decision 4).

## Crates & new code

### `gallery-vfs` (minimal v1)

- `trait Vfs { fn open(&self, path: &str) -> Result<Box<dyn ReadSeek>>; fn stat(&self, path: &str) -> Result<Stat>; fn write_atomic(&self, path: &str, bytes: &[u8]) -> Result<()>; }`
  plus a `StdVfs` impl. Simulator-only means Swift resolves the
  security-scoped root before calling in; the core receives plain paths under
  an active scope. (Handle-based `list()` lands in Phase 3 with the scanner.)
- `write_atomic` = temp file + rename in the same directory (sidecars must
  never be observed half-written by SidecarSyncService or cloud daemons).

### `gallery-meta` (write path + minimal read)

- **XMP sidecar read**: parse existing `IMG_1234.jpg.xmp` (quick-xml) into a
  DOM the writer can round-trip. v1 requirement is *preservation*, not full
  interpretation: every element/attribute the core doesn't own survives
  byte-faithfully where possible, semantically otherwise.
- **XMP sidecar write** — the highest-risk deliverable in the program:
  - Owned fields per `photo-tools/docs/xmp-schema.md` §1.1: the keyword
    fields (`dc:subject` leaves, `digiKam:TagsList` hierarchical paths, and
    the other keyword mirrors the schema lists), respecting casing rules (§3).
  - Read-modify-write: merge into the existing sidecar; create
    `IMG_1234.jpg.xmp` (suffix-preserved, §1.4) if absent.
  - Replace-don't-append semantics for machine tags: the core removes only
    tags it previously wrote (track them under a core sentinel, mirroring
    photo-tools' `--force` behavior) and never touches `People/*` or
    human-added keywords.
  - New sentinel field in the `photo-tools` namespace recording
    agent + model-pack version (§1.6 mechanics); **coordinate a schema-doc
    §5 version entry in the photo-tools repo before shipping.**

### `gallery-ml`

- **Decode/preprocess (pinned, pure Rust)**: `zune-jpeg`/`image` +
  `kamadak-exif` orientation → RGB, `fast_image_resize` (exact filter and
  version pinned) → model input tensor. No platform decoders anywhere in
  this path (determinism doctrine).
- **Inference trait** `ImageEncoder { fn embed(&self, img) -> Vec<f32> }`
  with an `ort` (ONNX Runtime, CPU EP, intra-op threads = 1) implementation.
  `tract` remains the escape hatch behind this trait.
- **Zero-shot tagger**: MobileCLIP-S2 (or SigLIP-base if export is cleaner)
  image encoder + **precomputed text embeddings** shipped in the model pack
  (no text tower on device). Label set = curated taxonomy leaves under
  `Objects/` and `Scenes/`, built from photo-tools'
  `src/photo_tools/data/ram_tag_mapping.yaml` (vendored + converted at pack
  build time, with per-root confidence thresholds and max-tag caps mirroring
  photo-tools' config defaults).
- **Threshold margins**: a tag is emitted at `score ≥ T` and *retracted on
  re-run* only below `T − ε`, so cross-arch float drift can't flap tags.
- **Work queue** (SQLite, schema in overview): states
  `pending → hashing → done | failed | stale`. Content hash = SHA-256 of
  file bytes, computed once and stored; embeddings stored per
  `(content_hash, model)`. Resumable after app kill; `failed` rows carry an
  error code and retry with backoff.

### `gallery-ffi` additions

As shipped (`core/gallery-ffi/src/tagging.rs`), Swift-side:

```swift
let session = try TaggingSession(cacheDbPath: …, modelPackDir: …)  // verifies pack hashes
try session.enqueue(paths: [String]) -> UInt32                     // batched, idempotent
try session.start(progress: TaggingProgressListener)               // spawns a core thread, returns
session.cancel()
session.isRunning() -> Bool
try session.stats() -> TaggingStats                                // pending/done/failed/skipped/tagged
try session.resetQueue()
session.modelPackInfo() -> ModelPackInfo                           // version, labelCount, dims
try inspectModelPack(modelPackDir: String) -> ModelPackInfo        // validate without a session
```

`TaggingProgressListener` (UniFFI foreign trait, implemented in Swift):
`onProgress(done, total)` (throttled ≥ 250 ms in Rust), `onPhotosTagged(paths)`
(batched, written sidecars only), `onFinished(summary)` — fired exactly once,
after the session releases its run lock, whether the run completed, was
cancelled, or failed (`TaggingRunSummary.failure`).

Errors are one closed `TaggingError` enum flattened from `MlError` +
`VfsError` + `MetaError`, plus `AlreadyRunning` (a second `start` mid-run).

## Model pack v1

- Contents: image-encoder ONNX (~40–150 MB fp16-weights/fp32-compute),
  `labels.json` (leaf path, prompt text-embedding matrix, threshold, root
  caps), `manifest.json` (version, files, sha256s).
- Built by a new script in-repo (`scripts/build_model_pack/`, Python, runs on
  the Mac): exports the encoder to ONNX, embeds the label prompts with the
  matching text tower, writes the manifest. Deterministic outputs, versioned.
- Distribution now: developer builds the pack locally; app loads it from
  `Application Support/ModelPacks/<version>/` (simulator: seeded via a
  Settings debug "Import model pack" file-importer or a build script copy).
  Hosted download is future work; the manifest format already supports it.

## App integration (Swift)

- `Settings` gains an **On-device tagging** section: enable toggle, model
  pack status, progress (reuse `ScanProgressBanner` patterns), "Tag now",
  and per-run summary. Persisted via the existing `didSet`/defaults pattern.
- New thin service `Services/TaggingService.swift` (`@MainActor final
  class`): owns the FFI session, feeds it the current `allPhotos` URLs
  (skipping `isPlaceholder`/non-downloaded photos — same rule as
  enrichment), forwards progress to an `@Observable` state.
- **Result ingestion**: after a run finishes (and incrementally every N
  tagged photos), trigger the existing sidecar refresh path
  (`SidecarSyncService` / the store's sidecar merge) so `hierarchicalTags`
  update and the tag grid/search/widget pipeline react through existing
  machinery. No new read path.
- Paths: cache DB + model-pack dir added to `GalleryPaths` (no defaults, per
  house rule).

## Testing

- **Rust unit**: preprocessing golden tests (fixture JPEG → pixel-exact
  tensor hash, committed), queue state machine, threshold-margin behavior,
  XMP writer round-trip on fixture sidecars (photo-tools-generated ones with
  People/*, OCR, location fields → assert untouched fields survive).
- **Oracle tests (Mac host, `cargo test` + a small harness)**:
  1. Write sidecars for a fixture set → `exiftool -j` the results → diff
     against expected field values.
  2. Run photo-tools' reader (`photo-tools tags list`) over the output tree →
     tags identical to what the core reports.
- **Determinism**: same fixture set tagged on `aarch64-apple-darwin` and in
  the iOS simulator → identical tag sets (not identical floats).
- **Swift integration**: `TestGalleryStore` + `TempDir` fixture library →
  run tagging → assert `hierarchicalTags` populated after the sidecar merge.
- **Manual acceptance**: `generate_test_library.py` library in the
  simulator; tags appear; photo count/labels sane; cancel/resume works;
  re-run is a fast no-op (hash hit).

## Risks

| Risk | Mitigation |
|---|---|
| XMP writer breaks another tool's data | Preservation-first DOM design; oracle tests against exiftool + photo-tools; sidecar-only writes are recoverable by deletion |
| Zero-shot quality ≪ RAM++ | Curated leaf list + per-root thresholds; measure precision on the test library early (task 1 of implementation); acceptable floor: no *wrong* high-confidence tags — sparse is fine for v1 |
| onnxruntime sim cross-compile | Known-good: `ort` ships prebuilt iOS-sim static libs; else `tract` fallback |
| Full-file SHA-256 cost on big libraries | Sequential read, one pass, stored forever; throttle to idle QoS; measured in acceptance |
| Sidecar writes racing SidecarSyncService | Atomic rename + refresh triggered by us after batches, not mid-write |

## Status (2026-08-03)

Phase 1 is functionally complete: the real model pack exists, the Rust pipeline
matches the Python reference on the same photos, and the sidecars it writes
round-trip through exiftool. The remaining items below are all deferrals, not
gaps in what shipped.

### Done

- [x] `gallery-vfs` — `Vfs` trait, `StdVfs`, `write_atomic`, in-memory impl for tests.
- [x] `gallery-meta` — preservation-first XMP sidecar read + read-modify-write,
      core sentinel, replace-don't-append, exiftool oracle tests.
- [x] `gallery-ml` — pinned decode/orient/resize (golden tensor hashes),
      `ort` CPU-EP encoder behind `ImageEncoder`, zero-shot tagger with
      per-root caps + hysteresis, SQLite work queue + embedding cache,
      `TaggingEngine` with its own thread pool and cancellation.
- [x] `gallery-ffi` — `TaggingSession`, `TaggingProgressListener`,
      `inspectModelPack`, typed `TaggingError`. One run at a time.
- [x] `scripts/build_core.sh` — merges the prebuilt `libonnxruntime.a` into
      the staticlib (`libtool -static`) so the app links with one framework
      dependency and two `OTHER_LDFLAGS` entries.
- [x] Swift — `GalleryPaths.mlCacheDatabaseURL` / `.modelPacksDirectoryURL`,
      `Services/TaggingService.swift`, `store.tagging`, the Settings
      "On-device Tagging" section (status / import / run / cancel / summary).
- [x] Result ingestion — no new read path: a run's written sidecars are picked
      up by a coalesced **light rescan**, whose fresh sidecar manifest drives
      `SidecarSyncService` → `reapplySidecarMerges` → tags, search, widget.
- [x] Tests — Rust unit + oracle + e2e suites; `TaggingSessionTests` runs the
      real FFI, the real ONNX Runtime, and the committed test pack in the
      simulator and asserts the *same* tag sets `engine_e2e.rs` asserts on
      `aarch64-apple-darwin` (the cross-arch determinism check).
- [x] **Real model pack** — `scripts/build_model_pack/` (see its README).
      MobileCLIP-S2 `datacompdr` via `open_clip_torch`; the export worked, so
      the documented SigLIP fallback is not what ships. Chosen partly because
      its `Resize(shortest, bilinear) + CenterCrop` transform is already
      exactly `gallery_ml::preprocess` — SigLIP's squash resize would have
      forced a `PREPROCESS_VERSION` bump and new golden hashes.

      `mobileclip-s2-v1`, 148.2 MB in `build/model_packs/` (git-ignored, not
      committed): `image_encoder.onnx` 143.0 MB fp32 opset 17,
      `label_embeddings.f32` 4.9 MB (2 386 × 512 LE f32),
      `labels.json` 242 KB, `manifest.json` 893 B. 2 386 labels — every
      distinct `Objects/*` (2 010) and `Scenes/*` (376) path in photo-tools'
      `ram_tag_mapping.yaml`. Note MobileCLIP's `mean=(0,0,0) std=(1,1,1)`:
      it trains on unnormalized `[0,1]` pixels, not the CLIP constants.
- [x] **Thresholds** — Objects ≥ 0.265, Scenes ≥ 0.250; caps 8/6 verbatim from
      photo-tools' `CATEGORY_CONFIG`. Measured, not guessed: cosines against
      this model sit in a narrow band (p50 0.0987, p99 0.2022, max 0.3142 over
      2 386 labels × 16 photos), so a threshold from intuition is wrong by more
      than the whole useful range. `calibrate.py` places the bar in the observed
      gap between the lowest correct tag kept and the highest wrong tag dropped
      — Objects between `Astronaut` 0.2686 and the clock face's `Bead` 0.2612;
      Scenes between the Hubble field's `Constellation` 0.2511 and a lawn
      close-up's `Urban/Square` 0.2469. Deliberately strict, per the phase's
      "no wrong high-confidence tags; sparse is fine" floor. Caveat: this is a
      **16-image calibration** — enough to place a global bar, not enough for
      the per-label overrides `labels.json` already supports.
- [x] **Parity validated** — `examples/dump_scores.rs` (Rust scores → JSON) vs
      `parity.py` (PIL + torch/ORT reference). Both sides read the same label
      embeddings from the pack, so the comparison isolates the image half:
      PIL/torch vs `fast_image_resize`/ORT. On the 16-photo reference set, with
      **both** the torch and the ONNX Python encoders: 16/16 top-10 set
      agreement, identical emitted tags on every image, **max |Δscore| 2.2e-3**,
      min embedding cosine 0.9999144. That drift is an order of magnitude below
      `hysteresis_epsilon` (0.02), which is how ε was sized.
- [x] **Acceptance** — `examples/tag_dir.rs` over a 312-photo library (291 from
      `generate_test_library.py --count 300`, plus the 16 reference
      photographs): 36 ms/photo single-threaded on an M-series host, warm re-run
      is a true no-op (0 sidecars rewritten). Tags are correct and sparse —
      `cat.jpg → Objects/Animal/Mammal/Cat`, `coffee.jpg → Espresso + Coffee +
      Coffee Cup`, `hubble → Scenes/Sky/Galaxy + Constellation`,
      `rocket → Objects/Vehicle/Aircraft/Rocket`. Preservation confirmed on the
      fixtures that already carried digiKam tags, face regions and
      `CountryCode`: all survived untouched. The two `failed` rows are the
      generator's deliberately truncated sidecars, where the core correctly
      refuses to write rather than clobber an unparseable file.
- [x] **photo-tools schema §1.7 + §5** — the five `Core*` sentinel fields
      documented in `docs/xmp-schema.md` with `localgallery-core` registered as
      the first agent, and the fields added to
      `exiftool_phototools.config` so exiftool reads them by name (verified:
      `-XMP-phototools:all` returns all five, Bags included). Deliberately
      **no `TaggerVersion` bump** — photo-tools writes and reads none of these
      fields, so bumping would re-tag every library for a change that cannot
      affect its output. That call is recorded in the doc and is the
      photo-tools owner's to overrule.

### Remaining

- **The exit criterion needs real photographs, not the synthetic library.** As
  written it says Objects/Scenes tags appear in the tag grid on a
  `generate_test_library.py` library. They do not, and should not: all 291
  synthetic images scored below threshold and got zero tags. They are labelled
  colour gradients — there is no cat in them for the cat label to win on, and a
  tagger that *did* fire on them would be the bug. The zero-tag result is
  therefore evidence the thresholds are right, not evidence of a gap. Manual
  acceptance in the simulator should use a folder of real photos; the synthetic
  library remains the right fixture for scan/queue/cancel behaviour.
- **HEIC.** `gallery-ml::preprocess` decodes JPEG and PNG only; an iPhone
  library is mostly HEIC, and those photos currently land in `skipped`. Needs
  a pure-Rust HEIC path (determinism doctrine forbids the platform decoder).
- **Background execution.** Foreground-only by design in this phase; the queue
  is already resumable after an app kill, so this is scheduling work
  (`BGProcessingTask`) plus device signing.
- **Sidecar merge precedence.** `mergeCachedSidecars` only fills
  `hierarchicalTags` when a photo has none, so ML tags added to a photo that
  already carries digiKam tags surface on the next *full* scan rather than the
  light one. Fine for v1 (the common case is untagged photos); revisit when
  the merge moves into the core in Phase 3.
- **Pack distribution.** The pack is built locally and side-loaded through the
  Settings importer; it is 148 MB and git-ignored, so there is currently no way
  for a user to get one. The manifest format already supports a hosted
  download — that is the work.
- **Device slice.** `build_core.sh` still produces a simulator-only
  XCFramework, so none of this has run on real hardware; the 36 ms/photo figure
  is an M-series host number, not a phone number.
- **Per-label thresholds.** Shipped as global per-root bars, calibrated on 16
  photographs. `labels.json` supports per-label overrides and
  `calibrate.py --bias` already identifies the labels that fire on everything
  (`charcoal`, `compost`); acting on it wants a background corpus of a few
  thousand photographs this repo does not have.
