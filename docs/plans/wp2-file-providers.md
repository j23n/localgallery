# WP2 — File-provider support (iCloud / OneDrive / Proton / Drive / Dropbox)

Goal: photos in folders backed by an iOS File Provider work in LocalGallery
even when the underlying files are not yet downloaded to the device. Sidecars
are bulk-fetched eagerly with user consent; full-resolution photos materialise
on demand when the user opens them; nothing is auto-evicted.

File paths and line numbers reflect the branch state at plan authoring; expect
drift after each pass.

---

## Design summary

- **Detection is per-file, not per-folder.** New code paths fire only when
  scanning encounters items reported as non-local; purely local libraries hit
  no new behaviour.
- **Sidecars are first-class.** Parsed XMP is cached in our own JSON-on-disk
  store keyed by photo UUID, so search/tags survive provider-side eviction of
  the source `.xmp`. Full files do not need to be downloaded for tag/people
  search to work.
- **Stale detection** uses `URLResourceKey.fileContentIdentifierKey` where the
  provider populates it, falling back to `(contentModificationDate, fileSize)`.
  `NSFileProviderItemVersion` is the provider-canonical identifier but is not
  publicly readable from host apps; `fileContentIdentifierKey` is the closest
  host-readable analogue.
- **Thumbnails for non-downloaded photos** come from
  `QLThumbnailGenerator.generateBestRepresentation`, which transparently uses
  provider-vended thumbnails. Once a thumbnail is in our on-disk cache it
  survives provider eviction.
- **Materialisation** for full-resolution viewing goes through a new
  `PhotoMaterializer` service. Spinner UI in the viewer; auto-fetch on detail
  open; never auto-evict.
- **Memory generation only considers photos with cached sidecars.**
- **A new Settings → Cloud Storage section** shows the materialised-photo count
  and exposes an explicit "Clear all downloads" action.

Throttle: sidecar fetch runs at concurrency 8.
Prompt threshold: prompt the user when sidecar fetch would touch ≥ 5,000
sidecars *or* ≥ 50 MB total. Below that, fetch silently.

---

## Pass 1 — Detection primitives & model fields

Foundational, no user-visible behaviour change.

### 1.1 `FileProviderDetector` service

New file: `LocalGallery/Services/FileProviderDetector.swift` — stateless
`enum` namespace.

```swift
enum DownloadStatus { case local, placeholder, downloading, stale }

enum FileProviderDetector {
    static func downloadStatus(of url: URL) -> DownloadStatus
    static func contentVersion(of url: URL) -> ContentVersion
    static func isFileProviderURL(_ url: URL) -> Bool
}

struct ContentVersion: Hashable, Codable {
    var contentIdentifier: Data?         // URLResourceKey.fileContentIdentifierKey
    var modificationDate: Date?
    var size: Int64?
}
```

Implementation notes:
- One batched `URLResourceValues` read per file:
  `[.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    .fileResourceIdentifierKey, .fileContentIdentifierKey,
    .contentModificationDateKey, .fileSizeKey]`.
- `ContentVersion` equality is `contentIdentifier ?? (mtime, size)`. Compare in
  that order so providers that populate `fileContentIdentifierKey` are
  authoritative.
- `isFileProviderURL`: cache `NSFileProviderManager.getDomainsWithCompletionHandler`
  results for the session, plus `URLResourceValues.isUbiquitousItem` for iCloud.
- All calls are metadata-only; none triggers a download.

### 1.2 Model extensions

Add to `LocalGallery/Models/PhotoFile.swift`:

```swift
enum PhotoLocality: Codable, Hashable {
    case local
    case remote(downloaded: Bool)
}

enum SidecarStatus: Codable, Hashable {
    case absent
    case cached(ContentVersion)
    case pendingFetch
    case fetchFailed(reason: String)
}

extension PhotoFile {
    var locality: PhotoLocality          // default .local; not in stable UUID
    var sidecarStatus: SidecarStatus     // default .absent
}
```

Stable UUID derivation does **not** change — these fields are runtime/cache
state, not identity. Existing on-disk caches remain valid; defaulted fields
populate to `.local` / `.absent` for back-compat.

### 1.3 Verification step (write a small one-shot tool, then delete it)

Before Pass 3, write a one-off SwiftUI debug screen that picks a folder and
prints `(url, downloadStatus, contentVersion)` for each file. Test against:
- A purely local folder
- An iCloud Drive folder with a mix of downloaded + placeholder files
- A Proton Drive folder

This pins down whether `ubiquitousItemDownloadingStatusKey` returns useful
values for third-party providers; if not, the fallback heuristic
`(fileSize == 0 && fileResourceType == .regular)` becomes the primary signal.
Encode whichever is reliable into `FileProviderDetector.downloadStatus`.

---

## Pass 2 — Scanner integration

`LocalGallery/Services/FolderScanner.swift`:

- During the iterative walk, batch-read the resource keys via
  `FileProviderDetector` for each photo and each `.xmp` candidate.
- Populate `PhotoFile.locality` from the result.
- Stop swallowing directory-listing errors with `try?` for remote folders —
  log and report them via the existing diagnostics channel so the user sees
  why a folder is empty.
- Extend the return tuple:
  `(rootFolder, flatPhotos, needsEnrichment, sidecarManifest)` where
  `sidecarManifest: [SidecarCandidate]` carries
  `(photoID, sidecarURL, currentVersion: ContentVersion)` for every photo
  that has a `.xmp` adjacent to it. Photos without sidecars are not in the
  manifest; their `sidecarStatus` stays `.absent`.

`GalleryStore` consumes the new manifest and forwards it to
`SidecarSyncService` (Pass 4).

No user-visible change yet.

---

## Pass 3 — Thumbnails for non-downloaded photos

First user-visible win: cloud photos appear in the grid.

### 3.1 `ThumbnailService` dual path

`LocalGallery/Services/ThumbnailService.swift`:
- For photos with `locality == .remote(downloaded: false)`, replace the
  `CGImageSourceCreateWithURL` call with
  `QLThumbnailGenerator.shared.generateBestRepresentation(for:)`.
- Use representation type `.thumbnail` at the existing tile sizes. Cache the
  result in the existing in-memory + disk cache.
- If QL returns nothing (provider doesn't vend thumbs), persist a sentinel
  "no-thumb" marker so we don't retry on every grid scroll, and return nil to
  the caller.
- Once a thumbnail is cached on disk it is reused regardless of subsequent
  download status; the on-disk cache outlives provider-side eviction of the
  source photo.

### 3.2 Cloud badge

New component: `LocalGallery/Components/RemoteBadge.swift` — small SF Symbol
overlay (`icloud` or `arrow.down.circle`).

`ThumbnailView.swift`: render the badge in the top-right corner when
`photo.locality == .remote(downloaded: false)`.

### 3.3 Sentinel handling

If `ThumbnailService` returned the "no-thumb" sentinel for a remote photo,
`ThumbnailView` falls back to a placeholder tile with the `photo` SF Symbol +
cloud badge instead of an indefinite spinner. Without this the grid would
stall on providers that don't vend thumbnails.

---

## Pass 4 — Detail-view auto-download

Makes the viewer functional for cloud photos.

### 4.1 `PhotoMaterializer` service

New file: `LocalGallery/Services/PhotoMaterializer.swift` —
`@Observable @MainActor final class`.

```swift
@MainActor @Observable
final class PhotoMaterializer {
    private(set) var inFlight: [PhotoFile.ID: Progress]

    func ensureMaterialized(_ photo: PhotoFile) async throws -> URL
    func cancel(_ photoID: PhotoFile.ID)
}
```

Behaviour:
- Fast path: photo is local → return `photo.url` immediately.
- Slow path:
  1. `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)` to get the
     provider domain + identifier.
  2. `NSFileProviderManager.fetchContents(for:version:request:completionHandler:)`
     when available; otherwise wrap a `NSFileCoordinator.coordinate(readingItemAt:)`
     to trigger materialisation by access.
  3. Surface progress via the inFlight map for the spinner.
- Coalesce by `PhotoFile.ID` so swipe-back-to-same-photo doesn't dispatch
  duplicate requests.
- After download succeeds, call `EnrichmentService.enrich(_:)` for that single
  photo to backfill EXIF/GPS/date fields onto the in-memory model.
- Update `PhotoFile.locality` to `.remote(downloaded: true)`.

### 4.2 Viewer flow

`LocalGallery/Views/PhotoViewerView.swift`:
1. On photo change, call `await materializer.ensureMaterialized(photo)`.
2. While in-flight, show a centered spinner with "Downloading…" label and
   percent if `Progress.fractionCompleted` is meaningful.
3. On success, render the image as today.
4. On failure, show an inline error with a retry button.
5. The EXIF panel reads from the now-enriched `PhotoFile` — no special
   handling needed there.

### 4.3 Adjacent-photo prefetch

In `PhotoMaterializer`, expose `prefetch(_ photos: [PhotoFile])` that fires
materialisation for `[N-1, N+1]` when the user lands on photo N, gated on a
`SettingsStore.prefetchAdjacentRemotePhotos` flag (default on).

Add a follow-on flag `useCellularForDownloads` (default off). When off, gate
prefetch on `NWPathMonitor` reporting Wi-Fi / wired only. The user's explicit
tap-to-view always proceeds regardless of this flag — only background prefetch
respects it.

---

## Pass 5 — Sidecar sync pipeline

Search and tag features start working for cloud libraries.

### 5.1 `SidecarSyncService`

New file: `LocalGallery/Services/SidecarSyncService.swift` —
`@Observable @MainActor final class`.

Responsibilities:
1. Receives the `sidecarManifest` from `FolderScanner`.
2. Diffs against `SidecarCacheStore`. Buckets each candidate as:
   - `upToDate` — cached `ContentVersion` matches current.
   - `needsFetch` — version differs.
   - `newlyDiscovered` — no cache entry yet.
   - `sidecarRemoved` — cached but no longer in manifest (orphan; GC).
3. Computes `(count: Int, estimatedBytes: Int64)` for the fetch pile using
   sizes from the manifest's URLResourceKey reads (no downloads required).
4. If `count >= 5_000 || estimatedBytes >= 50_000_000`, surfaces a
   `SyncPrompt` banner to the UI:

   > "We found 32,418 sidecar files (~312 MB) for this folder.
   > Download them now? [Download] [Skip] [Always for this folder]"

   Below threshold, fetch silently.
5. On confirmation, runs a `TaskGroup`-throttled fetch loop with
   concurrency 8. Each task:
   - `NSFileProviderManager.fetchContents(for:request:)` on the sidecar's
     identifier; on providers without that API, fall back to
     `NSFileCoordinator.coordinate(readingItemAt:)`.
   - Reads bytes, parses via the existing XMP parser path (`MetadataReader`'s
     XMP routines, factored out of `readImageMetadata`).
   - Persists to `SidecarCacheStore` keyed by the photo's stable UUID.
   - Updates `PhotoFile.sidecarStatus` to `.cached(currentVersion)`.
6. Reports progress via `@Observable` properties consumed by a top-of-grid
   banner: "Downloading sidecars 1,200 / 32,418 — Cancel".
7. Cancellation is honoured immediately; partial progress is preserved.
8. Failed items are recorded as `.fetchFailed(reason:)`; retry on next scan
   or on user-triggered "Retry failed" button.

### 5.2 `SidecarCacheStore`

New file: `LocalGallery/Services/SidecarCacheStore.swift` — JSON-on-disk store
mirroring `LibraryCacheStore`.

```swift
struct CachedSidecar: Codable {
    var version: ContentVersion
    var parsed: PhotoToolsMetadata
    var tags: [HierarchicalTag]
    var gps: GPS?
    var dateTaken: Date?
}

@MainActor final class SidecarCacheStore {
    func get(_ photoID: PhotoFile.ID) -> CachedSidecar?
    func put(_ photoID: PhotoFile.ID, _ entry: CachedSidecar)
    func remove(_ photoID: PhotoFile.ID)
    func gc(keeping: Set<PhotoFile.ID>)
}
```

Persisted at `Application Support/LocalGallery/sidecar-cache.json` (or
chunked file-per-folder if memory pressure warrants — start with single file).

### 5.3 Plug into enrichment

`GalleryStore.scan()`:
1. Run scanner.
2. Hand `sidecarManifest` to `SidecarSyncService`.
3. Have `EnrichmentService` consult `SidecarCacheStore` first when populating
   tags/GPS/date for remote photos — it already has a metadata-merge step.
4. For remote photos that lack a sidecar entry, leave them in
   `sidecarStatus == .absent`. They appear in the grid but are excluded from
   tag-search results.

### 5.4 Sort order during the unenriched gap

`SearchIndex` already sorts by date; for photos lacking EXIF and lacking a
sidecar, fall back to `URLResourceKey.contentModificationDateKey` from the
filesystem at scan time. When the photo is later materialised or its sidecar
arrives, re-index it via the existing incremental update path.

---

## Pass 6 — Memories & slideshow

### 6.1 `MemoryEngine` filter

`LocalGallery/Services/MemoryEngine.swift`: filter the candidate pool to
`photo.sidecarStatus matches .cached(_)` before generation. Add a debug log
line when the filtered set is significantly smaller than the total — useful
for users investigating sparse memories on a freshly-added cloud library.

### 6.2 `SlideshowVideoRenderer` pre-flight

`LocalGallery/Services/SlideshowVideoRenderer.swift`: before opening the
first asset, gather URLs for all photos in the memory and call
`PhotoMaterializer.ensureMaterialized` for non-local ones in parallel.
Surface progress in the export sheet ("Preparing photos 12 / 50…"). Without
this the renderer would silently fail on placeholder reads.

### 6.3 `WidgetSnapshotExporter`

`LocalGallery/Services/WidgetSnapshotExporter.swift`: filter the snapshot
input to photos with `locality == .local || .remote(downloaded: true)`.
Widgets must not depend on placeholders that may not be readable from the
extension process.

---

## Pass 7 — Settings & storage controls

`LocalGallery/Views/SettingsView.swift`: new section, only visible when at
least one folder is detected as file-provider.

```
Cloud Storage
─────────────
Materialized photos        1,234 (5.2 GB)   >
Clear all downloads                          >
Pre-fetch adjacent in viewer                ⏻
Use cellular for downloads                  ⏻

Sidecars
─────────────
Auto-download sidecars (per folder)          >
Re-download all sidecars                     >
```

- **Materialized photos** count: lazily computed on view appearance by
  iterating `flatPhotos`, reading
  `URLResourceKey.ubiquitousItemDownloadingStatusKey` (cheap, metadata-only).
  Cached for 30s to avoid jank on repeat opens.
- **Clear all downloads**: confirmation alert →
  `NSFileProviderManager.evictItem(identifier:)` for each materialised photo.
  Progress shown inline. Sidecar cache + thumbnail cache untouched, so the
  grid stays usable; only full-resolution viewing requires re-download.
- **Per-folder auto-download sidecars**: backed by `SettingsStore` keyed on
  bookmark-derived folder UUID; honoured by `SidecarSyncService` to skip the
  prompt.
- **Re-download all sidecars**: nuclear option that wipes `SidecarCacheStore`
  and re-runs sync.

---

## Pass 8 — Background sidecar refresh

The existing BGTask infrastructure (`AppDelegate` → `MemoryRefreshService`)
gets a sibling task for sidecar sync.

### 8.1 New BGTask identifier

`Info.plist` (`UIBackgroundModes` + `BGTaskSchedulerPermittedIdentifiers`):
add `com.localgallery.sidecar-refresh`.

### 8.2 Wire-up

- `AppDelegate.application(_:didFinishLaunchingWithOptions:)` registers the
  identifier alongside the memory-refresh task.
- New `SidecarRefreshService` (mirrors `MemoryRefreshService`) holds a weak
  reference to the live `GalleryStore` injected via `.task` from the root
  WindowGroup.
- The handler:
  1. Re-runs scan (metadata-only — cheap).
  2. Diffs sidecar manifest against `SidecarCacheStore`.
  3. Honours per-folder "auto-download" preference; if not set, skips
     (background must not surface UI prompts).
  4. Fetches up to a soft cap (e.g. 200 sidecars per BG window) at
     concurrency 4 (lower than foreground to be polite under iOS BG limits).
  5. Schedules the next task via `BGTaskScheduler` with a target interval of
     12h, mirroring memory refresh.
- Foreground sync remains responsible for first-time bulk downloads with the
  prompt. Background sync is incremental top-up only.

### 8.3 Cancellation & expiration

The handler installs a `BGTask.expirationHandler` that cancels the in-flight
`TaskGroup`. Partial progress is durable — `SidecarCacheStore` writes are
atomic per-entry.

---

## Pass 9 — Edge cases & policy

Bake these into the implementation; they are not "nice to haves":

- **First scan of a 50k cloud library**: scanner finishes in seconds (metadata
  only). Sidecar prompt appears with accurate counts. User confirms; banner
  shows progress; user can browse during the fetch — thumbnails come from
  QuickLook, search is partial but functional.
- **No network**: sidecar fetch fails per-item with a recorded reason. Retry
  on next launch; no alert noise in the foreground.
- **Sidecar deleted on the cloud side**: scanner drops it from the manifest;
  `SidecarSyncService.gc` removes it from `SidecarCacheStore`. Photo loses
  tag-search visibility next index pass.
- **Photo deleted, sidecar remains**: scanner won't list the photo; the
  cached sidecar is orphaned and GC'd at end of scan.
- **Photo and sidecar both modified between scans**: detected via
  `ContentVersion` change; re-fetched.
- **Mixed local + remote folder**: per-file detection handles this with no
  code branches.
- **Folder pick returns a non-folder URL** (some providers do this for
  Google Drive single files): existing `DocumentPicker` already filters to
  `.folder`; verify the picker rejects bad picks gracefully.
- **`ubiquitousItemDownloadingStatusKey` returns nil for a third-party
  provider**: covered by the Pass 1 verification step; the detector falls
  back to the size+filetype heuristic.

---

## Pass 10 — Testing matrix

Verify against, at minimum:

- **iCloud Drive**: download status, sidecar fetch, materialisation on viewer
  open, eviction via "Clear downloads", BG sidecar refresh.
- **Proton Drive**: full matrix; verify QL thumbnail vending, sidecar fetch,
  and `fileContentIdentifierKey` behaviour.
- **OneDrive** *(stretch)*: sanity pass.
- **Local folder**: zero behavioural change. No prompts, no extra metadata
  reads in the hot path beyond a `locality == .local` early-out.
- **Mixed library**: a folder containing both downloaded and placeholder
  photos.
- **Airplane mode**: graceful fallback; viewer shows error with retry; grid
  remains usable; failed items recorded.
- **Big-library prompt**: 32k+ sidecars; progress reporting and cancellation
  both work; cancelling mid-fetch leaves partially-cached entries durable.

---

## Order of execution

1. Pass 1 — primitives + model fields. No user-visible change. Mergeable.
2. Pass 2 — scanner integration. Still no UX change. Mergeable.
3. Pass 3 — QL thumbnails. **First user-visible win.** Mergeable.
4. Pass 4 — viewer auto-download. Cloud libraries become usable end-to-end
   for browsing.
5. Pass 5 — sidecar pipeline. Search/tags start working for cloud libraries.
6. Pass 6 — memories + slideshow + widget filters.
7. Pass 7 — settings.
8. Pass 8 — background refresh.
9. Pass 9 + 10 — edge-case hardening + test pass on real providers.

Each pass is intended to land as its own commit/PR; the app stays shippable
between passes.

---

## Open implementation questions

- **Sidecar cache file shape**: single JSON vs chunked per-folder vs SQLite.
  Start with single JSON to match `LibraryCacheStore`. Revisit if file size
  exceeds ~50 MB or load times become noticeable.
- **`fetchContents` vs `coordinate(readingItemAt:)`**: prefer the explicit
  FileProvider API where available; the coordinator path is the universal
  fallback. Confirm during Pass 4 implementation.
- **Throttle tuning**: concurrency 8 for foreground sidecar fetch may be
  aggressive for some providers (Proton has been observed to rate-limit).
  Surface a debug toggle to drop to 4 if telemetry shows failures.
- **EXIF range-read optimisation** (out of scope for this plan): in theory
  `NSFileProviderReplicatedExtension.fetchPartialContents` could let us read
  just the first ~64 KB of a JPEG to extract EXIF without full materialisation.
  Defer until after the sidecar path is in production — for libraries with
  good sidecar coverage it's redundant.
