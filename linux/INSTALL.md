# Install LocalGallery on Linux

GTK4 / libadwaita desktop build of the same library the iOS app uses.
One binary: a laptop window (1200×800) or `localgallery --comet`
(540×620).

## Dependencies

Needs libadwaita 1.5+ (Ubuntu 24.04, Fedora 43 / Mechanix OS).

```bash
# Debian / Ubuntu
sudo apt install libgtk-4-dev libadwaita-1-dev pkg-config \
  libssl-dev build-essential clang cmake

# Fedora
sudo dnf install gtk4-devel libadwaita-devel pkgconf-pkg-config \
  openssl-devel gcc clang cmake
```

Rust: the pin in `core/rust-toolchain.toml` (rustup). First
`gallery-ml` build may download a static ONNX Runtime into
`~/.cache` / the ort cache when the `ml` feature is on.

## Run from a checkout

```bash
cd linux
cargo run                     # laptop window
cargo run -- --comet          # Comet-sized window
cargo test --no-default-features
```

Tagging and faces need a model pack **and** `--features ml`:

```bash
# pack search order:
#   $LOCALGALLERY_PACK
#   ~/.local/share/localgallery/pack
#   /usr/share/localgallery/pack
#   <repo>/build/pack
cargo run --features ml
```

Build a pack with
[scripts/build_model_pack/README.md](../scripts/build_model_pack/README.md)
and either export `LOCALGALLERY_PACK` or stage it under one of those
roots. Without a pack, browse and Places still work; Scan Photos skips
ONNX phases.

Places uses Nominatim. GPS coordinates leave the machine. Override the
endpoint with `LOCALGALLERY_NOMINATIM`.

## Install a binary locally

```bash
cd linux
cargo build --release
install -Dm755 target/release/localgallery ~/.local/bin/localgallery
install -Dm644 data/com.j23n.LocalGallery.desktop \
  ~/.local/share/applications/com.j23n.LocalGallery.desktop
```

AppStream metadata is `data/com.j23n.LocalGallery.metainfo.xml`
(project license MPL-2.0). There is no Flathub publication in this
repo.

## Library mutations

The Linux UI writes `.xmp` sidecars on Scan Photos / people / Places
and can move, delete, or create files in the chosen folder. The
library directory is watched (inotify); the host mutes its own sidecar
writes for the length of a walk or analysis run.

## Docker

The repo-root `Dockerfile` is a Linux toolchain image (core tests,
exiftool, GTK headers). Mount the tree; do not COPY it. It cannot
build the iOS xcframework.
