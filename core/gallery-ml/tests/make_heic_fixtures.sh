#!/bin/bash
#
# Build the committed HEIC fixtures in `tests/fixtures/`.
#
#     bash core/gallery-ml/tests/make_heic_fixtures.sh
#
# Run only when adding a case; the outputs are committed, and regenerating
# them moves the golden hashes in `tests/preprocess_golden.rs`.
#
# The *encoder* here is ImageIO, through `sips`. That is deliberate and it is
# not a doctrine violation: the fixture bytes are committed, so what a given
# macOS version encodes stops mattering the moment this script has run. What
# the doctrine forbids is ImageIO at *runtime*, on the user's photos, which is
# the thing `heif-oxide` exists to avoid.
#
# Requires macOS (sips). There is no pure-Rust HEVC *encoder* to pair with the
# decoder — see the note in `preprocess::heif`.
set -eu

cd "$(dirname "$0")/fixtures"

# 1. The same content as an existing fixture, so `expected_tags.json` can
#    assert that a HEIC and a PNG of one image land on the same tags.
sips -s format heic meadow.png --out meadow.heic >/dev/null

# 2. Grid-tiled. ImageIO switches to a `grid` derived item at 1024 px, which
#    is how iPhone stores every full-size photo; a decoder that only handles a
#    single `hvc1` item passes every other test here and fails on real photos.
#    Verify with `make_heic_fixtures.sh`'s own item-type listing below — the
#    switch is a heuristic inside ImageIO, not a documented threshold, so a
#    macOS update could move it and quietly turn this fixture into a duplicate
#    of `meadow.heic`.
sips -Z 1024 meadow.png --out /tmp/heicfix_big.png >/dev/null
sips -s format heic /tmp/heicfix_big.png --out grid.heic >/dev/null
rm -f /tmp/heicfix_big.png

# 3. `irot` in the item properties, which is HEIC's own rotation and has
#    nothing to do with EXIF orientation. Applying both would double-rotate.
#    Built from the 96x64 gradient rather than the square meadow, so the
#    rotation is visible in the output *dimensions* and not only in the pixels.
sips -s format heic gradient.jpg --out rot90.heic >/dev/null
sips -r 90 rot90.heic >/dev/null

# Report the item types, because "is this actually tiled" is the one property
# of these fixtures that is invisible in the file name and in the pixels.
item_types() {
  python3 - "$1" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
kinds = set()
for m in re.finditer(b"infe", data):
    kinds.add(data[m.start() + 12:m.start() + 16].decode("latin1"))
print(",".join(sorted(kinds)))
PY
}

for f in meadow.heic grid.heic rot90.heic; do
  printf '%-14s %7s bytes  %-10s items=%s\n' "$f" "$(stat -f%z "$f")" \
    "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')" \
    "$(item_types "$f")"
done
