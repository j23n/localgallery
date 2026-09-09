# Release runbook (validation only)

Tagged revisions are **validation pins**. CI must not publish an IPA
or other installable ([ADR 0003](adr/0003-validation-only-release.md)).
There is no App Store pipeline in this repository.

## What a tag is for

1. Mark a known tree (`v0.1.0`).
2. Let CI generate the Xcode project (after core + pack path exist),
   compile, archive if configured, and run tests.
3. Stop. Do not attach `LocalGallery.ipa` to a GitHub Release.

`.github/workflows/build.yml` is unsigned archive validation: it
archives the app, checks the `.app` layout, and **fails if an IPA is
present**. It does not export, upload, or publish an IPA. Release
tokens are not used.

Human distribution, if any, is a local archive or sideload you produce
on a signing-capable Mac. That process is outside this repo.

## Operator checklist (local)

```bash
git checkout <tag>
./scripts/build_core.sh --release
# Optional pack — required only if you want tagging/faces in that build:
cd scripts/build_model_pack
# …create venv, build_pack.py --no-faces for anything you will give away
cd ../..
PACK_VARIANT=tagging ./scripts/prepare_pack.sh
xcodegen
# Any available iPhone simulator (iOS 18+). Helper: scripts/pick_ios_simulator.sh
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=$(./scripts/pick_ios_simulator.sh)" \
  -testLanguage en -testRegion US
cd core && cargo test --workspace
cd ../linux && cargo test --no-default-features
```

A tagging-only pack is the distribution default: the full pack's face
models are research / non-commercial. Personal builds may stage
`PACK_VARIANT=full`.

## Linux

```bash
cd linux
cargo test --no-default-features
cargo build --release --features ml    # only if a pack will be installed
```

Do not upload the binary as a "release artifact" from tag CI. Package
locally (see [linux/INSTALL.md](../linux/INSTALL.md)).

## Pack and license

- App: [MPL-2.0](../LICENSE) ([ADR 0004](adr/0004-mpl-licensing.md)).
- Model weights: separate. Do not ship `buffalo_sc` faces.
- HEIC: ImageIO on iOS analysis; software path elsewhere. No libheif.
