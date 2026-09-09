#!/usr/bin/env python3
"""Emit a CycloneDX 1.6 SBOM for source lockfiles (Cargo + model-pack pins).

Reads committed locks only — no network, no product rebuild. Output is for
validation artifacts and review, not a claim that CI published an IPA.

    python3 scripts/generate_sbom.py --out build/sbom.cdx.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PKG_RE = re.compile(
    r"^name = \"([^\"]+)\"\nversion = \"([^\"]+)\"(?:\nsource = \"([^\"]+)\")?",
    re.MULTILINE,
)
PIN_RE = re.compile(r"^([A-Za-z0-9_.-]+)==([0-9A-Za-z_.+-]+)")


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cargo_components(lock: Path) -> list[dict]:
    text = lock.read_text()
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for match in PKG_RE.finditer(text):
        name, version, source = match.group(1), match.group(2), match.group(3)
        key = (name, version)
        if key in seen:
            continue
        seen.add(key)
        purl = f"pkg:cargo/{name}@{version}"
        comp = {
            "type": "library",
            "name": name,
            "version": version,
            "purl": purl,
            "bom-ref": purl,
        }
        if source:
            comp["description"] = source
        out.append(comp)
    return out


def python_components(req: Path) -> list[dict]:
    out: list[dict] = []
    for raw in req.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        m = PIN_RE.match(line)
        if not m:
            continue
        name, version = m.group(1), m.group(2)
        purl = f"pkg:pypi/{name}@{version}"
        out.append(
            {
                "type": "library",
                "name": name,
                "version": version,
                "purl": purl,
                "bom-ref": purl,
            }
        )
    return out


def build_bom() -> dict:
    core_lock = ROOT / "core" / "Cargo.lock"
    linux_lock = ROOT / "linux" / "Cargo.lock"
    req = ROOT / "scripts" / "build_model_pack" / "requirements.txt"
    components: list[dict] = []
    components.extend(cargo_components(core_lock))
    components.extend(cargo_components(linux_lock))
    components.extend(python_components(req))
    # Dedup by purl after merging workspaces (shared crates).
    uniq: dict[str, dict] = {}
    for comp in components:
        uniq[comp["bom-ref"]] = comp
    ordered = [uniq[k] for k in sorted(uniq)]
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "timestamp": now,
            "component": {
                "type": "application",
                "name": "LocalGallery",
                "version": "0.1.0",
                "description": "Validation SBOM of committed Cargo.lock + model-pack pins",
            },
            "properties": [
                {
                    "name": "localgallery:core-cargo-lock-sha256",
                    "value": _sha256_file(core_lock),
                },
                {
                    "name": "localgallery:linux-cargo-lock-sha256",
                    "value": _sha256_file(linux_lock),
                },
                {
                    "name": "localgallery:model-pack-requirements-sha256",
                    "value": _sha256_file(req),
                },
            ],
        },
        "components": ordered,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "sbom.cdx.json")
    args = parser.parse_args()
    bom = build_bom()
    if len(bom["components"]) < 10:
        print("error: SBOM too small; lock parse failed", file=sys.stderr)
        return 1
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(bom, indent=2, sort_keys=False) + "\n")
    print(f"ok: {len(bom['components'])} components -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
