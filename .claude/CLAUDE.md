# LocalGallery

SwiftUI iOS photo gallery app that browses user-selected folders without importing into a library. Targets iOS 18+.

## Build & test

Four commands from a clean checkout — stage the model pack, build the Rust
core, generate the Xcode project, test:

```
./scripts/prepare_pack.sh        # newest build/model_packs/<version> → build/pack/<version> (bundled resource)
./scripts/build_core.sh          # cargo → UniFFI → build/core/{GalleryCore.xcframework,Generated}
xcodegen                         # generates LocalGallery.xcodeproj
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

`prepare_pack.sh` is cheap and idempotent: it clones (APFS `clonefile`, so no
time and no disk) the newest pack under `build/model_packs/` into the fixed
path `project.yml` bundles, and skips when that is already staged. The
version-named directory is kept inside `build/pack` — `PackResolver` compares
the bundled and imported packs *by directory name*, so a pack flattened to
`pack/` would compare as the literal string "pack". It does
**not** build a pack — `build_pack.py` needs torch and ~1 GB of weights, and a
clean checkout must not depend on a Python/PyTorch toolchain — so with nothing
built it exits non-zero printing the exact `build_pack.py` invocation. That
message at the start of the build is the whole point; without the check a
missing pack surfaces as a code-signing error at the end of it.
`PACK_VARIANT=tagging` stages a pack without face models: the insightface
`buffalo_sc` models in the full pack are research / non-commercial licensed, so
anything distributed ships the tagging variant (see README).

Swap `test` for `build` to just compile. `build_core.sh` must run before
`xcodegen` (the project references generated paths) and again after any change
under `core/`. Cargo is deliberately not an Xcode script phase — script
sandboxing fights it. Pass `--release` for an optimized core. Rust-only work:
`cd core && cargo test` (host).

**The first `build_core.sh` on a machine needs network access**: `gallery-ml`
links ONNX Runtime through the `ort` crate, whose build script downloads pyke's
prebuilt static `libonnxruntime.a` (~85 MB) into `~/Library/Caches/ort.pyke.io/`.
Offline builds work with `ORT_LIB_LOCATION=<dir containing libonnxruntime.a>`
— honoured both by `ort-sys` and by the script's merge step. Cargo does not
fold an external static library into its `staticlib` output, so `build_core.sh`
merges the two archives (`libtool -static`) before assembling the xcframework;
the two link requirements an archive can't express (`-lc++`,
`-framework CoreML`) live in `project.yml`'s `OTHER_LDFLAGS`.

Device builds (`-destination "generic/platform=iOS"`) do not work: they need a
signing team *and* an `aarch64-apple-ios` slice in the XCFramework, which
`build_core.sh` does not produce yet (simulator only — standing decision 3 in
`_plans/00-rust-core-overview.md`).

## Structure

Source under `LocalGallery/`. A view-facing Store, two domain stores it
exposes (`store.people`, `store.memories`), and focused services under
`Services/`.

### Rust core (`core/`)

Cargo workspace behind a UniFFI boundary; the roadmap lives in `_plans/`.
Phases 0–4:

- **gallery-model** — `stable_uuid::derive`, the byte-for-byte mirror of
  `StableUUID.derive`.
- **gallery-vfs** — `Vfs` trait + `StdVfs`; `write_atomic` = temp + rename.
- **gallery-meta** — XMP sidecar read/write. Preservation-first
  read-modify-write: the core replaces only what it previously wrote (tracked
  under `photo-tools:Core*` sentinel fields) and never touches human keywords.
  Two halves with **disjoint** ownership lists so they cannot retract each
  other: `write.rs` for machine tags (`CoreTags`/`CoreSubjects`/
  `CoreHierarchical`/`CoreModelPack`), and — Phase 2 — `faces.rs` + `regions.rs`
  for `People/*` keywords, the `iptcExt:PersonInImage` projection and
  `mwg-rs:RegionInfo` face regions (`CorePeople*`/`CoreRegions`/`CoreFacePack`).
  Regions merge with foreign ones by IoU > 0.5 and are written in digiKam's
  Name/Type/Area field order, which is what the region parser (now
  `gallery-meta::media::swift_xmp`) needs to attribute a name to the right box.
- **gallery-ml** — `TaggingEngine`: content hash → embedding cache → pinned
  decode/resize → ONNX Runtime (CPU EP) → zero-shot tagger → `write_tags`.
  Owns `gallery-cache.sqlite` (work queue + embeddings, schema v2). The
  embedding cache is keyed on the **encoder's SHA-256** + `PREPROCESS_VERSION`,
  not `pack_version`, so a labels-only pack rebuild re-scores from cached
  vectors and runs no inference; `pack_version` still drives re-scoring via
  `mark_stale_for_pack`. Every run starts by reclaiming abandoned `hashing`
  rows, re-opening `skipped` rows a previous decoder generation refused, and
  re-statting `done` rows so an in-place edit is re-tagged. Phase 2 adds the
  sibling `face::FaceEngine` — detect / align / embed / quality / cluster, its
  own queue and tables in the same cache file, plus `face::naming`
  (`name_cluster` / `rename_person` / `unname_cluster` / `ignore_cluster` /
  `sync_sidecars`) and the auto-tag pass that extends an already-named cluster
  to newly matched faces. A sibling rather than an extension: the two queues
  must be independently resumable, and a tagging-only pack has to keep working.
  Face results are keyed on `face_pack_key` (the two face model hashes +
  `PREPROCESS_VERSION` + `ALIGN_VERSION`), so adding face models to a pack does
  not re-tag and a labels rebuild does not re-detect.
- **gallery-index** — `SearchIndex` + `TagIndex`, ported (Phase 4).
  `LibraryIndex::build(all_photos)` owns **one** photo table; the sorted order
  (date desc, `url.path` tiebreak), the per-photo search corpus and the tag
  buckets are all lists of indices into it — the sanctioned improvement over
  the Swift `TagIndex`, which copied a whole `PhotoFile` into every bucket a
  photo was credited to. `text::match_key` (lowercase → NFC) is the one thing
  to be careful with: Swift's `String.contains` compares by **canonical
  equivalence**, so a precomposed query has to find a decomposed filename, and
  a byte-comparing port silently stops finding every accented name.
- **gallery-memories** — `MemoryEngine` + `computeScheduledMemories`, ported
  (Phase 4), with the Swift extension-file layout kept as modules
  (`calendar.rs` / `birthdays.rs` / `trips.rs` / `selection.rs`, plus
  `scheduled.rs` and `time.rs` / `locale.rs` for the two things Foundation used
  to supply implicitly). Pure over a `GenerationInputs` snapshot; the calendar
  is an **explicit fixed UTC offset** rather than the ambient `Calendar.current`
  the Swift read. Three deliberate divergences from the Swift, all from
  `_plans/06` Finding 3: people → photos is grouped **once per call** rather
  than once per horizon day, a no-birthday day early-exits before touching a
  photo, and nothing copies a photo. Two more are *tightenings* the Swift could
  not express: the birthday and density walks iterate in first-seen order
  instead of `Dictionary` order. Where the Swift is buggy the bug is **pinned**
  — see the landmine list in `core/fixtures/memories-conformance/README.md`,
  especially the GMT-vs-local id bug the widget horizon inherits.
- **gallery-ffi** — the sole crate the app sees (proc-macro UniFFI, namespace
  `GalleryCore`). Phase 1 adds `TaggingSession` (`enqueue` /
  `start(progress:rootPrefix:)` / `cancel` / `isRunning` / `stats` /
  `resetQueue` / `modelPackInfo`), the
  `TaggingProgressListener` foreign trait, `inspectModelPack`, and the
  `TaggingError` enum. `start` spawns a core-owned thread and returns; a
  second `start` while running is `TaggingError.AlreadyRunning`.
  Phase 2 adds the sibling `FaceSession` (`enqueue` /
  `start(progress:rootPrefix:)` / `cancel` / `isRunning` / `stats` /
  `libraryStats` / `resetQueue` / `clusters` / `clusterFaces` / `nameCluster` /
  `unnameCluster` / `ignoreCluster` / `renamePerson` / `recluster`), the
  `FaceProgressListener` foreign trait (`onPhotosWithFaces` = the cache
  changed, `onSidecarsWritten` = a file did — only the second obliges a
  re-read), and the `FaceError` enum, whose `ModelsUnavailable` is how the app
  learns a pack is tagging-only and `InvalidName` is the one case a user can
  fix by typing something else. `ModelPackInfo.hasFaces` answers the same
  question without opening a session. **Everything that writes —
  name/unname/ignore/rename/recluster/resetQueue — refuses with
  `AlreadyRunning` while a run is in flight** rather than blocking the caller
  or racing the run's own auto-tag pass over the cluster table; reads
  (`clusters`, `clusterFaces`) stay open so a review screen does not go blank
  for the length of a scan. `ClusterSummary` carries ≤4 exemplar `FaceRef`s —
  photo path plus a **normalized MWG centre/extent rectangle**, chosen best
  quality first and one per photo where possible — so Swift crops from its own
  thumbnail pipeline and no pixels cross the boundary.
  `src/support.rs` holds the run-thread mechanics both sessions share:
  `RunLock` (one run at a time, cancel flag, thread slot), the generic
  `FinishGuard` (release the lock *then* report, even on unwind), and
  `join_unless_current` (a listener that restarts or releases the session from
  `onFinished` must not self-join).
  Phase 4 adds `src/library.rs`: the `LibraryIndex` object (`build(photos)` /
  `sortedPhotoIds` / `search(query:requiredTagPaths:)` / `photoIdsForTag` /
  `tagSuggestions` / `photoCount`) and the memory engine as free functions
  (`generateMemories`, `computeScheduledMemories`, `scheduledMemoryHorizonDays`,
  `memoryClusterKey`, `memoryCountryName`) plus the `MemoryGenerator` object,
  which exists only to carry a cancel flag a Swift `withTaskCancellationHandler`
  can reach. Two shape decisions worth keeping: photos cross **in** as
  `ScanPhoto` (Phase 3's record — one photo wire format, not two) and **out** as
  ids, because the app already holds the structs; and `search` takes no
  `allTags` argument because the index holds its own aggregated list — the Swift
  signature let a caller pass an empty one and silently degrade every tag query,
  including the virtual `Places/…` prefixes, to a substring match.
  **A Rust doc comment on an exported item must not contain `/` followed by `*`**
  (`People/` + `*`): UniFFI copies docs into Swift block comments, Swift nests
  them, and the generated file stops compiling at the last line.

Plus an in-workspace `uniffi-bindgen` bin so no global install is needed.
Toolchain pinned in `core/rust-toolchain.toml`.

`build/core/Generated/GalleryCore.swift` is compiled into the app target and
`GalleryCore.xcframework` linked (not embedded — static lib); both are
generated and git-ignored. The Swift/Rust parity contract is the shared
fixture `LocalGalleryTests/Support/Fixtures/stable_uuid_vectors.json`, read by
`StableUUIDVectorTests` and `core/gallery-model/tests/stable_uuid_vectors.rs`
and regenerated by `scripts/gen_stable_uuid_vectors.swift`.

Size baseline, Release arm64-simulator app binary:

| | bytes | Δ |
|---|---|---|
| no core | 7,102,960 | — |
| Phase 0 core | 7,559,456 | +446 KB |
| Phase 1 core (ONNX Runtime) | 38,981,728 | **+30.0 MB** |

The jump is ONNX Runtime: the merged `libgallery_core_merged.a` is 193 MB in
Release and the linker keeps ~30 MB of it. That is the price of the inference
backend, not of the FFI — `tract` remains the escape hatch behind
`gallery_ml::ImageEncoder` if the size ever matters more than the speed.

Pinned there and worth knowing before Phase 3: stable ids hash UTF-8 bytes, so
NFC and NFD spellings of a name derive **different** ids — while Swift's
`String ==` calls those same two strings **equal** (canonical equivalence).
Anything that dedupes by String will disagree with anything that dedupes by id.

### Store
- **Services/GalleryStore.swift** — `@Observable @MainActor` view-facing state. Owns `allPhotos`, `rootFolder`, `contacts`, the indexes, and wires the domain stores/services together. Views observe it via `@Environment(GalleryStore.self)`. All `allPhotos`/`rootFolder` mutations go through the `apply(_:)` choke point.
- **Services/GalleryStore+Scanning.swift** — the scan pipeline as a same-type extension: launch restore, scan-kind resolution/dedupe, the two-phase scan, enrichment, and the sidecar merge (see "Scanning" below).

### Domain stores (owned by GalleryStore, reached as `store.people` / `store.memories`)
- **PeopleStore** — hidden/featured/me person state, visible people lists, per-person cover photo + face-region matching, own UserDefaults persistence. Cross-domain side effects (memory regen, widget export) are Store-injected closures.
- **MemoryCoordinator** — the memories state machine: generated `[Memory]` + disk cache, the once-per-day gate (set only **after** a generation completes; epoch-invalidated by force-regen), seen/cool-down bookkeeping, hidden set, `visible` filtering, birthdays toggle. Engine inputs are snapshotted via the Store-provided `makeInputs` closure, so the whole type is testable without a Store (see `MemoryCoordinatorTests`).

### Services (`LocalGallery/Services/`)
- **AppRouter** — `@Observable @MainActor` cross-tab nav state (tab selection, per-tab paths, deep-link queue; queued memory links wait until `memories.hasGeneratedToday`).
- **AsyncSemaphore** — shared counting semaphore bounding parallel decodes (thumbnails 4), sidecar fetches (8), and enrichment reads (8).
- **BookmarkManager** — security-scoped bookmark + balanced start/stop access (`activeURL` is only recorded when the start call succeeds).
- **Clock** — `Clock` protocol + `SystemClock`; `FixedClock` lives in the app target under `#if DEBUG` (Clock.swift).
- **CloudStorageService** — stateless FileProvider probe/evict mechanics behind the Settings "Cloud Storage" section.
- **ContactLinker** — `personContactLinks` index + linkState/effectiveContact lookups.
- **ContactsService** — `ContactsServicing` protocol + `LiveContactsService` (the seam the Store injects; tests stub it) + a static `ContactsService` enum used by views for authorization checks.
- **CrashDiagnosticsService** — MetricKit `MXMetricManagerSubscriber` that persists the latest crash payload to disk for the in-app share flow.
- **EXIFService** — lazy EXIF + photo-tools XMP read for the info panel. Also the home of `exifDateFormatter` (`en_US_POSIX`, Gregorian, no `timeZone`) since `MetadataReader` moved into the core — device-locale parsing breaks on non-Gregorian calendars.
- **CoreScanner** — the app's side of the Rust scanner (Phase 3). Owns the core's `ScannerSession` and `CoreProviderProbe`, and bridges `ScanOutcomeRecord` ⇄ `PhotoFile`/`PhotoFolder`. Replaced `FolderScanner`; scan *policy* stayed in `GalleryStore+Scanning`. Two things to know: the core sends folders **flat** (parent index + a `(photoStart, photoCount)` slice of `flatPhotos`) so 20k photos cross once rather than twice, and `CoreScanner.fileURL(_:)` rebuilds URLs by percent-encoding rather than `URL(fileURLWithPath:)`, **which decomposes** — an NFC filename would otherwise land under a different `stableID` than the core derived.
- **CoreProviderProbe** — the one thing the core cannot do for itself: the `URLResourceKey` read that says whether a file is provider-backed, whether its bytes are here, and what its content identifier is. Called **per directory, in batches**, only for files a pass is about to rebuild. Three of those seven keys (`isUbiquitousItem*`) are a blocking XPC round trip to `fileproviderd` and the other four are a stat, so the probe **resolves once per scan whether the tree is ubiquitous at all** and reads only the cheap four when it is not — which took a cold 20k scan from 406 s to 2.3 s. Placeholder detection survives on `totalFileSize > fileSize`, the branch non-Apple providers always took. Do not "restore" the full key set for uniformity: `_plans/06` Finding 1 has the numbers, including the 16-way fan-out that made it *slower* (512 s) because the call serialises somewhere threads cannot reach.
- **CoreLibraryIndex** — the app's side of the Rust library index (Phase 4). Replaced `SearchIndex` + `TagIndex`. Every ordering and matching decision is the core's; what stays in Swift is the `photoByID` **object table** (the core answers in ids and the app holds the structs) and keeping the FFI off the main actor. `build(allPhotos:)` populates the id table synchronously — `photo(byID:)` is on the viewer's and the memory rail's critical path — and hands *everything else* to a detached task: marshalling the `ScanPhoto` records, the core call, and resolving the returned ids back to `PhotoFile`s. Only the finished arrays are assigned back. Three rules the rebuild path exists to keep: **core builds are serialised** (each awaits the previous — the generation counter orders the *publish*, but only the await orders the core's own index swap, and a stale build finishing last would leave the app rendering one library and querying another); the memos are cleared **at publish, not at start** (between the two, `photoByID` holds the new library while the core holds the old, so a query in that window caches an answer that resolves to nothing and survives the whole rebuild); and `hasEverPublished` (`store.hasSortedPhotos`) distinguishes "not sorted yet" from "no photos", which is what stops a cold launch flashing "No photos match." over a full library. `photos(forTag:)` and `search(query:requiredTags:)` are memoised **from one publish to the next**, because `PeopleListRow`, `PersonCard` and `TagGridView.photos` all ask from inside a `View` body and a boundary crossing per frame is exactly what `_plans/06`'s scroll findings forbid. `settle()` is test-only.
- **CoreMemories** — the app's side of the Rust memory engine (Phase 4). Replaced `MemoryEngine` + its four extension files. Marshals a `CoreMemories.Inputs` snapshot into the FFI record **inside** the detached task (it walks every photo twice and the caller is `@MainActor`), runs `generate` / `computeScheduled` there, and maps the results back to `Memory`. Three things it owns rather than forwards: cancellation (`Task.detached` swallows the caller's, so it is wired explicitly into the core's `MemoryGenerator`); the time zone, read from **`Calendar.current.timeZone`, not `TimeZone.current`** — the latter is cached and does not track an `NSTimeZone.default` override, so it answers GMT under the non-UTC conformance scenario and a stale zone on a device that crossed one — and it is sampled **per photo** (`secondsFromGMT(for: photo.dateTaken)`) as well as at `now`, because the core has no tz database and a single offset applied to all of history moves `density-*`/`trip-*` ids across a DST boundary twice a year; and `folderPlaceholderPhotos`, the cloud placeholders `MemoryCoordinator` filters out of the scored pool but which the **folder-event ladder alone** must still see (the deleted Swift read `folder.photos`, which that filter never touched). `countryName(from:)` is now the core's `en_US` table, not `Locale.current` (see the locale note under "Notes").
- **EnrichmentService** — parallel `TaskGroup` enrichment of stale photo metadata; caller cancellation is forwarded into the detached work. Non-downloaded placeholders skip the byteless read and are re-enriched when their bytes arrive (locality-transition triggers in the scanner and `ensureMaterialized`). The reads themselves are the core's (`readImageMetadata` / `readVideoDate`); this file owns only the scheduling. `EnrichmentService.resolve(_:)` turns the core's zone-less EXIF wall clock into a `Date` in the **device** zone — the explicit form of what `exifDateFormatter`'s missing `timeZone` did.
- **FaceService** — on-device faces (Phase 2). Owns the Rust core's `FaceSession` and mirrors `TaggingService` structurally (session held across runs, `cancelRequested` covering the window before a run exists, off-actor open/release, root-scoped runs, the shared `SidecarRefreshCoalescer`). Two things are its own: **availability is read from `TaggingService.pack.hasFaces`** through an injected `installedPack` closure, so a Settings appearance never SHA-256s the same ONNX twice, and it has calls that write to disk *without* being a run — `name` / `unname` / `ignore` / `rename` / `recluster`, all refused by the core while a run is in flight, hence `isRunning` gates the review buttons and not just the progress row. Eligibility calls straight through to `TaggingService.isEligible` (same bytes, same decoder, same sidecar). `allClusters` is refreshed after every run and every mutation; `reviewableClusters` is the unlabeled ones with ≥ `reviewMinimumFaces` (3), biggest first. Results reach the app the same way tagging's do: the light rescan → `SidecarSyncService` → `reapplySidecarMerges` → `PeopleStore`, which needs no new read path because the core writes the `People/*` keywords and `mwg-rs` regions it already parses.
- **FileProviderDetector** — probes URLs for file-provider non-local status + `fileContentIdentifierKey`-based content versions.
- **GalleryPaths** — single source of truth for every disk location + the bookmark key. Services take paths by injection with **no defaults**, so a missed injection fails loudly instead of writing production paths from tests. `mlCacheDatabaseURL` / `modelPacksDirectoryURL` (Application Support) belong to the Rust core — Swift only supplies the paths. `bundledModelPackURL` is the pack inside the app bundle (`Bundle.main.url(forResource: "pack",…)`, optional because a build can lack one); it is injected like the rest, so a test never SHA-256s the shipped 157 MB pack by accident.
- **PackResolver** — which model pack the app uses, as a pure function of two candidate lists (Phase 7). **Newest wins, wherever it lives**, ties to the imported copy: "imported always wins" would let one import shadow every future bundled pack, with nothing to tell the user why an app update changed nothing. `candidates(in:)` is the per-root enumerator (subdirectories carrying a `manifest.json`) and `resolve(bundled:imported:)` applies the version-aware `.numeric` comparator across the union — `.numeric` because plain lexicographic order ranks `-v1.9` above `-v1.10`. The comparison is on **directory names**, which is why `prepare_pack.sh` stages into `build/pack/<version>/` and the bundled *root* is what gets enumerated. Split out of `TaggingService` so the rule is testable without a 157 MB fixture (`PackResolverTests`).
- **JSONDiskCache** — generic versioned JSON-file store used by the library/memories/sidecar caches: ordered + optionally debounced writes, version probed before the payload decode, eviction on mismatch *and* corrupt files.
- **LibrarySnapshot** — the persisted scan result (`rootFolder` + `allPhotos` + an optional `sidecarManifest`) and its schema `version` history; `MemoriesCacheSchema` (independent version) lives alongside. **`sidecarManifest` was added to v20 without a version bump** (`_plans/06` Finding 2): a v20 file written before it existed decodes with `nil`, pays one legacy re-probe, then persists it. Bumping instead would have cost every installed library a full rescan to save one pass. `GalleryStore.loadCache()` seeds `lastSidecarManifest` from it *before* `restoreFolder` starts the launch scan — that ordering is the whole fix. The same file is read and written by the Rust core, so `SidecarCandidate` is `Codable` with `DownloadStatus` carrying `String` raw values and `ContentVersion.contentIdentifier` being a `String` (tolerant of the legacy `Int64` on decode).
- **LogPersistence** / **LogStore** / **LogRedactor** — opt-in ring-buffer log capture feeding `LogsView` and the crash-share payload. `Log.r.*` tokenizes identifying strings; **use `Log.r.error(_:)` instead of `error.localizedDescription`** in log interpolation (Cocoa errors embed file names).
- **MemoryRefreshService** — indirection between the BG-task handler in AppDelegate and the Store.
- **PhotoExporter** — re-encodes a photo to JPEG at a chosen quality for share-sheet export.
- **PhotoMaterializer** — kicks off + tracks file-provider downloads; coalesces by photo id with token-checked cleanup; gates *prefetch* on `NWPathMonitor.isExpensive` when "Use Cellular Data" is off.
- **SidecarCacheStore** / **SidecarSyncService** / **SidecarRefreshService** — parsed `.xmp` cache + bulk provider fetches + BG refresh. Fetched bytes are parsed by the core (`parseXmpBytes`), the same parser the scan and enrichment paths use.
- **SidecarRefreshCoalescer** — shared by `TaggingService` and `FaceService`: turns a burst of "the core wrote sidecars" callbacks into at most one rescan per `refreshInterval` (30s), and **drains rather than drops** a request that arrives during an in-flight rescan — that walk may have listed the tree before the sidecars existed, so dropping it loses the results until something else happens to scan. `lastRefreshAt` marks when a refresh actually *ran*, so a steady drip of suppressed batches cannot keep pushing the window out.
- **SlideshowMusic** — `AVAudioEngine`-based ambient pad synthesis for the six slideshow music themes.
- **TaggingService** — on-device tagging (Phase 1). Owns the Rust core's `TaggingSession`, finds/verifies the installed model pack, feeds it the eligible photos, and publishes `isAvailable`/`isRunning`/`progress`/`lastSummary`. Eligibility is *not* the enrichment rule restated: both exclude non-downloaded placeholders (no bytes), but enrichment reads videos' dates while tagging refuses them (no frame sampler in the core). A run is scoped to the current library root (`rootPrefix`) because the core's cache DB is one file per app keyed by absolute path and outlives any one root. **Results come back through the existing sidecar pipeline, not a new read path**: a run writes `.xmp` files the last scan never saw, so the service triggers a **light rescan** (coalesced, `refreshInterval` 30s + one at the end) → fresh sidecar manifest → `SidecarSyncService` → `reapplySidecarMerges` → tags/indexes/widget. Coalescing *defers*, never drops: a refresh requested while one is in flight is drained after it, since that walk may predate the sidecars. The pack it runs is `PackResolver`'s answer over the bundled root and `ModelPacks/` (Phase 7), so a clean install tags with no import step; `PackStatus.source` carries which of the two won, `removeImportedPack()` deletes the active import and re-resolves onto the bundled one, and an import no longer decides that it is active — it is verified at its destination and then resolution decides. Pack verification is cached on the manifest's size+mtime (Settings' `.task` fires on every appearance and a full verify SHA-256s the whole ONNX); the core re-verifies at session open regardless. Progress callbacks arrive on core worker threads and hop to the main actor through a `Sendable` bridge holding only `@Sendable` closures.
- **SlideshowVideoRenderer** — renders a memory's photo list as a crossfading MP4 (1080×1080, H.264).
- **ThumbnailService** — in-memory + on-disk thumbnail and full-resolution caches (see invalidation matrix below).
- **VideoExportShield** — iOS 26+ `BGContinuedProcessingTask` wrapper that keeps the slideshow MP4 export alive (with system progress UI) when the app is backgrounded mid-render; the render still runs in `CollectionsView.startRender`, the shield only tracks/expires it. No-op when the system declines or pre-26. Registered in AppDelegate; identifier listed in `BGTaskSchedulerPermittedIdentifiers`.
- **WidgetExportScheduler** — 200ms-debounced task calling `WidgetSnapshotExporter.shared.export`.
- **WidgetSnapshotExporter** — writes photo/folder/memory snapshots + thumbnails to the App Group container.

### Models (`LocalGallery/Models/`)
- **PhotoFile** — the core photo value type; metadata, tags, GPS, locality, sidecar status, SHA-256-derived stable UUID. Codable is hand-written: adding a field means touching `CodingKeys`, the memberwise init, **and** `init(from:)`, and usually bumping `LibrarySnapshot.version`.
- **PhotoFolder** — folder node with subfolders, photos, and a stable UUID.
- **Memory** / **MemoryType** — a generated memory and its classification. Equality/hash are **id-only**.
- **HierarchicalTag** / **TagNamespace** — structured tag value type + SF Symbol helpers for the six photo-tools taxonomy roots.
- **TagSuggestion** — flattened tag with photo count, used by the search index and tag picker.
- **EXIFData**, **PhotoToolsMetadata**, **PersonLink** (+`FailableDecodable` tolerant-decode wrapper), **FaceRegion**, **FolderSortOrder**, **ContactInfo**.

### Views (`LocalGallery/Views/`)
One type per file. Notable groupings:
- **Viewer/** — `PhotoViewerView` (chrome + filmstrip), `PagingPhotoView` (UIPageViewController wrapper), `PhotoPageView` (one page incl. video/live/materialize states), `ZoomableImageView`, `SwipeToDismissGesture`.
- **Collections/** — `PersonCard`, `PersonContextMenu` (shared Me/Feature/Link/Hide menu), `MemoryCardView`, `MemoryGridView`, `TagGridView`, `PeopleListView`, and the Phase 2 face review: `PeopleReviewRow` (the People-screen doorway, shown only when `faces.reviewableClusters` is non-empty) → `PeopleReviewView` (cluster grid) → `ClusterReviewView` (every face, a name field with contact/library suggestions, and "Not a Person"). Crops are `PersonThumbnailView` with the region the core returned — no new crop path, because `FaceRef` is already MWG-shaped. Merge/split are deliberately absent: proposals are computed but applying one is not implemented.
- **PhotoChrome.swift** — pill formatting helpers + the shared `ChromePill` and `ViewerDismissButton` used by viewer and slideshow, plus the Liquid Glass adapters (`chromeGlass(in:legacyOpacity:)`, `ChromeGlassGroup`): glass on iOS 26+, the legacy translucent white fills earlier.
- **PhotoInfoPanel.swift**, **AllPhotosView**, **FolderBrowserView**, **CollectionsView**, **PhotoGridScreen** (grid + search + selection; still the largest view), **SettingsView** (Photo Library · Cloud Storage · Sidecars · People · **On-device Tagging** — model-pack status, its *source* ("Bundled" / "Imported"), "Import Model Pack…" folder picker, "Remove Imported Pack" (confirmed; shown only for an imported pack, falls back to the bundled one), "Tag Library Now" with progress/cancel, "Reset Tagging Data" (destructive, confirmed; clears the queue, keeps sidecars and cached embeddings), last-run summary, plus a **faces sub-block** ("Scan Faces" with its own progress/cancel and last-run line) that is present only when the installed pack ships face models — rows rather than a section of its own, because faces come from the *same* pack. The two run buttons disable each other: the engines hold separate SQLite connections to one WAL cache file, and serialising in the UI beats teaching both to retry `SQLITE_BUSY` · Stats · Diagnostics · About), **MemorySlideshowView**, **PeopleContactLinking**, **LogsView**, **EXIFFormatters** (incl. `photoCountLabel`).

### Components (`LocalGallery/Components/`)
`ThumbnailView` (task keyed on URL **and** cell size), `PersonThumbnailView`, `FolderGridView`, `GridLayoutConfig`, `PhotoShareKit`, `RemoteBadge`, `ScanProgressBanner` (owns the shared `ScanProgress.countText`), `SettingsToolbarButton`, `LibraryEmptyState`, `ShareSheet` / `AVPlayerLayerView`. Folder picking goes through SwiftUI `.fileImporter` (Settings); logs/redaction-key exports through `ShareLink` — `ShareSheet.present` remains only for the multi-file crash-report share.

### Other
- **LocalGalleryApp.swift** — app entry, AppDelegate (BG-task registration + orientation lock), root WindowGroup, `ContentView`.
- **Design.swift** — design tokens (`enum Design`; light-only palette) and the gated-modifier helpers `View.softTopScrollEdge()` / `View.minimizableTabBar()`.
- **Logging.swift** — `TeeLogger` wrapper that mirrors every `os.Logger` call into `LogStore` for the in-app LogsView. Everything is logged `privacy: .public`, so redaction relies on call sites using `Log.r.*`. Per-category `minLevel` gates both sinks (a gated `.debug` is invisible even in Console.app).
- **Shared/** — `SharedContainer`, `WidgetSnapshot`, `WidgetDeepLink`, `WidgetRotation`, `SeededRNG`; compiled into both the host app and the widget extension.

## Scanning

The most intricate behavior in the app (`GalleryStore+Scanning.swift`). The
*walk* moved into the Rust core in Phase 3 (`gallery-scan`, reached through
`CoreScanner`); everything below is policy and stayed in Swift:

- **Kinds**: `.light` (pull-to-refresh; reuses cached `PhotoFile`s for unchanged files — one stat per file, no provider probe, no EXIF), `.full` (Settings "Reload Library"; probes + rebuilds everything), `.auto` (foreground/cold-launch; light, promoted to full when >48h since the last full pass — `fullScanInterval`).
- **Two-phase**: a requested full scan with a warm cache runs a quick light pre-pass first so new files surface in seconds, then the full pass follows.
- **Dedupe**: concurrent scans of the same URL await the in-flight task, but a request is only *satisfied* by a pass that could answer it — not by a weaker one (a `.full` request re-runs behind an in-flight light scan) and not by an **earlier** one (a pass that began before the request may have walked the tree before the request's files existed; this is what dropped a tagging run's sidecars). The re-run carries the original request timestamp, so it costs one extra pass, not a storm. Scans of different roots serialize.
- **Light-scan blind spot**: in-place file modifications are invisible until the 48h full-scan backstop (light scan trusts cached size/modDate without statting).
- **After the final pass**: sidecar sync plan → `memories.generateIfNeeded()` → widget snapshot export.
- **The provider probe is the whole cost.** A 7-key `resourceValues` per file is a ~11 ms blocking XPC round trip; serially over 20k photos + 17k sidecars that was 99.4% of a cold scan. Two things fixed it: the core asks **per directory, in batches, and only for files it is about to rebuild** (a light scan over an unchanged library asks for *none*), and `CoreProviderProbe` drops the three expensive keys on a non-iCloud tree. Anything that makes the light path probe again, or that widens the key set unconditionally, re-opens `_plans/06` Finding 1.

## Memories

`gallery_memories::generate` (reached through `CoreMemories.generate`) is pure;
`MemoryCoordinator` owns the gating. Score
ladder (before 0–12 daily jitter, −30 seen-within-6-months, −25
cluster-cooldown-3-days): birthdays 100 · onThisDay 50+5/yr · yearsAgo 35–45 ·
trips 20+1.5/day · subtrips 15+1.2/day · folder events 10+span · density 8.
Top 10 selected greedily with cluster uniqueness (a trip parent and its
sub-trips share a cluster). Every memory passes `finalize` (75-photo cap with
cover re-pointing + standardized subtitle) — including the widget's
pre-published scheduled days, so ids and content match when the day arrives.
Calendar ids are date-qualified (`onThisDay-2024-06-11`) so viewing one day's
memory doesn't seen-penalize every future day.

## Cache invalidation matrix

| Cache | Invalidated by |
|---|---|
| Library (`LibrarySnapshot.version`, JSONDiskCache) | version bump or corrupt file → evicted; eviction also clears the **memories** disk cache (stale photo IDs) |
| Memories (`MemoriesCacheSchema.version`) | own version bump, library eviction, force-regenerate |
| Sidecars (`SidecarCacheStore.version`) | own version bump, "Re-download all sidecars", per-entry content-version diff, GC of orphans after scan |
| Thumbnails (disk) | source mtime newer than cache entry; QuickLook (placeholder) entries trusted while placeholder; "Clear thumbnail cache" |
| `.nothumb` sentinels | only honoured on the QuickLook path, expire after 24h, dropped once the file is local |

## Widget pipeline

`GalleryStore.exportWidgetSnapshot()` (after scan / tag aggregation / memory
regen / hide-unhide) → `WidgetExportScheduler` (200ms debounce) →
`WidgetSnapshotExporter` actor (writes JSON + thumbnails to the App Group; GC
of stale thumbs) → widget `TimelineProvider`s read via `WidgetSnapshotReader`
→ taps deep-link via `WidgetDeepLink` → `AppRouter` (queues ids until the
backing data exists). Calendar-tied memories for the next 7 days are
pre-published with validity windows (`computeScheduledMemories`); foreground
catch-up regenerates the same ids on the matching day.

## Notes

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`, iOS 18 target.
- `GalleryStore` is `@Observable @MainActor` (no `@unchecked Sendable`). Services are `@MainActor final class` (state-holding) or stateless `enum` namespaces. Heavy work runs off-actor: prefer `nonisolated` async funcs (they run on the global executor **and preserve cancellation**); where `Task.detached` is needed for priority, forward cancellation with `withTaskCancellationHandler` (see `CoreMemories.generate`, `EnrichmentService.enrich`).
- A `DefaultsBacked` property wrapper was considered for the hand-rolled `didSet { defaults.set(...) }` persistence pattern and rejected: the `@Observable` macro doesn't support property wrappers on observed properties. The didSet pattern is the @Observable-compatible way.
- **Locale, after Phase 4.** Memory subtitles (`"Jun 11, 2019 · 12 photos"`) and country names in trip titles / the photo-info pill used to come from ICU through `DateFormatter.setLocalizedDateFormatFromTemplate` and `Locale.current.localizedString(forRegionCode:)`, so they followed the device language. They now come from the core's own `en_US` tables. This is a **user-visible behaviour change, accepted deliberately**: a memory's title and subtitle are part of its identity in the conformance fixtures, and the alternatives were bundling ICU in the core (megabytes, for one string per country) or moving subtitle composition into the UI layer (which would unpin the fixtures). Revisit by moving composition to the view, not by adding a locale to the core.
- Stable photo/folder IDs derived from the file URL via SHA-256 (prefix-16 bytes, RFC 4122 variant + version-5 marker; namespace-less; matches localmusic) — grid doesn't flicker on rescan.
- The BG-task handler in `AppDelegate.handleBackgroundRefresh` calls into `MemoryRefreshService` (held on the AppDelegate); the WindowGroup attaches the live Store via a `.task` modifier. Expiration handlers cancel the work and the cancellation actually propagates.
- Tests: `LocalGalleryTests/Unit` + `Support` (fixtures, `TempDir`, `TestUserDefaults`, `TestGalleryStore`). The memory engine/coordinator suites pass an explicit UTC calendar or noon-UTC fixtures for timezone robustness. `TaggingSessionTests`/`FaceSessionTests` drive the real FFI against the *same* committed test packs `cargo test` uses (`core/gallery-ml/tests/{testpack,facepack,fixtures}`, folder references in `project.yml`), so a simulator-vs-host drift fails rather than being fixed up in one copy — that is also why the packs are referenced in place and never duplicated into the test target.
- iOS 26 APIs are adopted behind `if #available(iOS 26.0, *)` while the target stays 18: Liquid Glass chrome (PhotoChrome adapters), `tabBarMinimizeBehavior`, `scrollEdgeEffectStyle`, and the `BGContinuedProcessingTask` export shield. The UIKit nav/tab appearance overrides in `configureAppearance` are deliberately **not** gated — re-theming the system bars for glass is a separate design decision.

## Known follow-ups (deliberately not done yet)

- `PhotoGridScreen` is still ~900 lines; extracting the filter pipeline into an `@Observable` model would make it testable.
- `SwipeToDismissGestureInstaller` could become a `UIGestureRecognizerRepresentable` (iOS 18) — needs on-device gesture testing.
- Collections navigation mixes typed `CollectionsRoute` pushes with closure-based `NavigationLink`s; unifying on typed routes would let deep links reach every screen.
- `clearAllDownloads` enumerates file-provider domains once per photo; the domain list could be fetched once per run (needs care: `NSFileProviderDomain` isn't Sendable).
- Face **merge and split** are unimplemented: `merge_proposals` are computed and stored, but `merge(a, b)` / `split(id, faces)` do not exist in the core and nothing surfaces them in the UI.
- Renaming an already-named person is core-side only (`FaceSession.renamePerson` / `FaceService.rename`); no UI reaches it yet, and the existing person screens still key off the `People/*` tag.
- The face review screen shows *unlabeled* clusters only. There is no per-person "recent auto-adds" list, which the Phase 2 plan wants as the safety valve on auto-tagging.
- Reading face clusters costs a full `FaceSession` open (both ONNX models), because that is the only route to the cluster table — so opening the People tab with a face-capable pack loads weights the user may never scan with. Off the main actor and once per launch, and skipped entirely for a tagging-only pack, but a cache-only FFI entry point would remove it.

## External

- **photo-tools XMP schema** — companion tagger at [j23n/photo-tools](https://github.com/j23n/photo-tools). Canonical field/namespace/taxonomy definitions: [docs/xmp-schema.md](https://github.com/j23n/photo-tools/blob/main/docs/xmp-schema.md). Tag data this app reads (`digiKam:TagsList`, `photo-tools:CountryCode`, etc.) is defined there.
