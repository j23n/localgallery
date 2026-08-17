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
- **HEIC** — iPhone's default photo format is read like any other: embedded XMP tags, on-device tagging, and face detection, decoded on a pure-Rust HEVC path rather than the platform decoder so two devices agree on the result
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
- [rustup](https://rustup.rs) — the tagging/faces/scanning core is Rust
- Python 3 — only to build the on-device model pack, once

## Build

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Stage the model pack into build/pack, which the app bundles
./scripts/prepare_pack.sh

# Build the Rust core (must run before xcodegen, and again after any change
# under core/). Needs network access the first time — see below.
./scripts/build_core.sh

# Generate the Xcode project
xcodegen

# Open in Xcode
open LocalGallery.xcodeproj
```

Then build and run on a simulator (iOS 18+).

### Model pack

On-device tagging and face grouping run against a *model pack* — an ONNX image
encoder, the precomputed label embeddings, and optionally two face models. The
pack is ~157 MB, so it is not committed; `scripts/build_model_pack/` builds it
and `scripts/prepare_pack.sh` stages the newest build into
`build/pack/<version>`, which the app bundles. Run `prepare_pack.sh` with no
pack built and it prints the exact command that builds one.

The app ships the staged pack, so a fresh install can tag and scan faces with
no setup. Settings → Import Model Pack… still installs a newer pack over it;
whichever pack has the higher version wins.

**Licence:** the face models in the default (full) pack are insightface's
`buffalo_sc` — SCRFD-500M and w600k_mbf — which are **research /
non-commercial licensed**. That is fine for a personal build; anything
distributed must either ship the tagging-only pack

```bash
PACK_VARIANT=tagging ./scripts/prepare_pack.sh
```

or substitute face models whose licence permits it. A tagging-only pack is a
valid pack: the app simply hides the face-scanning controls.

The first `build_core.sh` on a machine downloads a prebuilt static ONNX Runtime
(~85 MB) into `~/Library/Caches/ort.pyke.io/`; offline builds work with
`ORT_LIB_LOCATION` pointing at a directory containing `libonnxruntime.a`.
Nothing else in the core needs a toolchain beyond `cargo` — image decoding,
HEIC included, is pure Rust.

### Third-party licences

The app is MPL 2.0. Its dependencies are permissive and statically linked:
ONNX Runtime (MIT), and for HEIC, `heif-oxide` + `rust_h265` (MIT OR
Apache-2.0). No copyleft library is linked in — HEIC decoding deliberately
does **not** use libheif/libde265, which are LGPL-3.0 and whose static linking
obliges a distributor to let a user relink against a modified library. Swapping
the decoder back to them would re-introduce that obligation; the seam that
would make such a swap possible is `gallery_ml::preprocess::ImageDecoder`.

## Tests

The `LocalGallery` scheme includes the unit-test target:

```bash
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -testLanguage en -testRegion US
```

The locale flags are required: the memories conformance fixtures record the
simulator's locale and assert `en_US`, so a Mac in another region fails two of
them for no reason.

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
