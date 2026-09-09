# Contributing

LocalGallery is a folder-backed photo app: iOS (SwiftUI + UniFFI) and
Linux (GTK4 / libadwaita) share the Rust core under `core/`.

## Current-state docs

Write about what the tree does now. Standing decisions live in
[docs/adr/](docs/adr/). Do not add `_plans/`, `docs/plans/`, or other
roadmap files to this repo. See [ADR 0005](docs/adr/0005-current-state-docs.md).

## License

Contributions are [MPL-2.0](LICENSE). Keep Cargo `license` fields and
AppStream `project_license` on `MPL-2.0`. Do not add LGPL image
decoders to the shipping binary
([ADR 0004](docs/adr/0004-mpl-licensing.md)).

## Build and test

iOS (Apple Silicon Mac, Xcode that provides an iPhone simulator):

```bash
./scripts/build_core.sh
./scripts/prepare_pack.sh          # optional; needs a built pack
xcodegen
# Any available iPhone simulator (iOS 18+). Helper: scripts/pick_ios_simulator.sh
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=$(./scripts/pick_ios_simulator.sh)" \
  -testLanguage en -testRegion US
```

`xcodegen` needs `build/core/GalleryCore.xcframework` and the
`build/pack` folder path from `project.yml`. The Xcode **Build Rust
Core** phase reruns `scripts/build_core.sh`. Locale flags are required:
memories fixtures assert `en_US`.

Rust core and Linux host tests:

```bash
cd core && cargo test --workspace
cd linux && cargo test --no-default-features
```

Linux UI: see [linux/INSTALL.md](linux/INSTALL.md). Model pack:
[scripts/build_model_pack/README.md](scripts/build_model_pack/README.md).

## What not to change in a docs-only change

Do not bump dependency versions, edit GitHub workflows, or alter
runtime tests unless the change is about that area.

## Guides

- [Architecture and trust boundaries](docs/architecture.md)
- [Mutations, storage, and backup](docs/storage.md)
- [Validation-only release](docs/release.md)
- [AI disclaimer](docs/AI_DISCLAIMER.md)
