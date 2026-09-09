# LocalGallery

A folder-backed photo and video gallery for iOS and Linux. You pick a
directory of files; the apps browse it in place. Nothing is imported
into a private library.

Pair it with [Syncthing](https://syncthing.net/) (via
[SyncTrain](https://apps.apple.com/app/synctrain/id6475591584) on iOS)
to sync the folder across devices.

## Why

Photo libraries should not require a specific app or service. The
folder is the gallery: you own the files and choose where they live.

## Features

- **Folder browsing** — cover thumbnails, sorting, nested folders
- **Collections** — tags (people, places, objects, scenes) from XMP
- **All Photos** — date-sorted grid with search
- **Memories** — once-a-day stories, slideshow, MP4 export (iOS)
- **People** — face regions from MWG XMP; optional address-book link (iOS)
- **Home-screen widgets** — photo, folder, tag, memories (iOS)
- **Video and Live Photos** — inline playback (iOS)
- **HEIC** — read like other stills. Analysis decode is ImageIO on iOS
  and software HEVC (`heif-oxide`) on Linux and `cargo test`
- **Cloud folders** — iOS File Provider: on-demand download, sidecar
  cache for evicted `.xmp`
- **EXIF panel** — camera, lens, exposure, GPS, size
- **Hierarchical tags** — `digiKam:TagsList`-style paths; see the
  [photo-tools schema](https://github.com/j23n/photo-tools/blob/main/docs/xmp-schema.md)
- **On-device tagging and faces** — optional model pack (ONNX)
- **Places from GPS** — Nominatim reverse geocode; **coordinates leave
  the device**
- **Explicit file mutations** — Scan Photos writes `.xmp` sidecars;
  you can move, delete, or create items in the folder
- **Opt-in crash export** — MetricKit + redacted logs, never uploaded
  automatically (iOS)

## What the apps write

They are not read-only. Sidecar writes and file move/delete/create
are described in [docs/storage.md](docs/storage.md). Image bytes are
not rewritten by the core.

Places is the only product network egress: Nominatim (injectable
endpoint). There is no LocalGallery account or telemetry backend.

## Requirements

- **iOS app:** a current Xcode that can run an iOS 18+ simulator
  (project file declares Xcode 16.0 / iOS 18.0). [XcodeGen](https://github.com/yonaskolb/XcodeGen).
  [rustup](https://rustup.rs). Python 3 only if you build a model pack.
- **Linux app:** GTK4, libadwaita 1.5+, Rust — [linux/INSTALL.md](linux/INSTALL.md).

## Build (iOS)

```bash
brew install xcodegen          # CI pins 2.46.0; see scripts/install_xcodegen.sh
./scripts/build_core.sh        # UniFFI Swift + GalleryCore.xcframework
# Optional: stage a model pack (tagging/faces). Without one, those
# features stay off. xcodegen still needs the build/pack directory:
mkdir -p build/pack
./scripts/prepare_pack.sh      # when build/model_packs/<version> exists
xcodegen
open LocalGallery.xcodeproj
```

`xcodegen` lists `build/core/Generated/GalleryCore.swift`; it does not
run UniFFI. If that file is stale, Xcode reports missing `HeicDecoder`
and similar. `./scripts/build_core.sh` regenerates it. The LocalGallery
target's **Build Rust Core** phase runs the same script; pass
`--release` only when you invoke it from the CLI.

The first `build_core.sh` on a machine downloads a static ONNX Runtime
(~85 MB) into `~/Library/Caches/ort.pyke.io/`. Offline:
`ORT_LIB_LOCATION` pointing at a directory that contains
`libonnxruntime.a`.

Device / Archive builds need a signing team in Xcode (or
`DEVELOPMENT_TEAM` in `project.yml`).

### Model pack

On-device tagging and face grouping use a pack (ONNX encoder, label
embeddings, optional face models, ~157 MB). **It is not committed and
is not required.** `scripts/build_model_pack/` builds one;
`scripts/prepare_pack.sh` stages the newest build into
`build/pack/<version>/`.

A tagging-only pack is valid: Scan Photos tags objects/scenes and
names places; it skips faces. Use that variant for any build you
distribute — the default full pack's face models are insightface
`buffalo_sc` (research / non-commercial):

```bash
PACK_VARIANT=tagging ./scripts/prepare_pack.sh
```

### Third-party licences

The app is MPL-2.0. Linked decode/inference crates are permissive
(ONNX Runtime MIT; `heif-oxide` + `rust_h265` MIT OR Apache-2.0).
HEIC does not use libheif/libde265 (LGPL-3.0). The decode seam is
`gallery_ml::preprocess::ImageDecoder`.

## Tests

```bash
# Any available iPhone simulator (iOS 18+). Helper: scripts/pick_ios_simulator.sh
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=$(./scripts/pick_ios_simulator.sh)" \
  -testLanguage en -testRegion US

cd core && cargo test --workspace
```

Locale flags are required: memories fixtures assert `en_US`.

Tests live in `LocalGalleryTests/Unit` with fixtures in
`LocalGalleryTests/Support` and `core/fixtures/`. Architecture:
[docs/architecture.md](docs/architecture.md).

## CI

Pull requests and tags **validate** the tree (generate, compile, test).
They do not publish an IPA. See [docs/release.md](docs/release.md) and
[ADR 0003](docs/adr/0003-validation-only-release.md).

The committed taxonomy path list and `taxonomy_paths_sha256` are required
checks. Live source-provenance against
[j23n/photo-tools](https://github.com/j23n/photo-tools) is a **manual
gate**: that repository is currently private or returns 404, so CI warns
and continues rather than staying red. A git commit is recorded only when
a mapping at that commit reproduces the pinned hash. Do not invent one.

## Setup

On first launch, pick (or create) a folder of photos. Syncthing and
iCloud Drive folders are fine. Scan Photos is opt-in and writes
sidecars. Places uploads GPS to Nominatim.

## Linux

[linux/README.md](linux/README.md) · [linux/INSTALL.md](linux/INSTALL.md)

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## AI disclaimer

[docs/AI_DISCLAIMER.md](docs/AI_DISCLAIMER.md)

## License

[MPL-2.0](LICENSE)
