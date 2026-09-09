# LocalGallery for Linux

GTK4 / libadwaita app. Same Rust core as iOS. One binary: GNOME laptop
layout, or `--comet` for a 540×620 window.

Install and package notes: [INSTALL.md](INSTALL.md).

```bash
sudo apt install libgtk-4-dev libadwaita-1-dev pkg-config
cd linux
cargo run -- --comet
cargo run
cargo test --no-default-features
```

Needs libadwaita 1.5+ (Ubuntu 24.04, Fedora 43 / Mechanix OS).

## What it does

The chosen folder is the library. **Scan Photos** (Preferences or the
app menu) runs tagging → faces → places and writes `.xmp` sidecars
next to photos. You can also move, delete, or create items in that
folder. Image bytes are not rewritten.

Places uses Nominatim in the Rust core (same source as iOS). **GPS
coordinates leave the device.** Override the endpoint with
`LOCALGALLERY_NOMINATIM`.

Tagging and faces need a model pack **and** `--features ml`. The pack
is optional and manual:

```bash
cargo run --features ml
# $LOCALGALLERY_PACK, ~/.local/share/localgallery/pack,
# /usr/share/localgallery/pack, then source-tree build/pack
```

HEIC analysis and viewer decode use the core software HEVC path, not
ImageIO.

The library folder is watched (inotify). Sidecar writes from an
analysis run are muted for that walk.

Grid tiles use the Freedesktop thumbnail cache (`large` at 1×,
`x-large` at 2×). A miss is written back so Files can reuse it. The
viewer decodes the original at the window long side, capped at 2000 px.
Tagging and faces do not read those display pixels. People review
crops the display thumb at the MWG box.

License: MPL-2.0 (see root `LICENSE` and AppStream `project_license`).
