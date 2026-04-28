# LocalGallery

SwiftUI iOS photo gallery app that browses user-selected folders without importing into a library. Targets iOS 18+.

## Build

Uses XcodeGen. Run `xcodegen` to generate `LocalGallery.xcodeproj`, then build in Xcode or via:

```
xcodebuild build -project LocalGallery.xcodeproj -scheme LocalGallery -destination "generic/platform=iOS"
```

## Structure

Source under `LocalGallery/`. The view-facing Store + a set of focused
services under `Services/`.

### Store
- **GalleryStore.swift** — `@Observable @MainActor` view-facing state. Owns `allPhotos`, `rootFolder`, `memories`, `contacts`, the People/Memory toggles, and orchestrates the services below. Forwards calls into them; views observe its properties via `@Environment(GalleryStore.self)`.

### Services (`LocalGallery/Services/`)
- **BookmarkManager** — security-scoped bookmark + balanced start/stop access.
- **ContactLinker** — `personContactLinks` index + linkState/effectiveContact lookups.
- **EXIFService** — lazy EXIF + photo-tools XMP read for the EXIF panel.
- **EnrichmentService** — parallel `TaskGroup` enrichment of stale photo metadata.
- **FolderScanner** — iterative folder traversal returning a `(rootFolder, flatPhotos, needsEnrichment)` tuple.
- **LibraryCacheStore** / **MemoriesCacheStore** — JSON-on-disk caches for the scan result and the generated memories.
- **MemoryEngine** — once-a-day memory generation (on this day, years ago, trips, birthdays, etc.).
- **MemoryRefreshService** — indirection between the BG-task handler in AppDelegate and the Store.
- **MetadataReader** — pure stateless EXIF / XMP / video-date readers used by the scanner + enricher.
- **SearchIndex** + **TagIndex** — sorted photo list, search corpus, tag → photos index, async tag aggregator.
- **ThumbnailService** — in-memory + on-disk thumbnail and full-resolution caches.
- **WidgetExportScheduler** — debounced detached task that calls `WidgetSnapshotExporter.shared.export`.

### Other
- **Models.swift** — `PhotoFile`, `PhotoFolder`, `Memory`, `HierarchicalTag`, `TagSuggestion`, `EXIFData`, `PhotoToolsMetadata`, `PersonLink`.
- **AllPhotosView / FolderBrowserView / CollectionsView / PhotoViewerView / PhotoGridScreen / SettingsView / EXIFPanelView / MemorySlideshowView / ThumbnailView** — SwiftUI views, all `@Environment(GalleryStore.self) private var manager`.
- **AppRouter.swift** — `@Observable @MainActor` cross-tab nav state (tab selection, per-tab paths, deep-link queue).
- **LocalGalleryApp.swift** — app entry, AppDelegate (BG-task registration + orientation lock), root WindowGroup.
- **GridLayoutConfig.swift** — shared grid layout config (4 size tiers, portrait/landscape column tables).
- **Logging.swift** — `os.Logger` instances by category.

## Notes

- Project uses Swift 6 language mode with `SWIFT_STRICT_CONCURRENCY: complete` and an iOS 18 deployment target.
- `os.Logger` interpolations use `@escaping @autoclosure` — always use `self.` for property references inside Logger calls.
- `GalleryStore` is `@Observable @MainActor` (no `@unchecked Sendable`). Services are either `@MainActor final class` (state-holding) or stateless `enum` namespaces. Heavy work runs in `Task.detached` (called from inside services) so the main actor stays responsive.
- Stable photo/folder IDs derived from file URL via MD5 (CryptoKit) — grid doesn't flicker on rescan.
- The BG-task handler in `AppDelegate.handleBackgroundRefresh` calls into `MemoryRefreshService` (held on the AppDelegate) rather than reaching for a global Store singleton. The WindowGroup attaches the live Store to the service via a `.task` modifier.

## External

- **photo-tools XMP schema** — companion tagger at [j23n/photo-tools](https://github.com/j23n/photo-tools). Canonical field/namespace/taxonomy definitions: [docs/xmp-schema.md](https://github.com/j23n/photo-tools/blob/main/docs/xmp-schema.md). Tag data this app reads (`digiKam:TagsList`, `photo-tools:CountryCode`, etc.) is defined there.
