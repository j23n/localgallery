#!/usr/bin/env bash
#
# Stage the on-device model pack where Xcode can bundle it:
#
#   build/model_packs/<version>/  ->  build/pack/<version>/
#
# Usage:  ./scripts/prepare_pack.sh [--force] [--optional|--no-pack]
#
#   PACK_VARIANT=full|tagging   which pack to stage (default: full)
#   PACK_SOURCE_DIR=<dir>       where built packs live (default: build/model_packs)
#
#   --force      restage even when the stamp matches
#   --optional   succeed with an empty build/pack when no pack is present
#   --no-pack    never stage a real pack; leave empty build/pack for xcodegen
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
# Cloning, not copying: on APFS `cp -c` asks for a `clonefile`; on GNU
# coreutils `--reflink=auto` is the equivalent. A volume that cannot clone
# falls back to a real copy. `stat` size/mtime uses GNU `-c` or BSD `-f`.
#
# The pack is deliberately *not* built here. `build_pack.py` needs torch and
# ~1 GB of downloaded weights, and folding that into the documented build would
# make a clean checkout depend on a Python/PyTorch toolchain. So when there is
# no pack to stage this exits non-zero with the command that builds one — a
# clear message at the start of the build rather than a code-signing error at
# the end of it. `--optional` / `--no-pack` are the CI escape hatch: tests that
# need a real pack skip; everything else can generate the Xcode project.
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
OPTIONAL=0
NO_PACK=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --optional) OPTIONAL=1 ;;
        --no-pack) NO_PACK=1 ;;
        # Everything from the shebang to the `set -e` is the doc comment.
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (expected --force, --optional, or --no-pack)" >&2; exit 2 ;;
    esac
done

if [[ "$OPTIONAL" -eq 1 && "$NO_PACK" -eq 1 ]]; then
    echo "error: --optional and --no-pack are mutually exclusive" >&2
    exit 2
fi

case "$VARIANT" in
    full|tagging) ;;
    *) echo "error: PACK_VARIANT must be 'full' or 'tagging' (got '$VARIANT')" >&2; exit 2 ;;
esac

# Portable file identity: size and mtime. GNU stat uses -c; BSD/macOS uses -f.
file_sig() {
    local f="$1" size mtime
    if size="$(stat -c '%s' "$f" 2>/dev/null)"; then
        mtime="$(stat -c '%Y' "$f")"
    else
        size="$(stat -f '%z' "$f")"
        mtime="$(stat -f '%m' "$f")"
    fi
    printf '%s %s' "$size" "$mtime"
}

# Newest-name order matching `sort -V` (PackResolver / this script). GNU and
# modern BSD `sort` have -V; fall back to a numeric-aware Python key.
version_sort() {
    if sort -V </dev/null >/dev/null 2>&1; then
        sort -V
    else
        python3 -c '
import re, sys
def key(s):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"([0-9]+)", s)]
print("\n".join(sorted((l.rstrip("\n") for l in sys.stdin), key=key)))
'
    fi
}

# APFS clonefile, GNU reflink, then a plain recursive copy.
stage_copy() {
    local src="$1" dest="$2"
    if cp -Rc "$src" "$dest" 2>/dev/null; then
        return 0
    fi
    if cp -R --reflink=auto "$src" "$dest" 2>/dev/null; then
        return 0
    fi
    cp -R "$src" "$dest"
}

write_empty_pack() {
    local reason="$1"
    rm -rf "$DEST_ROOT"
    mkdir -p "$DEST_ROOT"
    printf '%s\n' "$reason" > "$STAMP"
    echo "pack: $reason; empty build/pack for xcodegen"
}

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
    done | version_sort | tail -1
}

build_command() {
    local flags=""
    [[ "$VARIANT" == tagging ]] && flags=" --no-faces"
    echo "  cd $ROOT/scripts/build_model_pack"
    echo "  python3 -m venv .venv"
    echo "  .venv/bin/pip install -r requirements.txt"
    echo "  .venv/bin/python build_pack.py --out ../../build/model_packs$flags"
}

if [[ "$NO_PACK" -eq 1 ]]; then
    write_empty_pack "no-pack"
    exit 0
fi

PACK_NAME=""
[[ -d "$SOURCE_ROOT" ]] && PACK_NAME="$(newest_pack)"

if [[ -z "$PACK_NAME" ]]; then
    if [[ "$OPTIONAL" -eq 1 ]]; then
        write_empty_pack "optional-missing"
        exit 0
    fi
    echo "error: no $VARIANT model pack under $SOURCE_ROOT" >&2
    echo >&2
    echo "Build one (~350 MB of downloads, once):" >&2
    build_command >&2
    echo >&2
    echo "Then re-run ./scripts/prepare_pack.sh." >&2
    echo "CI / pack-less checkouts: ./scripts/prepare_pack.sh --optional" >&2
    exit 1
fi

SOURCE="$SOURCE_ROOT/$PACK_NAME"
DEST="$DEST_ROOT/$PACK_NAME"

# Identity of what is staged: which pack, and the manifest's size + mtime. A
# rebuilt pack under the same version name changes the manifest, so it restages.
SIGNATURE="$PACK_NAME $(file_sig "$SOURCE/manifest.json")"

if [[ $FORCE -eq 0 && -f "$DEST/manifest.json" && -f "$STAMP" ]] \
    && [[ "$(cat "$STAMP")" == "$SIGNATURE" ]]; then
    echo "pack: $PACK_NAME already staged in build/pack"
    exit 0
fi

echo "==> staging $PACK_NAME -> build/pack/$PACK_NAME"
rm -rf "$DEST_ROOT"
mkdir -p "$DEST_ROOT"
stage_copy "$SOURCE" "$DEST"
[[ -f "$DEST/manifest.json" ]] || { echo "error: staging produced no manifest.json" >&2; exit 1; }
echo "$SIGNATURE" > "$STAMP"

if has_faces "$DEST"; then
    echo "    faces: yes (insightface buffalo_sc — research / non-commercial licence)"
else
    echo "    faces: no (tagging-only pack)"
fi
echo "    $(du -sh "$DEST" | cut -f1)  $DEST"
echo
echo "Next: xcodegen && xcodebuild  (the Xcode build compiles the Rust core)"
