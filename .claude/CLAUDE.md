# LocalGallery

SwiftUI iOS photo gallery app that browses user-selected folders without importing into a library. Targets iOS 18+.

## Build & test

Uses XcodeGen. Run `xcodegen` to generate `LocalGallery.xcodeproj`, then build in Xcode or via:

```
xcodebuild build -project LocalGallery.xcodeproj -scheme LocalGallery -destination "generic/platform=iOS"
xcodebuild test  -project LocalGallery.xcodeproj -scheme LocalGallery -destination "platform=iOS Simulator,name=iPhone 16"
```

## Structure

Source under `LocalGallery/`. A view-facing Store, two domain stores it
exposes (`store.people`, `store.memories`), and focused services under
`Services/`.

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
- **EXIFService** — lazy EXIF + photo-tools XMP read for the info panel.
- **EnrichmentService** — parallel `TaskGroup` enrichment of stale photo metadata; caller cancellation is forwarded into the detached work. Non-downloaded placeholders skip the byteless read and are re-enriched when their bytes arrive (locality-transition triggers in the scanner and `ensureMaterialized`).
- **FileProviderDetector** — probes URLs for file-provider non-local status + `fileContentIdentifierKey`-based content versions.
- **FolderScanner** — iterative folder traversal returning `(rootFolder, flatPhotos, needsEnrichment, sidecarManifest, added/removed/modified URLs, failedDirectoryPaths)`. Directories whose listing throws are excluded from removal accounting — the Store carries their cached photos forward so a transient I/O error can't wipe a subtree.
- **GalleryPaths** — single source of truth for every disk location + the bookmark key. Services take paths by injection with **no defaults**, so a missed injection fails loudly instead of writing production paths from tests.
- **JSONDiskCache** — generic versioned JSON-file store used by the library/memories/sidecar caches: ordered + optionally debounced writes, version probed before the payload decode, eviction on mismatch *and* corrupt files.
- **LibrarySnapshot** — the persisted scan result (`rootFolder` + `allPhotos`) and its schema `version` history; `MemoriesCacheSchema` (independent version) lives alongside.
- **LogPersistence** / **LogStore** / **LogRedactor** — opt-in ring-buffer log capture feeding `LogsView` and the crash-share payload. `Log.r.*` tokenizes identifying strings; **use `Log.r.error(_:)` instead of `error.localizedDescription`** in log interpolation (Cocoa errors embed file names).
- **MemoryEngine** (+`Calendar` / `+Birthdays` / `+Trips` / `+Selection` extension files) — pure once-a-day memory generation; see "Memories" below.
- **MemoryRefreshService** — indirection between the BG-task handler in AppDelegate and the Store.
- **MetadataReader** — pure stateless EXIF / XMP / video-date readers used by the scanner + enricher. `exifDateFormatter` is the shared `en_US_POSIX` parser (device-locale parsing breaks on non-Gregorian calendars). Per-field sidecar-vs-embedded precedence is documented at the merge site in `readImageMetadata`.
- **PhotoExporter** — re-encodes a photo to JPEG at a chosen quality for share-sheet export.
- **PhotoMaterializer** — kicks off + tracks file-provider downloads; coalesces by photo id with token-checked cleanup; gates *prefetch* on `NWPathMonitor.isExpensive` when "Use Cellular Data" is off.
- **SearchIndex** + **TagIndex** — sorted photo list (date desc, URL-path tiebreak so rescans don't shuffle), search corpus, tag → photos index, async tag aggregator.
- **SidecarCacheStore** / **SidecarSyncService** / **SidecarRefreshService** — parsed `.xmp` cache + bulk provider fetches + BG refresh.
- **SlideshowMusic** — `AVAudioEngine`-based ambient pad synthesis for the six slideshow music themes.
- **SlideshowVideoRenderer** — renders a memory's photo list as a crossfading MP4 (1080×1080, H.264).
- **ThumbnailService** — in-memory + on-disk thumbnail and full-resolution caches (see invalidation matrix below).
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
- **Collections/** — `PersonCard`, `PersonContextMenu` (shared Me/Feature/Link/Hide menu), `MemoryCardView`, `MemoryGridView`, `TagGridView`, `PeopleListView`.
- **PhotoChrome.swift** — pill formatting helpers + the shared `ChromePill` and `ViewerDismissButton` used by viewer and slideshow.
- **PhotoInfoPanel.swift**, **AllPhotosView**, **FolderBrowserView**, **CollectionsView**, **PhotoGridScreen** (grid + search + selection; still the largest view), **SettingsView**, **MemorySlideshowView**, **PeopleContactLinking**, **LogsView**, **EXIFFormatters** (incl. `photoCountLabel`).

### Components (`LocalGallery/Components/`)
`ThumbnailView` (task keyed on URL **and** cell size), `PersonThumbnailView`, `FolderGridView`, `GridLayoutConfig`, `PhotoShareKit`, `RemoteBadge`, `ScanProgressBanner` (owns the shared `ScanProgress.countText`), `SettingsToolbarButton`, `LibraryEmptyState`, `DocumentPicker` / `ShareSheet` / `AVPlayerLayerView`.

### Other
- **LocalGalleryApp.swift** — app entry, AppDelegate (BG-task registration + orientation lock), root WindowGroup, `ContentView`.
- **Design.swift** — design tokens (`enum Design`; light-only palette) and `View.softTopScrollEdge()`.
- **Logging.swift** — `TeeLogger` wrapper that mirrors every `os.Logger` call into `LogStore` for the in-app LogsView. Everything is logged `privacy: .public`, so redaction relies on call sites using `Log.r.*`. Per-category `minLevel` gates both sinks (a gated `.debug` is invisible even in Console.app).
- **Shared/** — `SharedContainer`, `WidgetSnapshot`, `WidgetDeepLink`, `WidgetRotation`, `SeededRNG`; compiled into both the host app and the widget extension.

## Scanning

The most intricate behavior in the app (`GalleryStore+Scanning.swift`):

- **Kinds**: `.light` (pull-to-refresh; reuses cached `PhotoFile`s for unchanged files — one stat per file, no provider probe, no EXIF), `.full` (Settings "Reload Library"; probes + rebuilds everything), `.auto` (foreground/cold-launch; light, promoted to full when >48h since the last full pass — `fullScanInterval`).
- **Two-phase**: a requested full scan with a warm cache runs a quick light pre-pass first so new files surface in seconds, then the full pass follows.
- **Dedupe**: concurrent scans of the same URL await the in-flight task; a `.full` request is **not** satisfied by an in-flight light scan (it re-runs after); scans of different roots serialize.
- **Light-scan blind spot**: in-place file modifications are invisible until the 48h full-scan backstop (light scan trusts cached size/modDate without statting).
- **After the final pass**: sidecar sync plan → `memories.generateIfNeeded()` → widget snapshot export.

## Memories

`MemoryEngine.generate` is pure; `MemoryCoordinator` owns the gating. Score
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
- `GalleryStore` is `@Observable @MainActor` (no `@unchecked Sendable`). Services are `@MainActor final class` (state-holding) or stateless `enum` namespaces. Heavy work runs off-actor: prefer `nonisolated` async funcs (they run on the global executor **and preserve cancellation**); where `Task.detached` is needed for priority, forward cancellation with `withTaskCancellationHandler` (see `MemoryEngine.generate`, `EnrichmentService.enrich`).
- A `DefaultsBacked` property wrapper was considered for the hand-rolled `didSet { defaults.set(...) }` persistence pattern and rejected: the `@Observable` macro doesn't support property wrappers on observed properties. The didSet pattern is the @Observable-compatible way.
- Stable photo/folder IDs derived from the file URL via SHA-256 (prefix-16 bytes, RFC 4122 variant + version-5 marker; namespace-less; matches localmusic) — grid doesn't flicker on rescan.
- The BG-task handler in `AppDelegate.handleBackgroundRefresh` calls into `MemoryRefreshService` (held on the AppDelegate); the WindowGroup attaches the live Store via a `.task` modifier. Expiration handlers cancel the work and the cancellation actually propagates.
- Tests: `LocalGalleryTests/Unit` + `Support` (fixtures, `TempDir`, `TestUserDefaults`, `TestGalleryStore`). The memory engine/coordinator suites pass an explicit UTC calendar or noon-UTC fixtures for timezone robustness.

## Known follow-ups (deliberately not done yet)

- `PhotoGridScreen` is still ~900 lines; extracting the filter pipeline into an `@Observable` model would make it testable.
- `SwipeToDismissGestureInstaller` could become a `UIGestureRecognizerRepresentable` (iOS 18) — needs on-device gesture testing.
- Collections navigation mixes typed `CollectionsRoute` pushes with closure-based `NavigationLink`s; unifying on typed routes would let deep links reach every screen.
- `TagIndex` stores full `PhotoFile` copies per bucket; switching to `[String: [UUID]]` + `photoByID` would shrink it.
- `clearAllDownloads` enumerates file-provider domains once per photo; the domain list could be fetched once per run (needs care: `NSFileProviderDomain` isn't Sendable).

## External

- **photo-tools XMP schema** — companion tagger at [j23n/photo-tools](https://github.com/j23n/photo-tools). Canonical field/namespace/taxonomy definitions: [docs/xmp-schema.md](https://github.com/j23n/photo-tools/blob/main/docs/xmp-schema.md). Tag data this app reads (`digiKam:TagsList`, `photo-tools:CountryCode`, etc.) is defined there.
