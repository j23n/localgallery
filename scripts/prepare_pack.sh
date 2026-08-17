#!/usr/bin/env bash
#
# Stage the on-device model pack where Xcode can bundle it:
#
#   build/model_packs/<version>/  ->  build/pack/<version>/
#
# Usage:  ./scripts/prepare_pack.sh [--force]
#
#   PACK_VARIANT=full|tagging   which pack to stage (default: full)
#   PACK_SOURCE_DIR=<dir>       where built packs live (default: build/model_packs)
#
# Run this before `xcodegen`, alongside `build_core.sh`. `project.yml` bundles
# `build/pack` as a folder resource, so it has to exist at a fixed path — while
# `build_pack.py` names its output for the pack version. This script is the
# join: it picks the newest built pack and clones it *under* that fixed path,
# keeping the version-named directory. The name is not decoration: `PackResolver`
# decides between the bundled and the imported pack by comparing directory
# names, so a bundled pack flattened to `pack/` would compare as the string
# "pack" and beat every imported version that sorts below it.
#
# `build/pack` holds exactly one pack — the previous one is cleared, so an app
# update cannot end up shipping two.
#
# Cloning, not copying: `cp -c` asks APFS for a `clonefile`, so staging 157 MB
# costs no time and no disk. A non-APFS volume falls back to a real copy.
#
# The pack is deliberately *not* built here. `build_pack.py` needs torch and
# ~1 GB of downloaded weights, and folding that into the documented build would
# make a clean checkout depend on a Python/PyTorch toolchain. So when there is
# no pack to stage this exits non-zero with the command that builds one — a
# clear message at the start of the build rather than a code-signing error at
# the end of it.
#
# `PACK_VARIANT=tagging` stages a tagging-only pack (no face models). The face
# models in the full pack are insightface's `buffalo_sc` (SCRFD-500M +
# w600k_mbf), which are research / non-commercial licensed: anything
# distributed has to ship the tagging variant or substitute licence-clean face
# models of its own.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${PACK_SOURCE_DIR:-$ROOT/build/model_packs}"
DEST_ROOT="$ROOT/build/pack"
STAMP="$ROOT/build/pack.stamp"
VARIANT="${PACK_VARIANT:-full}"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        # Everything from the shebang to the `set -e` is the doc comment.
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (expected --force)" >&2; exit 2 ;;
    esac
done

case "$VARIANT" in
    full|tagging) ;;
    *) echo "error: PACK_VARIANT must be 'full' or 'tagging' (got '$VARIANT')" >&2; exit 2 ;;
esac

# A schema-2 pack declares its face models under a top-level `faces` key; a
# tagging-only pack (schema 1, or `build_pack.py --no-faces`) has none.
has_faces() {
    grep -q '"faces"[[:space:]]*:' "$1/manifest.json"
}

# Newest pack matching the variant, by version-aware name order — the same
# ordering `PackResolver` applies at runtime, so the pack the app resolves is
# the pack staged here. `sort -V` ranks `-v1.10` above `-v1.9`, which plain
# lexicographic order does not.
newest_pack() {
    local dir
    for dir in "$SOURCE_ROOT"/*/; do
        [[ -f "$dir/manifest.json" ]] || continue
        if [[ "$VARIANT" == tagging ]] && has_faces "${dir%/}"; then continue; fi
        basename "${dir%/}"
    done | sort -V | tail -1
}

build_command() {
    local flags=""
    [[ "$VARIANT" == tagging ]] && flags=" --no-faces"
    echo "  cd $ROOT/scripts/build_model_pack"
    echo "  python3 -m venv .venv"
    echo "  .venv/bin/pip install -r requirements.txt"
    echo "  .venv/bin/python build_pack.py --out ../../build/model_packs$flags"
}

PACK_NAME=""
[[ -d "$SOURCE_ROOT" ]] && PACK_NAME="$(newest_pack)"

if [[ -z "$PACK_NAME" ]]; then
    echo "error: no $VARIANT model pack under $SOURCE_ROOT" >&2
    echo >&2
    echo "Build one (~350 MB of downloads, once):" >&2
    build_command >&2
    echo >&2
    echo "Then re-run ./scripts/prepare_pack.sh." >&2
    exit 1
fi

SOURCE="$SOURCE_ROOT/$PACK_NAME"
DEST="$DEST_ROOT/$PACK_NAME"

# Identity of what is staged: which pack, and the manifest's size + mtime. A
# rebuilt pack under the same version name changes the manifest, so it restages.
SIGNATURE="$PACK_NAME $(stat -f '%z %m' "$SOURCE/manifest.json")"

if [[ $FORCE -eq 0 && -f "$DEST/manifest.json" && -f "$STAMP" ]] \
    && [[ "$(cat "$STAMP")" == "$SIGNATURE" ]]; then
    echo "pack: $PACK_NAME already staged in build/pack"
    exit 0
fi

echo "==> staging $PACK_NAME -> build/pack/$PACK_NAME"
rm -rf "$DEST_ROOT"
mkdir -p "$DEST_ROOT"
# `-c` is the APFS clone; a volume that cannot clone falls back to a real copy.
cp -Rc "$SOURCE" "$DEST" 2>/dev/null || cp -R "$SOURCE" "$DEST"
[[ -f "$DEST/manifest.json" ]] || { echo "error: staging produced no manifest.json" >&2; exit 1; }
echo "$SIGNATURE" > "$STAMP"

if has_faces "$DEST"; then
    echo "    faces: yes (insightface buffalo_sc — research / non-commercial licence)"
else
    echo "    faces: no (tagging-only pack)"
fi
echo "    $(du -sh "$DEST" | cut -f1)  $DEST"
echo
echo "Next: ./scripts/build_core.sh && xcodegen && xcodebuild ..."
