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

## Results after Phase 3 step 5 (measured 2026-08-04)

Same simulator, same generator invocation, same `Scan totals` line. Findings 1
and 2 are **closed**; Finding 3 is untouched and still owned by Phase 4.

> **Finding 3 closed by Phase 4** (measured 2026-08-04, Release, same 20k
> library). The scheduled-memories pass is **61–144 ms and off the main
> actor** — `sample` over a 12 s launch window shows no `computeScheduled` or
> `uniffi` frames on the main thread. The `OnThisDay (…)` per-day log burst
> this section measured from no longer exists (the core does not log); the
> replacement line is `Scheduled horizon: N items over 7 days in …ms` from
> `GalleryStore.exportWidgetSnapshot`. Index build over the same library is
> 357–419 ms end to end (core: 130–303 ms), also off the main actor — see
> `_plans/05` for why the wall clock did not drop below the 0.3 s gate even
> though the algorithm got faster.
>
> *Amended after the Phase-4 review (`_plans/05`, R-S3).* "Off the main actor"
> was true of the measured span and not of the whole call: the marshalling into
> `ScanPhoto` records ran **before** the detached hop and the id resolution
> **after** it on the index path, and `CoreMemories.record(from:)` ran on the
> caller's actor on the horizon path. Neither showed up as `computeScheduled`
> or `uniffi` frames, which is why the `sample` evidence above missed them.
> Both are inside the detached task now; the only main-actor work left in a
> rebuild is the `[UUID: PhotoFile]` table build, which is deliberate.

| Scenario | Baseline | Now | Gate | |
|---|---|---|---|---|
| Cold full scan, 20k files | **406 s** | **2.3 s** | ≤ 60 s | ✅ 177× |
| Light rescan, zero changes | **259 s** | **0.83 s** | ≤ 10 s | ✅ |
| Relaunch light scan | 259 s | **0.79 s**, `probe=0ms probed=0 batches=0` | seconds, probe ≈ 0 | ✅ |
| "Reload Library" (two-phase) | — | 0.79 s light pre-pass + **1.23 s** full pass | — | |
| FFI record marshalling, 20k | — | `in=50ms out=64ms` | — | not the bottleneck |

**Read Finding 1's fix direction below with the correction that follows it: the
fan-out it proposed does not work, and the reason is worth more than the
prediction was.**

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

### Correction — the fan-out was the wrong fix, and the right one was smaller

Fix direction 1 was implemented as specified (bounded fan-out, deterministic
positional emission) and **measured to make things worse**:

| probe strategy | cold scan, 20k |
|---|---|
| serial, 7 keys (baseline) | 406 s |
| 16-way fan-out, 7 keys | **512 s** |
| 16-way fan-out + per-directory `contentsOfDirectory` prefetch, 7 keys | **582 s** |
| 4 cheap keys only (fan-out irrelevant) | **2.3 s** |

`sample` during the 512 s run showed all 16 threads parked in `mach_msg2_trap`
inside `resourceValues`, and the arithmetic settles it: per-probe latency went
from ~11 ms to ~220 ms — exactly 16× plus contention. Throughput was flat, so
the round trip is serialised somewhere the thread count cannot reach. Fix
direction 2's prefetch experiment was run too and is also a dead end: the
`contentsOfDirectory` cache does not serve the ubiquitous keys either, and the
prefetch call itself costs.

What worked was asking for **less**, not asking in parallel. Of the seven keys
`FileProviderDetector.probe` reads, only three go to `fileproviderd`:
`isUbiquitousItem`, `ubiquitousItemDownloadingStatus`,
`ubiquitousItemIsDownloading`. The other four (`fileSize`, `totalFileSize`,
`contentModificationDate`, `fileContentIdentifier`) are a stat. The scanner now
resolves once per scan whether the tree is ubiquitous at all — one probe — and
on a non-iCloud tree reads only the cheap four. Placeholder detection survives
because `totalFileSize > fileSize` is the branch every non-Apple provider
already took; what is given up is iCloud's `.downloading` / `.stale`
distinctions, which nothing in the app reads and which the core already
collapses into `placeholder`.

The 20k fixture library is not ubiquitous, so **all 36,999 of those probes were
asking a plain local file whether it was in the cloud**. 403 of the baseline's
406 seconds bought exactly one bit of information, and it was always the same
bit.

On a genuinely ubiquitous library nothing changes: the full seven-key read
happens as before and the scan is as slow as it always was. Making *that* case
fast needs the placeholder bit to come from `stat` (`st_blocks == 0 &&
st_size > 0`) rather than from Foundation, which is a real behaviour change and
is deliberately not in this phase.

### Correction 2 — where the one probe is taken, and what "I could not tell" means

Two details of that once-per-scan probe were wrong on the first pass, and both
lean the same way: towards being fast at the cost of being right.

It was resolved lazily, from the **parent directory of the first probe batch**.
Which directory that is depends on traversal order and on which files a light
scan decided to rebuild — an implementation detail deciding a library-wide
policy. It is now resolved from the scan **root**, once, before any batch runs
(`CoreProviderProbe.resolveTreeKind(root:)`).

And a *thrown* `resourceValues` was folded into `false` — the same answer a
genuinely local folder gives. A read can throw for reasons that are not "this
is local storage": a permission blip, a provider that has not mounted, a
security-scoped bookmark whose scope was not started. Any of those switched the
whole library to the cheap probe, and then every undownloaded photo read as
`.local` — no cloud badge, `ensureMaterialized` never fires, an empty frame in
the viewer. It now **fails closed**: a thrown read means read all seven keys.
Of the two failure modes, being slow is the one that recovers on its own.

**A read that succeeds with the key absent is the opposite case, and the
distinction is load-bearing.** Measured on the simulator: on iOS,
`resourceValues(forKeys:)` for the ubiquitous keys *never throws* and reports
`isUbiquitousItem == nil` for everything outside iCloud Drive — a plain local
directory answers `nil`, not `false`. That absence is the ordinary case and the
entire source of the saving above. Folding it into "unknown" as well would send
every scan down the seven-key path and undo 406 s → 2.3 s completely. The rule
is one function, `CoreProviderProbe.treeIsUbiquitous(_:)`, with a test on each
branch, because getting it backwards is invisible in every other observable.

The saving is therefore unaffected by the fix — it comes from local trees,
where the read succeeds and the key is absent.

**Still open, deliberately:** one answer covers the whole tree, so a *mixed*
library (local root, iCloud folder inside it) gives the ubiquitous subtree the
cheap probe. Placeholders there are still found through
`totalFileSize > fileSize`; the `.downloading` / `.stale` distinction is lost,
and nothing in the app reads it. The fix is a per-directory answer — one extra
`resourceValues` per directory, which is cheap but is a change to this section's
cost model, so it waits for Phase 4.

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

### Closed as specified

Landed exactly as described — optional field, no version bump, seeded in
`loadCache()` before `restoreFolder`'s `.auto` scan. Measured on relaunch:

    Loaded 20000 photos and 16999 sidecar rows from cache v20
    Scan totals: 20000 files in 97 folders, total=794ms … probe=0ms probed=0
                 batches=0 hits=20000 slow=0 reuseCached=true

One wrinkle the sketch did not cover: the scan pipeline's "no changes" branch
does not call `apply(_:)`, so it never reached `saveCache()`. The first pass
after an upgrade changes the manifest and *nothing else* — so without an
explicit write the fix would have lived in memory only and every launch would
have gone on re-probing. `runScanPass` now compares the manifest across the
pass and calls `persistLibraryCache()` on that branch.

Two further wrinkles came out of the post-port review, both of which put a
library back on the slow path this finding exists to leave:

- **`[]` was persisted as `nil`.** `saveCache()` folded an empty manifest into
  the absent case, and `nil` means "written by a build from before this field
  existed" — worth one legacy re-probe of the whole library. For anyone not
  using digiKam, `[]` is the *permanent* state, so those libraries re-probed on
  every launch forever to rediscover a fact they had already written down. The
  coercion is gone; `[]` round-trips as `[]`.
- **`ContentVersion.size` recorded the on-disk size.** The Swift baseline wrote
  `totalFileSize ?? fileSize`, which differ for exactly one kind of file and it
  is the kind that matters: a placeholder, whose `st_size` is a stub. This
  field is what the sidecar cache diffs on, so the stub made every placeholder
  `.xmp` look changed on the first scan after the upgrade — and re-fetch.
  `ProviderAttrs` now carries `intended_size` across the boundary and the
  manifest row prefers it.

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
