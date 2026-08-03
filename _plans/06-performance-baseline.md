# Performance baseline — 20k-photo library (measured 2026-08-03)

Profiling results from a full pass over the app with the synthetic 20,000-photo
test library. Three concrete bottlenecks, each with a root cause pinned to
code, plus the numbers to beat. Written so the fixes can land either as
Swift patches now or as part of the Rust-core phases — each finding says
which phase owns it and what conformance/acceptance gate it implies.

## Method (reproducible)

- iPhone 17 Pro **simulator**, iOS 26.5, **Release** build.
- Library: `scripts/generate_test_library.py --count 20000 --seed 42`
  (20,000 stills + 16,978 `.xmp` sidecars, 395 MB), installed with
  `--install booted` into Files-app local storage — i.e. a
  **file-provider-backed** folder, same storage class as iCloud/Drive
  folders on device.
- Timings from the app's own `localgallery` log lines
  (`log stream --level debug --predicate 'subsystem == "localgallery"'` —
  info/debug are *not* persisted, `log show` won't have them) plus
  host-side `sample LocalGallery` call graphs.
- Caveat: provider XPC latency and disk speed differ on device (real cloud
  providers are typically *slower* than the simulator's local provider),
  so the shape holds even where absolute numbers shift.

## Baseline numbers

| Scenario | Measured | Verdict |
|---|---|---|
| Cold full scan, 20k files | **406 s** — `probe=403.6 s` (99.4%) | Finding 1 |
| First light rescan after launch, zero changes | **259 s** — `probe=257 s`, `hits=20000 slow=0` | Finding 2 |
| Scheduled-memories widget pass | **~9 s on the main thread**, per launch/scan/tag-rebuild/hide | Finding 3 |
| Warm-launch snapshot restore | 1.3 s decode + 0.25–0.3 s index build | healthy |
| Enrichment, 20k (EXIF + sidecar + regions) | 6.4 s, parallel, off-main | healthy |
| Daily memory generation (off-main) | 1.7 s | healthy |
| Tag aggregation (detached, utility QoS) | ~6.7 s background | healthy |
| Widget export encode | 3.8 s first run (500 thumbs), 0.4 s after | healthy |
| 20k-grid fast scroll / 1.4k folder grid / viewer paging / search | no CPU saturation, no app-code main-thread hotspots; peak RSS 427 MB (NSCache caps working) | healthy — don't regress |

Log lines that carry the numbers: `Scan totals: … probe=…ms hits=… slow=…`,
`Done in …s` (enrichment), `Built: … in …ms` (index), `Generated … memories
in …ms`, `Exported snapshot: … in …ms`.

## Finding 1 — full scan is 99.4% serial file-provider probe

`FileProviderDetector.probe(_:)` (`FileProviderDetector.swift:58`) does one
`url.resourceValues(forKeys:)` with the 7 ubiquitous-item keys = one blocking
XPC round-trip to `fileproviderd`, **~20 ms each, fully serial**, called per
photo (`FolderScanner.swift:318`), per sidecar (`:378`), per video (`:416`)
— ~37k round-trips for this library. `sample` shows the scan thread parked
in `mach_msg2_trap`, not computing: the scan is latency-bound, so the fix is
about round-trips, not work.

**Fix direction (Swift, any time — probing stays Swift-side per the Phase 3
non-goals):**
1. Per folder: collect probe-needing URLs after the classify pass, fan out
   through a bounded `withTaskGroup` (start width 16; benchmark 8/16/32)
   into a `[URL: ProbeResult]`, keep emission serial → deterministic output,
   ~`/width` wall time (406 s → ~30–60 s expected).
2. Secondary experiments: add the probe keys to the
   `contentsOfDirectory(includingPropertiesForKeys:)` prefetch
   (`FolderScanner.swift:160`) — likely a no-op, the prefetch cache is
   already broken for plain stat keys on iOS 26 + security-scoped bookmarks
   (see comment at `FolderScanner.swift:205`) — and a one-time root probe to
   skip per-file probes entirely for non-provider trees.

**Rust-core relevance (Phase 3):** the VFS `list()` is specced to return
`is_placeholder`/`content_version` per entry. If the iOS `Vfs` impl feeds
those from per-URL `resourceValues`, the Rust scanner inherits this exact
serialization. The VFS implementation must batch/parallelize provider
attribute reads (or accept a folder-level "provider-ness" hint) — put a
perf gate in the Phase 3 exit criteria, not just conformance.

**Gate:** full scan of the 20k fixture library ≤ 60 s on the simulator
(from `Scan totals`), light scan unchanged-library ≤ 10 s.

## Finding 2 — sidecar manifest is not persisted; every launch re-pays a ~4-min rescan

Light scan skips the sidecar probe only on `cachedSidecarManifest[photo.id]`
hits (`FolderScanner.swift:374`), but the manifest lives in
`GalleryStore.lastSidecarManifest` (`GalleryStore.swift:111`) — in-memory,
`[]` on launch. First `.auto` scan after every launch re-probes all ~17k
sidecars: 259 s with 20,000/20,000 photo cache hits. Second rescan in the
same session is fast.

**Fix direction (Swift):** persist the manifest with the snapshot —
make `FolderScanner.SidecarCandidate` `Codable`, add
`sidecarManifest: [SidecarCandidate]?` to `LibrarySnapshot` as an
**optional** field, **no version bump** (v20 decodes with `nil`, pays one
legacy re-probe, then persists; a bump would force a 7-min full rescan on
every install). Populate `lastSidecarManifest` during cache load, *before*
`restoreFolder` kicks off the `.auto` scan. Staleness is already guarded:
the fast path requires unchanged photo size+modDate, sidecar sync still
diffs content versions, and deleted sidecars drop out via the directory
listing.

**Rust-core relevance (Phase 3, contract-critical):** Phase 3 freezes
`LibrarySnapshot` JSON as a byte-compatible contract with committed
fixtures. If this field lands first, the fixtures and the Rust
decoder/encoder must include it; if the Rust port lands first, add the field
to the *shared* shape then. Either way: the snapshot fixture in
`04-phase-3-scanner-metadata.md` §1 must be regenerated when this field is
added, and the Rust side must round-trip it losslessly.

**Gate:** app relaunch on an unchanged 20k library → post-launch scan
completes in seconds with `probe=` ≈ 0 in `Scan totals`.

## Finding 3 — scheduled-memories widget pass: ~9 s main-thread stall

Call graph (65% of a 12 s post-launch sample, all on the main actor):

```
rebuildSortAndIndex closure (GalleryStore.swift:549)
→ exportWidgetSnapshot (GalleryStore.swift:610)
  → computeScheduledMemories (GalleryStore.swift:673)   ← ×7 horizon days
    → MemoryEngine.generateBirthdayMemories (MemoryEngine+Birthdays.swift:29)
      → ~all time in _ArrayBuffer._consumeAndCreateNew / PhotoFile copies
```

Runs after every scan completion, tag aggregation, memories-published,
people change. Three compounding causes:

1. **COW-defeating append** — `if var existing = byPath[path] { existing.photos.append(photo); byPath[path] = existing }`
   copies the person's whole `[PhotoFile]` array on *every* append
   (dictionary retains a reference while `existing` mutates) → quadratic in
   photos-per-person; millions of large-struct copies at 20k photos /
   20.5k people-tag instances.
2. **7× regrouping** — the full-library person grouping is day-independent
   but runs inside the 7-day horizon loop.
3. **Main-actor execution** — unlike `MemoryEngine.generate`, which
   snapshots inputs and runs detached.

**Fix direction (Swift, ordered by payoff/size):**
- (a) Group by **indices** (`[String: [Int]]`, in-place
  `byPath[key, default: []].append(i)`), materialize photos only for
  birthday-matching people. Also fixes the same pattern's cost inside the
  daily `MemoryEngine.generate` path.
- (b) **Early-exit**: check whether *any* contact has a birthday on the
  target day before touching photos — the common case is "no birthdays in
  the 7-day horizon", which should cost ~0.
- (c) Hoist grouping out of the day loop and move `computeScheduledMemories`
  off-main (snapshot inputs like `MemoryCoordinator.GenerationInputs`,
  compute detached, generation-counter guard like `tagBuildGeneration`).

**Rust-core relevance (Phase 4):** `MemoryEngine` ports to Rust and the
Swift engine is deleted — the COW bug dies with the port, but **do not
transplant the architecture**: the Rust engine must (i) group people→photos
once per generation call, not per day; (ii) early-exit on no-birthday days;
(iii) be invoked off the main thread with snapshot inputs. Add the 20k
fixture to the Phase 4 benchmarks: scheduled-memories horizon pass for 7
days must complete in < 100 ms in Rust, and the FFI call must never run on
the main thread.

**Gate:** post-launch `sample` shows no `exportWidgetSnapshot` /
`computeScheduledMemories` frames on the main thread; the `OnThisDay (…)`
log burst (7 lines) completes in < 1 s total.

## Do-not-regress list (for both Swift fixes and the Rust port)

- Warm restore: 20k snapshot decode ≈ 1.3 s off-main, index build ≤ 0.3 s.
- Enrichment: 20k in ≤ 10 s, parallel, off-main, cancellation propagates.
- Scrolling: thumbnail decode stays bounded (semaphore 4) with NSCache caps
  (100 MB thumbs / 200 MB full-res); peak RSS stayed ≤ ~430 MB under
  aggressive 20k-grid scrolling. No app-code main-thread hotspots during
  scroll/viewer/search — keep it that way when scanner/indexes move to Rust
  (FFI calls from view code must not appear in scroll-time samples).

## Harness notes

- The 20k library generator is deterministic (`--seed 42`); regenerate and
  reinstall any time (`--install booted`; needs the Files app opened once).
- A temporary headless driver (`LocalGalleryUITests` target +
  `LocalGalleryPerf` scheme, both marked "remove after profiling" in
  `project.yml`) can replay the scenarios: onboarding folder-pick, fast
  scroll, folder browse, viewer paging, search, plus a file-based
  remote-control test for arbitrary taps/swipes when the doc picker or
  ad-hoc flows are involved.
- `ThumbnailService` has **no timing instrumentation**; scroll analysis
  relied on `sample`. If thumbnail perf ever needs regression tracking, add
  a decode-time log/signpost first (there are currently **no os_signpost**s
  anywhere in the app).
