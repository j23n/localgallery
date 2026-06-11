# LocalGallery

A read-only photo and video viewer for iOS. Point it at a folder of images and browse them — no importing, no library lock-in, no cloud required.

## Why

Photo libraries shouldn't require a specific app or service to access. LocalGallery treats a plain folder of image files as your gallery. You own the files, you choose where they live, and nothing is copied or modified.

Pair it with [Syncthing](https://syncthing.net/) (via [SyncTrain](https://apps.apple.com/app/synctrain/id6475591584) on iOS) to sync your photos across devices without any cloud service.

## Features

- **Folder browsing** — navigate your photo folders with cover thumbnails and sorting options
- **Collections** — auto-grouped views by hierarchical tags (people, places, objects, etc.)
- **All Photos** — flat grid of every photo, sorted by capture date, with search
- **Memories** — once-a-day generated stories (on this day, years ago, trips, birthdays) with a music-backed slideshow and MP4 export
- **People** — face-cropped person rail from MWG XMP regions, with optional address-book linking for birthday memories
- **Home-screen widgets** — rotating photo, folder, tag, and memories widgets with deep links
- **Video and Live Photos** — inline playback for videos and Live Photo motion
- **Cloud folders** — file-provider folders (iCloud Drive, etc.) work via on-demand download, with `.xmp` sidecar caching for evicted files
- **EXIF metadata** — camera, lens, exposure, GPS, and dimensions in a slide-up panel
- **Hierarchical tags** — reads `digiKam:TagsList`-style XMP keywords with slash-separated paths (e.g. `Places/Japan/Tokyo`, `People/Anna`); see the [photo-tools schema](https://github.com/j23n/photo-tools/blob/main/docs/xmp-schema.md)
- **Metadata search** — search across filenames, keywords, and tags
- **Disk cache** — thumbnails and scan results are cached for fast repeat launches
- **Background refresh** — daily memories and sidecar syncs run as background tasks
- **Opt-in crash reporting** — MetricKit crash payloads + redacted logs, shared manually, never sent automatically
- **No account required** — no sign-up, no server, no tracking

## Requirements

- Xcode 16.0+
- iOS 18.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Generate the Xcode project
xcodegen

# Open in Xcode
open LocalGallery.xcodeproj
```

Then build and run on a simulator or device (iOS 18+).

## Tests

The `LocalGallery` scheme includes the unit-test target:

```bash
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 16"
```

Tests live in `LocalGalleryTests/Unit` with shared fixtures in
`LocalGalleryTests/Support`. For an architecture overview (scan pipeline,
memory generation, cache invalidation, widget pipeline), see
[.claude/CLAUDE.md](.claude/CLAUDE.md).

## Setup

On first launch, the app asks you to select (or create) a folder containing your photos. This can be any folder accessible to the app — including one synced by Syncthing or iCloud Drive.

The app is read-only: it never modifies, moves, or deletes your files.

## AI disclaimer

Please see [docs/AI_DISCLAIMER.md](docs/AI_DISCLAIMER.md).

## License

[MPL 2.0](LICENSE)
