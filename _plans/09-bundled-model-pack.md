# Phase 7 — Ship the model pack inside the app

Today the only way to get tagging or faces working is Settings → "Import Model
Pack…" and a folder picker. That is a developer's install path, not a user's:
a fresh install has no pack, the feature appears broken, and there is nowhere
to get one from. The pack should be in the app.

**Exit criterion:** a clean install can tag and scan faces with no import step,
the import path still works for a newer pack, and the 3-command build tells you
exactly what to do when the pack is missing instead of failing obscurely.

## Current state

| thing | where |
|---|---|
| pack discovery | `TaggingService.newestPackDirectory(in:)` — subdirectories of one root containing `manifest.json`, sorted by version-aware name, newest first |
| root | `GalleryPaths.modelPacksDirectoryURL` = `Application Support/ModelPacks/` |
| import | `TaggingService.importModelPack(from:)` — copies, then verifies **at the destination**, removing a rejected copy |
| verification cache | `PackFingerprint` = manifest path + size + mtime; a full verify SHA-256s every model file |
| faces availability | `TaggingService.pack.hasFaces` (manifest schema 2), read by `FaceService` through an injected closure |
| the real pack | `build/model_packs/mobileclip-s2-v1` — 157 MB, already built on this machine, inside git-ignored `build/` |
| pack access | `gallery-ml/src/pack.rs` reads with `std::fs::read`; **nothing writes into a pack directory** |
| resource precedent | `project.yml` already declares `core/gallery-ml/tests/{testpack,facepack,fixtures}` as `type: folder` resources |

## Decisions

### Read the bundled pack in place

The core never writes to a pack directory — `pack.rs` reads and hashes, and the
sessions hold files open read-only. So the read-only app bundle is a valid pack
location and there is no reason to copy 157 MB into Application Support on
first launch.

The one wrinkle is the verification cache, which is keyed on the manifest's
size and mtime. A reinstall changes the mtime, so the pack is fully re-verified
once per install. That is the correct behaviour (the bytes really did change)
and it costs a SHA-256 pass over 157 MB — a fraction of a second, off the main
actor, once.

### Precedence: newest wins, wherever it lives

Not "imported always wins": a stale import would shadow a newer bundled pack
forever after an app update, and the user would have no way to know.

Resolution becomes: collect candidate directories from **both** the bundle and
`Application Support/ModelPacks/`, and apply the existing version-aware name
comparator across the union. An imported `mobileclip-s2-v2` beats a bundled
`-v1`; a bundled `-v2` beats a stale imported `-v1`. Ties go to the imported
copy (the user did something deliberate).

Extract this as a pure function — `PackResolver.resolve(bundled:imported:)`
over arrays of URLs — so it is testable without a 157 MB fixture. That is the
whole reason to name it.

### Keep the import path

It stays, with two changes: Settings labels the active pack's *source*
("Bundled" / "Imported"), and an imported pack gains a "Remove" button that
falls back to the bundled one. Import is how a new pack gets tested before it
is built into a release, and how a user with a licence-clean face pack of their
own substitutes it.

### Bundle the full pack, faces included

`build_pack.py --no-faces` produces a valid schema-1, tagging-only pack and the
app already hides its face UI for one, so both variants are buildable today.

Bundle the **full** pack. Faces are a headline feature of the app and the whole
Phase-2 review flow is dead weight without them. The cost is that the app
binary now contains the insightface `buffalo_sc` models (SCRFD-500M +
w600k_mbf), which are **research / non-commercial licensed**. For a personal,
simulator-only app that is fine; for anything distributed it is not, and the
fix is a build flag, not a redesign:

```
PACK_VARIANT=tagging ./scripts/prepare_pack.sh   # --no-faces
```

Write that constraint into `README.md` next to the pack step, not only here.

### The pack lives at one stable path, populated by a script

`project.yml` must reference a fixed path, and pack directories are named for
their version. So:

- `build/pack/` — the single stable location the Xcode resource points at,
  git-ignored with the rest of `build/`.
- `scripts/prepare_pack.sh` — populates it. If a built pack exists under
  `build/model_packs/`, it clones the newest one into `build/pack/` with
  `cp -c` (APFS `clonefile`: instant, no extra disk). If none exists, it prints
  the exact `build_pack.py` invocation and exits non-zero.

**Correction, made while building this:** the pack is staged one level down, at
`build/pack/<version>/`, and `build/pack` is the *root* the resolver
enumerates — not the pack itself. Flattening it loses the version-named
directory, and the version name is precisely what precedence is decided on: a
bundled pack living at `pack/` would be compared as the literal string "pack",
which beats every `mobileclip-…` an import could ever produce. So the fixed
path is a root holding exactly one pack (the previous one is cleared, so an
update cannot ship two), `GalleryPaths.bundledModelPackURL` is that root, and
`PackResolver.candidates(in:)` reads it exactly as it reads
`Application Support/ModelPacks/`. One enumeration rule, two roots.

`build_core.sh` stays as it is. The pack is not a core artefact, and folding a
Python/PyTorch download into the Rust build would make the documented
three-command build depend on a 2 GB toolchain. The build becomes four
commands, with the new one cheap and idempotent:

```bash
./scripts/prepare_pack.sh
./scripts/build_core.sh
xcodegen
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

`project.yml` gains, on the app target only:

```yaml
- path: build/pack
  type: folder
  buildPhase: resources
```

which lands as `LocalGallery.app/pack/`, found via
`Bundle.main.url(forResource: "pack", withExtension: nil)`.

The precondition check belongs in `prepare_pack.sh` rather than a build phase,
so a missing pack is a clear message at the start rather than a code-signing
error at the end.

## What an app update costs

Worth stating precisely, because the machinery already answers it and the
answer is better than people assume:

- **Labels-only pack rebuild** (new taxonomy, same encoder): the embedding
  cache is keyed on the encoder's SHA-256 + `PREPROCESS_VERSION`, so every
  vector is reused. `pack_version` changes, `mark_stale_for_pack` re-opens the
  rows, and the run re-scores from cache — **no inference at all**.
- **New encoder**: the cache key changes, and the library is re-embedded. Long,
  resumable, cancellable, and correct.
- **Faces added to a pack**: face results key on `face_pack_key` (both face
  model hashes + `PREPROCESS_VERSION` + `ALIGN_VERSION`), which is independent
  of the tagging key — adding face models does not re-tag, and a labels rebuild
  does not re-detect.

## Order of work

1. **`scripts/prepare_pack.sh`** + the `PACK_VARIANT` flag + README/CLAUDE.md
   build-step updates. Lands alone and is verifiable by itself.
2. **`PackResolver`** — pure resolution over two candidate lists, with the
   bundled URL supplied by `GalleryPaths` (by injection, no default, like every
   other path in that type). `TaggingService.refreshPack` calls it instead of
   `newestPackDirectory(in:)` on one root; `newestPackDirectory` becomes the
   per-root enumerator it already is.
3. **Settings** — source label, "Remove imported pack", and the empty state
   reworded: with a bundled pack, "no pack" is now a build error rather than a
   user state, so the copy that tells the user to import one only appears when
   the bundle genuinely has none.
4. **`project.yml`** resource + a first-launch check.

## Test plan

- `PackResolverTests` (pure, no bytes): bundled only; imported only; imported
  newer; bundled newer; equal versions → imported; a directory with no
  `manifest.json` ignored; `-v1.10` sorts above `-v1.9` (the reason the
  comparator is `.numeric`).
- `TaggingSessionTests` / `FaceSessionTests` keep using the tiny committed
  `testpack`/`facepack`. They must **not** switch to the real pack: they are
  the simulator-vs-host drift check, the host has no 157 MB fixture, and a
  148 MB ONNX in a test run would dwarf the suite.
- One integration check that the bundled pack is actually present in the built
  app and verifies — skipped (not failed) when `build/pack` was not populated,
  so a checkout without a pack still runs the suite green.

## Risks

| Risk | Response |
|---|---|
| +157 MB app size | Accepted; simulator-only. For a real distribution this becomes On-Demand Resources or a first-run download — both of which reuse the resolver's "imported" branch, so the architecture does not change. |
| Face-model licence ships in the binary | Documented in README next to the build step; `PACK_VARIANT=tagging` is the switch. Not a code change when it matters. |
| A fresh clone can't build | `prepare_pack.sh` fails loudly with the exact command to run. The alternative — a silently pack-less app — is what we have today. |
| Pack and app versions drift | The manifest's `pack_version` is already recorded on every result and drives `mark_stale_for_pack`; bundling changes nothing about that. |
| `cp -c` on a non-APFS volume | Falls back to a real copy; the script should not assume clonefile, only prefer it. |
