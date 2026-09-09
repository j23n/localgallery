#!/usr/bin/env python3
"""Record or verify photo-tools taxonomy provenance.

Does not vendor the yaml or any pack binary. Writes/checks:

    taxonomy.lock.json     source repo/commit + derived hashes
    taxonomy_paths.txt     sorted Objects/* and Scenes/* paths

    python3 lock_taxonomy.py --check           # paths + live provenance
    python3 lock_taxonomy.py --check-paths     # committed path list only
    python3 lock_taxonomy.py --write --photo-tools /path/to/photo-tools

`--check-paths` is required: a drifted path list or hash is a hard fail.

`--check` also queries the declared source repository. A git commit is
recorded only when that mapping reproduces taxonomy_paths_sha256. Unresolved
source provenance (private/404 repo, or no verified commit yet) is a
warning and exits 2 — a manual gate, not a CI-red condition. A pinned
commit that fetches and fails to reproduce the hash is a hard fail.
Do not invent a source commit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCK = HERE / "taxonomy.lock.json"
PATHS = HERE / "taxonomy_paths.txt"
ROOTS = ("Objects", "Scenes")
UNRESOLVED = 2


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def _paths_from_mapping_bytes(data: bytes) -> list[str]:
    try:
        import yaml
    except ImportError as exc:
        raise SystemExit(
            "error: PyYAML is required to derive paths from a fetched mapping"
        ) from exc
    mapping = yaml.safe_load(data)
    paths: set[str] = set()
    for entry in mapping.values():
        if entry is None:
            continue
        category = entry["category"]
        if category not in ROOTS:
            continue
        path = f"{category}/{entry['tag']}"
        if not re.fullmatch(r"[A-Za-z0-9 /-]+", path):
            raise ValueError(f"unexpected characters in taxonomy path {path!r}")
        paths.add(path)
    return sorted(paths)


def _paths_digest(paths: list[str]) -> str:
    return _sha256_bytes("".join(p + "\n" for p in paths).encode())


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
            "status": "pinned" if commit else "unresolved",
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


def check_paths() -> int:
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


def _http_get(url: str, timeout: int = 30) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": "localgallery-taxonomy-lock"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if getattr(resp, "status", 200) >= 400:
                return None
            return resp.read()
    except (urllib.error.URLError, TimeoutError, ValueError):
        return None


def _git_ls_remote(repository: str, ref: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "ls-remote", repository, ref],
            text=True,
            timeout=30,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if not out:
        return None
    return out.split()[0]


def _fetch_mapping(repository: str, path: str, commit: str) -> bytes | None:
    if repository.rstrip("/").endswith(".git"):
        repo = repository[: -len(".git")]
    else:
        repo = repository.rstrip("/")
    slug = repo.removeprefix("https://github.com/").removeprefix("http://github.com/")
    urls = [
        f"https://raw.githubusercontent.com/{slug}/{commit}/{path}",
        f"{repo}/raw/{commit}/{path}",
    ]
    for url in urls:
        data = _http_get(url)
        if data:
            return data
    # Shallow sparse clone as a last resort.
    tmp = tempfile.mkdtemp(prefix="photo-tools-")
    try:
        subprocess.check_call(
            [
                "git",
                "clone",
                "--filter=blob:none",
                "--sparse",
                "--depth",
                "1",
                repository,
                tmp,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=90,
        )
        if commit:
            subprocess.check_call(
                ["git", "-C", tmp, "fetch", "--depth", "1", "origin", commit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=90,
            )
            subprocess.check_call(
                ["git", "-C", tmp, "checkout", commit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
        mapping = Path(tmp) / path
        if mapping.is_file():
            return mapping.read_bytes()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return None
    finally:
        subprocess.call(["rm", "-rf", tmp])
    return None


def _fail(reason: str) -> int:
    print(f"error: taxonomy provenance check failed: {reason}", file=sys.stderr)
    return 1


def _unresolved(reason: str) -> int:
    print(f"warning: unresolved taxonomy provenance: {reason}", file=sys.stderr)
    print(
        "warning: source-provenance verification is a manual gate until a "
        "verified commit can be supplied. Path/hash pins remain required. "
        "Do not invent a source commit. Query https://github.com/j23n/photo-tools "
        "and pin a commit only if its Objects/Scenes mapping reproduces "
        "taxonomy_paths_sha256.",
        file=sys.stderr,
    )
    return UNRESOLVED


def check_provenance() -> int:
    lock = json.loads(LOCK.read_text())
    source = lock.get("source") or {}
    derived = lock.get("derived") or {}
    expected = derived.get("taxonomy_paths_sha256")
    repository = source.get("repository") or "https://github.com/j23n/photo-tools"
    path = source.get("path") or "src/photo_tools/data/ram_tag_mapping.yaml"
    commit = source.get("commit")

    if not expected:
        return _fail("lock is missing derived.taxonomy_paths_sha256")

    if commit:
        if not re.fullmatch(r"[0-9a-f]{40}", str(commit)):
            return _fail(f"source.commit is not a 40-char git sha ({commit!r})")
        data = _fetch_mapping(repository, path, commit)
        if not data:
            return _unresolved(
                f"could not fetch {path} at {commit} from {repository} "
                "(repository may be private or 404)"
            )
        try:
            paths = _paths_from_mapping_bytes(data)
        except (ValueError, KeyError, TypeError) as exc:
            return _fail(f"mapping at {commit} did not parse: {exc}")
        digest = _paths_digest(paths)
        if digest != expected:
            return _fail(
                f"commit {commit} mapping digest {digest} != pinned {expected}"
            )
        print(f"ok: photo-tools {commit} reproduces taxonomy_paths_sha256")
        return 0

    # No commit in the lock: try to resolve HEAD. Pin only if it matches.
    head = _git_ls_remote(repository, "HEAD") or _git_ls_remote(repository, "refs/heads/main")
    if not head:
        api = _http_get(
            "https://api.github.com/repos/j23n/photo-tools/commits/main"
        ) or _http_get("https://api.github.com/repos/j23n/photo-tools")
        if not api:
            return _unresolved(
                f"public clone of {repository} was not resolvable from this environment"
            )
        try:
            payload = json.loads(api.decode())
            head = payload.get("sha") or (payload.get("commit") or {}).get("sha")
        except json.JSONDecodeError:
            head = None
        if not head:
            return _unresolved(f"{repository} responded but advertised no commit")

    data = _fetch_mapping(repository, path, head)
    if not data:
        return _unresolved(f"could not fetch {path} at HEAD {head} from {repository}")
    try:
        paths = _paths_from_mapping_bytes(data)
    except (ValueError, KeyError, TypeError) as exc:
        return _unresolved(f"HEAD {head} mapping did not parse: {exc}")
    digest = _paths_digest(paths)
    if digest != expected:
        return _unresolved(
            f"HEAD {head} mapping digest {digest} != pinned {expected}; "
            "not pinning a non-reproducing commit"
        )
    return _unresolved(
        f"HEAD {head} reproduces the taxonomy hash but the lock does not "
        "pin that commit; re-run --write against that checkout"
    )


def check() -> int:
    rc = check_paths()
    if rc != 0:
        return rc
    return check_provenance()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--check-paths",
        action="store_true",
        help="verify taxonomy_paths.txt against the lock only (no network)",
    )
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
    if args.check_paths:
        return check_paths()
    return check()


if __name__ == "__main__":
    sys.exit(main())
