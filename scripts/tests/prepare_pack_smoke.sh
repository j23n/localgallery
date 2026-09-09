#!/usr/bin/env bash
#
# Smoke tests for scripts/prepare_pack.sh: GNU/BSD-portable staging, newest
# pack selection, variant filtering, stamp skip, and --optional / --no-pack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/prepare_pack.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/prepare_pack_smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

export PACK_SOURCE_DIR="$TMP/model_packs"
# Isolate dest by running from a fake repo root that still finds the script.
# prepare_pack.sh derives ROOT from its own location, so we override dest via
# a wrapper that copies the script... instead, we monkey-patch by using the
# real script and pointing PACK_SOURCE_DIR, then checking the real build/.
# That would clobber the developer's staged pack. Use a copy of the script
# with ROOT redirected through an env the script does not have — so invoke
# via a tiny shim that cds into TMP and execs a patched copy.

FAKE="$TMP/repo"
mkdir -p "$FAKE/scripts" "$FAKE/build"
cp "$SCRIPT" "$FAKE/scripts/prepare_pack.sh"
chmod +x "$FAKE/scripts/prepare_pack.sh"
# The copied script still computes ROOT from BASH_SOURCE, which is FAKE. Good.

write_pack() {
    local name="$1" faces="${2:-0}"
    local dir="$FAKE/build/model_packs/$name"
    mkdir -p "$dir"
    if [[ "$faces" -eq 1 ]]; then
        printf '{\n  "pack_version": "%s",\n  "faces": {}\n}\n' "$name" > "$dir/manifest.json"
    else
        printf '{\n  "pack_version": "%s"\n}\n' "$name" > "$dir/manifest.json"
    fi
    echo "payload $name" > "$dir/dummy.bin"
}

run() {
    (cd "$FAKE" && PACK_SOURCE_DIR="$FAKE/build/model_packs" "$@")
}

# -- unknown flag
set +e
run /bin/bash "$FAKE/scripts/prepare_pack.sh" --bogus >/dev/null 2>"$TMP/err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "unknown flag should exit 2, got $rc"
pass "unknown flag exits 2"

# -- missing pack fails
set +e
run /bin/bash "$FAKE/scripts/prepare_pack.sh" >/dev/null 2>"$TMP/err"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing pack should exit 1, got $rc"
grep -q "no full model pack" "$TMP/err" || fail "missing pack error text"
pass "missing pack fails loudly"

# --optional with no pack
run /bin/bash "$FAKE/scripts/prepare_pack.sh" --optional >"$TMP/out"
[[ -d "$FAKE/build/pack" ]] || fail "--optional did not create build/pack"
[[ "$(cat "$FAKE/build/pack.stamp")" == "optional-missing" ]] || fail "--optional stamp"
grep -q "optional-missing" "$TMP/out" || fail "--optional stdout"
pass "--optional succeeds with empty pack"

# --no-pack even when a pack exists
write_pack "mobileclip-s2-v1" 1
run /bin/bash "$FAKE/scripts/prepare_pack.sh" --no-pack >"$TMP/out"
[[ ! -e "$FAKE/build/pack/mobileclip-s2-v1" ]] || fail "--no-pack staged a pack"
[[ "$(cat "$FAKE/build/pack.stamp")" == "no-pack" ]] || fail "--no-pack stamp"
pass "--no-pack ignores an existing pack"

# --optional and --no-pack together
set +e
run /bin/bash "$FAKE/scripts/prepare_pack.sh" --optional --no-pack >/dev/null 2>"$TMP/err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "exclusive flags should exit 2, got $rc"
pass "--optional/--no-pack exclusive"

# stage newest full pack (faces ok); v1.10 beats v1.9
write_pack "mobileclip-s2-v1.9" 1
write_pack "mobileclip-s2-v1.10" 1
write_pack "mobileclip-s2-v1" 1
run /bin/bash "$FAKE/scripts/prepare_pack.sh" --force >"$TMP/out"
[[ -f "$FAKE/build/pack/mobileclip-s2-v1.10/manifest.json" ]] || fail "did not stage v1.10"
[[ ! -e "$FAKE/build/pack/mobileclip-s2-v1.9" ]] || fail "left an older pack in dest"
grep -q "staging mobileclip-s2-v1.10" "$TMP/out" || fail "staging line"
pass "stages newest version-aware pack"

# stamp skip
run /bin/bash "$FAKE/scripts/prepare_pack.sh" >"$TMP/out"
grep -q "already staged" "$TMP/out" || fail "expected stamp skip"
pass "stamp skip is a no-op"

# --force restages
run /bin/bash "$FAKE/scripts/prepare_pack.sh" --force >"$TMP/out"
grep -q "staging mobileclip-s2-v1.10" "$TMP/out" || fail "--force did not restage"
pass "--force restages"

# tagging variant skips packs with faces
rm -rf "$FAKE/build/model_packs" "$FAKE/build/pack" "$FAKE/build/pack.stamp"
write_pack "full-v1" 1
write_pack "tag-v1" 0
PACK_VARIANT=tagging run /bin/bash "$FAKE/scripts/prepare_pack.sh" --force >"$TMP/out"
[[ -f "$FAKE/build/pack/tag-v1/manifest.json" ]] || fail "tagging did not stage tag-v1"
[[ ! -e "$FAKE/build/pack/full-v1" ]] || fail "tagging staged a faces pack"
pass "PACK_VARIANT=tagging skips faces packs"

# tagging with only faces packs + --optional
rm -rf "$FAKE/build/model_packs" "$FAKE/build/pack" "$FAKE/build/pack.stamp"
write_pack "full-only" 1
PACK_VARIANT=tagging run /bin/bash "$FAKE/scripts/prepare_pack.sh" --optional >"$TMP/out"
[[ "$(cat "$FAKE/build/pack.stamp")" == "optional-missing" ]] || fail "tagging --optional stamp"
pass "tagging --optional when only faces packs exist"

# bad PACK_VARIANT
set +e
PACK_VARIANT=other run /bin/bash "$FAKE/scripts/prepare_pack.sh" >/dev/null 2>"$TMP/err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "bad variant should exit 2, got $rc"
pass "invalid PACK_VARIANT exits 2"

echo
echo "prepare_pack smoke: all passed"
