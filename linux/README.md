# LocalGallery for Linux

GTK4 / libadwaita app. Same Rust core as iOS. One binary for a GNOME laptop
and a Mecha Comet (`--comet` opens at 540×620).

```bash
sudo apt install libgtk-4-dev libadwaita-1-dev pkg-config
cd linux
cargo run -- --comet          # Comet-sized window
cargo run                     # 1200×800 laptop window
cargo test --no-default-features   # host tests, no GTK
```

Needs libadwaita 1.5+ (Ubuntu 24.04, Fedora 43 / Mechanix OS).

**Scan Photos** (Preferences or the app menu) runs tagging → faces → places.
Places uses Nominatim in the Rust core (same source as iOS). GPS leaves the
device. Override the endpoint with `LOCALGALLERY_NOMINATIM`. Tagging and
faces need a model pack *and* a build with ONNX:

```bash
cargo run --features ml
# pack search order: $LOCALGALLERY_PACK, ~/.local/share/localgallery/pack,
# /usr/share/localgallery/pack, source-tree build/pack
```

The library folder is watched (inotify). Our own sidecar writes are muted
for the length of a walk or analysis run.

Grid tiles use the Freedesktop cache (`large` at 1×, `x-large` at 2×). A miss
is written back there so Files can reuse it. The viewer decodes the original
at the window long side, capped at 2000 px like iOS. Tagging/faces never read
these display pixels. People review crops the display thumb at the MWG box.
