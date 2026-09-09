#!/usr/bin/env python3
"""Record or verify photo-tools taxonomy provenance.

Does not vendor the yaml or any pack binary. Writes/checks:

    taxonomy.lock.json     source repo/commit + derived hashes
    taxonomy_paths.txt     sorted Objects/* and Scenes/* paths

    python3 lock_taxonomy.py --check
    python3 lock_taxonomy.py --write --photo-tools /path/to/photo-tools
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCK = HERE / "taxonomy.lock.json"
PATHS = HERE / "taxonomy_paths.txt"


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def write(photo_tools: Path) -> None:
    import labels as labels_mod

    mapping = labels_mod.mapping_path(photo_tools)
    if not mapping.is_file():
        raise SystemExit(f"missing taxonomy mapping: {mapping}")
    paths = labels_mod.taxonomy_paths(photo_tools, verify=False)
    paths_text = "".join(p + "\n" for p in paths)
    PATHS.write_text(paths_text)

    try:
        commit = _git(photo_tools, "rev-parse", "HEAD")
        tracked = _git(photo_tools, "ls-files", str(labels_mod.MAPPING_RELPATH))
    except (subprocess.CalledProcessError, FileNotFoundError):
        commit = None
        tracked = ""

    lock = {
        "source": {
            "repository": "https://github.com/j23n/photo-tools",
            "path": str(labels_mod.MAPPING_RELPATH),
            "commit": commit,
            "mapping_sha256": _sha256_bytes(mapping.read_bytes()),
            "git_tracked": bool(tracked),
        },
        "derived": {
            "pack_version": "mobileclip-s2-v1",
            "label_count": len(paths),
            "taxonomy_paths_file": PATHS.name,
            "taxonomy_paths_sha256": _sha256_bytes(paths_text.encode()),
        },
    }
    LOCK.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"wrote {PATHS} ({len(paths)} paths)")
    print(f"wrote {LOCK}")
    if commit:
        print(f"photo-tools HEAD {commit}")
    print(f"mapping sha256 {lock['source']['mapping_sha256']}")


def check() -> int:
    if not PATHS.is_file() or not LOCK.is_file():
        print(f"error: missing {PATHS.name} or {LOCK.name}", file=sys.stderr)
        return 1
    paths_text = PATHS.read_text()
    paths = [line for line in paths_text.splitlines() if line]
    if paths != sorted(paths):
        print("error: taxonomy_paths.txt is not sorted", file=sys.stderr)
        return 1
    lock = json.loads(LOCK.read_text())
    derived = lock.get("derived", {})
    digest = _sha256_bytes(paths_text.encode())
    pinned = derived.get("taxonomy_paths_sha256")
    if pinned and digest != pinned:
        print(f"error: {PATHS.name} sha256 {digest} != lock {pinned}", file=sys.stderr)
        return 1
    count = derived.get("label_count")
    if count is not None and len(paths) != count:
        print(f"error: path count {len(paths)} != lock {count}", file=sys.stderr)
        return 1
    if len(paths) < 100:
        print(f"error: implausibly small taxonomy ({len(paths)} paths)", file=sys.stderr)
        return 1
    print(f"ok: {len(paths)} pinned taxonomy paths; sha256 {digest}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write", action="store_true")
    parser.add_argument(
        "--photo-tools",
        type=Path,
        default=None,
        help="photo-tools checkout (default: sibling photo-tools/)",
    )
    args = parser.parse_args()
    if args.write:
        root = args.photo_tools
        if root is None:
            import labels as labels_mod

            root = labels_mod.DEFAULT_PHOTO_TOOLS
        write(root)
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main())
