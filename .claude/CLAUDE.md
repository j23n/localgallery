# LocalGallery

SwiftUI iOS photo gallery app that browses user-selected folders without importing into a library. Targets iOS 17+.

## Build

Uses XcodeGen. Run `xcodegen` to generate `LocalGallery.xcodeproj`, then build in Xcode or via:

```
xcodebuild build -project LocalGallery.xcodeproj -scheme LocalGallery -destination "generic/platform=iOS"
```

## Structure

All source is in `LocalGallery/`. Key files:

- **GalleryManager.swift** — `@MainActor ObservableObject` singleton: folder scanning, metadata enrichment, thumbnail generation (memory + disk cache), search index, tag aggregation, memories
- **Models.swift** — `PhotoFile`, `PhotoFolder`, `Memory`, `HierarchicalTag`, `TagSuggestion`, `EXIFData`
- **AllPhotosView.swift** — Date-sectioned photo grid with search, tag filtering, year scrubber
- **FolderBrowserView.swift** — Hierarchical folder navigation
- **CollectionsView.swift** — People, events, memories (uses pre-computed indexes from GalleryManager)
- **PhotoViewerView.swift** — Full-screen viewer with UIPageViewController paging, pinch-zoom, live photo support
- **ThumbnailView.swift** — Async thumbnail loading with shimmer placeholder
- **GridLayoutConfig.swift** — Shared grid layout config (3 size tiers)
- **Logging.swift** — `os.Logger` instances by category

## Notes

- `os.Logger` interpolations use `@escaping @autoclosure` — always use `self.` for property references
- `GalleryManager` is `@unchecked Sendable`; heavy work runs in `Task.detached` or `nonisolated static` methods
- Stable photo/folder IDs derived from file URL via MD5 (CryptoKit) — grid doesn't flicker on rescan
- Project uses Swift 5 language mode (`SWIFT_STRICT_CONCURRENCY: minimal`)
