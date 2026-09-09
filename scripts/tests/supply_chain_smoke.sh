#!/usr/bin/env bash
#
# Parse/run the supply-chain helpers added for CI. Does not need PyPI or
# photo-tools: path inventory must pass; provenance is expected to fail
# unresolved until a reproducing commit is pinned.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/supply_chain_smoke.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

python3 scripts/build_model_pack/lock_requirements.py --check \
    || fail "lock_requirements.py --check"
pass "direct-artifact inventory"

python3 scripts/build_model_pack/lock_taxonomy.py --check-paths \
    || fail "lock_taxonomy.py --check-paths"
pass "taxonomy path pin"

set +e
python3 scripts/build_model_pack/lock_taxonomy.py --check >"$TMPDIR/tax.out" 2>"$TMPDIR/tax.err"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    grep -q "reproduces taxonomy_paths_sha256" "$TMPDIR/tax.out" \
        || fail "provenance passed without a pin confirmation"
    pass "taxonomy provenance pinned"
elif [[ "$rc" -eq 2 ]]; then
    grep -q "unresolved taxonomy provenance" "$TMPDIR/tax.err" \
        || fail "exit 2 without unresolved provenance message"
    pass "taxonomy provenance unresolved (explicit fail)"
else
    cat "$TMPDIR/tax.err" >&2
    fail "lock_taxonomy.py --check exited $rc"
fi

python3 scripts/generate_sbom.py --out "$TMPDIR/sbom.cdx.json" \
    || fail "generate_sbom.py"
python3 - <<PY
import json, sys
from pathlib import Path
p = Path("$TMPDIR/sbom.cdx.json")
bom = json.loads(p.read_text())
assert bom.get("bomFormat") == "CycloneDX", bom.get("bomFormat")
assert bom.get("specVersion") == "1.6"
n = len(bom.get("components") or [])
assert n >= 10, n
print(f"ok: sbom {n} components")
PY

python3 - <<'PY'
from pathlib import Path
root = Path(".")
files = [
    root / ".github/workflows/test.yml",
    root / ".github/workflows/build.yml",
    root / ".github/dependabot.yml",
]
for path in files:
    text = path.read_text()
    if "\t" in text:
        raise SystemExit(f"tabs in {path}")
    if path.name == "dependabot.yml":
        if "package-ecosystem: cargo" not in text or "package-ecosystem: pip" not in text:
            raise SystemExit("dependabot missing cargo/pip ecosystems")
        continue
    for needle in (
        "jobs:",
        "uses: actions/checkout@",
        "d1031067263f94b142dd6c0ce24c5eb9d02d52a0",
        "ed7a3b1fda3918c0306d1b724322adc0b8cc0a90",
    ):
        if needle not in text:
            raise SystemExit(f"{path} missing {needle}")
    if "brew install xcodegen" in text or "latest-stable" in text:
        raise SystemExit(f"{path} still uses unpinned XcodeGen/Xcode")
print("ok: workflow structure / pins")
try:
    import yaml  # type: ignore
except ImportError:
    print("ok: PyYAML not installed; skipped full YAML load")
else:
    for path in files:
        docs = list(yaml.safe_load_all(path.read_text()))
        if not docs or docs[0] is None:
            raise SystemExit(f"empty YAML: {path}")
        print(f"ok: yaml load {path}")
PY

for script in \
    scripts/install_xcodegen.sh \
    scripts/pick_ios_simulator.sh \
    scripts/generate_xcode.sh \
    scripts/prepare_pack.sh \
    scripts/build_core.sh \
    scripts/set_build_number.sh \
    scripts/tests/prepare_pack_smoke.sh \
    scripts/tests/supply_chain_smoke.sh
do
    bash -n "$script" || fail "bash -n $script"
done
pass "shell syntax"

echo
echo "supply_chain smoke: all passed"
