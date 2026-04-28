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
- **Services/GalleryStore.swift** — `@Observable @MainActor` view-facing state. Owns `allPhotos`, `rootFolder`, `memories`, `contacts`, the People/Memory toggles, and orchestrates the services below. Forwards calls into them; views observe its properties via `@Environment(GalleryStore.self)`.

### Services (`LocalGallery/Services/`)
- **AppRouter** — `@Observable @MainActor` cross-tab nav state (tab selection, per-tab paths, deep-link queue).
- **BookmarkManager** — security-scoped bookmark + balanced start/stop access.
- **ContactLinker** — `personContactLinks` index + linkState/effectiveContact lookups.
- **ContactsService** — static wrapper around `CNContactStore`; returns `[ContactInfo]` snapshots for memory generation.
- **EXIFService** — lazy EXIF + photo-tools XMP read for the EXIF panel.
- **EnrichmentService** — parallel `TaskGroup` enrichment of stale photo metadata.
- **FolderScanner** — iterative folder traversal returning a `(rootFolder, flatPhotos, needsEnrichment)` tuple.
- **LibraryCacheStore** / **MemoriesCacheStore** — JSON-on-disk caches for the scan result and the generated memories.
- **MemoryEngine** — once-a-day memory generation (on this day, years ago, trips, birthdays, etc.).
- **MemoryRefreshService** — indirection between the BG-task handler in AppDelegate and the Store.
- **MetadataReader** — pure stateless EXIF / XMP / video-date readers used by the scanner + enricher.
- **SearchIndex** + **TagIndex** — sorted photo list, search corpus, tag → photos index, async tag aggregator.
- **SlideshowMusic** — `AVAudioEngine`-based ambient pad synthesis for the six slideshow music themes.
- **SlideshowVideoRenderer** — renders a memory's photo list as a crossfading MP4 file (1080×1080, H.264).
- **ThumbnailService** — in-memory + on-disk thumbnail and full-resolution caches.
- **WidgetExportScheduler** — debounced detached task that calls `WidgetSnapshotExporter.shared.export`.
- **WidgetSnapshotExporter** — writes photo/folder/memory snapshots + thumbnails to the App Group container for widget extensions.

### Models (`LocalGallery/Models/`)
- **PhotoFile** — the core photo value type; carries metadata, tags, GPS, and a SHA-256-derived stable UUID.
- **PhotoFolder** — folder node with subfolders, photos, and a SHA-256-derived stable UUID.
- **Memory** / **MemoryType** — a generated memory (on this day, trip, birthday, etc.) and its classification enum.
- **HierarchicalTag** / **TagNamespace** — structured tag value type + SF Symbol helpers for the six photo-tools taxonomy roots.
- **TagSuggestion** — flattened tag with photo count, used by the search index and tag picker.
- **EXIFData** — camera/lens/GPS fields from image metadata.
- **PhotoToolsMetadata** — fields from the `photo-tools` custom XMP namespace (tagger version, country code, CLIP info).
- **PersonLink** — typed enum for how a `People/<name>` tag is linked to an address-book contact.
- **FolderSortOrder** — sort options surfaced in the folder browser.
- **ContactInfo** — lightweight `CNContact` snapshot (name + birthday) used for birthday memory generation.

### Views (`LocalGallery/Views/`)
- **AllPhotosView / FolderBrowserView / CollectionsView / PhotoViewerView / PhotoGridScreen / SettingsView / EXIFPanelView / MemorySlideshowView / PeopleContactLinking** — SwiftUI views, all `@Environment(GalleryStore.self) private var store`.

### Components (`LocalGallery/Components/`)
- **ThumbnailView** — async thumbnail cell with progress placeholder.
- **FolderGridView** — reusable grid of photos for a folder or tag filter.
- **GridLayoutConfig** — shared grid layout config (4 size tiers, portrait/landscape column tables).
- **DocumentPicker** / **ShareSheet** / **VideoPlayerView** — UIKit wrapper components.

### Other
- **LocalGalleryApp.swift** — app entry, AppDelegate (BG-task registration + orientation lock), root WindowGroup, `ContentView`.
- **Design.swift** — design tokens (`enum Design`) and `View.softTopScrollEdge()` progressive-enhancement helper.
- **Logging.swift** — `os.Logger` instances by category.
- **Shared/** — `SharedContainer`, `WidgetSnapshot`, `WidgetDeepLink`, `WidgetRotation`; compiled into both the host app and the widget extension target.

## Notes

- Project uses Swift 6 language mode with `SWIFT_STRICT_CONCURRENCY: complete` and an iOS 18 deployment target.
- `os.Logger` interpolations use `@escaping @autoclosure` — always use `self.` for property references inside Logger calls.
- `GalleryStore` is `@Observable @MainActor` (no `@unchecked Sendable`). Services are either `@MainActor final class` (state-holding) or stateless `enum` namespaces. Heavy work runs in `Task.detached` (called from inside services) so the main actor stays responsive.
- Stable photo/folder IDs derived from the file URL via SHA-256 (prefix-16 bytes, RFC 4122 variant + version-5 marker; namespace-less; matches localmusic) — grid doesn't flicker on rescan.
- The BG-task handler in `AppDelegate.handleBackgroundRefresh` calls into `MemoryRefreshService` (held on the AppDelegate) rather than reaching for a global Store singleton. The WindowGroup attaches the live Store to the service via a `.task` modifier.

## External

- **photo-tools XMP schema** — companion tagger at [j23n/photo-tools](https://github.com/j23n/photo-tools). Canonical field/namespace/taxonomy definitions: [docs/xmp-schema.md](https://github.com/j23n/photo-tools/blob/main/docs/xmp-schema.md). Tag data this app reads (`digiKam:TagsList`, `photo-tools:CountryCode`, etc.) is defined there.
