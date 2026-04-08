# LocalGallery

A read-only photo and video viewer for iOS. Point it at a folder of images and browse them — no importing, no library lock-in, no cloud required.

## Why

Photo libraries shouldn't require a specific app or service to access. LocalGallery treats a plain folder of image files as your gallery. You own the files, you choose where they live, and nothing is copied or modified.

Pair it with [Syncthing](https://syncthing.net/) (via [SyncTrain](https://apps.apple.com/app/synctrain/id6475591584) on iOS) to sync your photos across devices without any cloud service.

## Features

- **Folder browsing** — navigate your photo folders with cover thumbnails and sorting options
- **Collections** — auto-grouped views by hierarchical tags (people, places, objects, etc.)
- **All Photos** — flat grid of every photo, sorted by capture date, with search
- **Video and Live Photos** — inline playback for videos and Live Photo motion
- **EXIF metadata** — camera, lens, exposure, GPS, and dimensions in a slide-up panel
- **Hierarchical tags** — reads XMP/IPTC keywords with namespace support (e.g. `Country|Japan`, `People|Name`)
- **Metadata search** — search across filenames, keywords, and tags
- **Disk cache** — thumbnails are cached to disk for fast repeat browsing
- **Background scanning** — folder contents are scanned in the background with persisted state
- **No account required** — no sign-up, no server, no tracking

## Requirements

- Xcode 16.0+
- iOS 17.0+
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

Then build and run on a simulator or device (iOS 17+).

## Setup

On first launch, the app asks you to select (or create) a folder containing your photos. This can be any folder accessible to the app — including one synced by Syncthing or iCloud Drive.

The app is read-only: it never modifies, moves, or deletes your files.

## License

[MPL 2.0](LICENSE)
