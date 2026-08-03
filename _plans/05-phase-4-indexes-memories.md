# Phase 4 — Indexes + MemoryEngine move into the core

Final extraction: `SearchIndex`, `TagIndex`, and `MemoryEngine` (with its
`+Calendar`/`+Birthdays`/`+Trips`/`+Selection` extensions) are ported to
Rust and the Swift copies deleted. After this phase `GalleryStore` is a thin
observable view-model over core results, and a new platform app is
"a UI + a VFS adapter + these FFI calls."

**Exit criterion:** app runs with Swift `MemoryEngine`/`SearchIndex`/
`TagIndex` deleted; the memory-engine conformance suite (derived from the
existing tests) passes identically in `cargo test` and over FFI; generated
memories on a fixture library are id-for-id identical to the last
Swift-engine build given the same clock and seen/cooldown state.

## Non-goals

- `MemoryCoordinator` stays in Swift: the once-per-day gate, epoch
  invalidation, seen/cooldown persistence, hidden set, visibility filtering
  are app-state concerns wired to UserDefaults and the Store. Only the pure
  `generate` (inputs snapshot → `[Memory]`) moves.
- `PeopleStore`, `ContactLinker`, widget export, `AppRouter` — Swift.
- Search *UI* behavior (`PhotoGridScreen` filter pipeline) — unchanged; it
  consumes index query results as today.

## Order of work

### 1. Conformance fixtures from the existing test suites

- `MemoryEngineTests`/`MemoryCoordinatorTests` already use explicit UTC
  calendars and noon-UTC fixtures — export each scenario as JSON:
  `{inputs: {photos, contacts/birthdays, now, seen, cooldowns, jitterSeed},
  expected: [memories: id, type, photoIds, cover, subtitle]}`.
  The daily jitter (0–12) must be driven by the same seeded RNG — port
  `SeededRNG` (in `Shared/`) to Rust with its own conformance vectors so
  jitter is reproducible cross-language.
- Score-ladder edge fixtures: birthday vs onThisDay collisions, trip parent
  + subtrip cluster uniqueness, the 75-photo `finalize` cap with cover
  re-pointing, date-qualified calendar ids (`onThisDay-2024-06-11`),
  scheduled-days pre-publish parity (`computeScheduledMemories` — same
  `finalize` path, ids must match when the day arrives).

### 2. `gallery-memories`

- Direct port of the engine files; keep the extension-file structure as
  Rust modules (`calendar.rs`, `birthdays.rs`, `trips.rs`, `selection.rs`)
  so the score-ladder documentation in CLAUDE.md still maps to code.
- Clock stays an input (`now: i64` + tz/calendar parameter — the engine
  already takes an explicit calendar; port with explicit UTC-offset
  semantics, fixtures enforce timezone robustness).
- `generate` runs on a core thread with cancellation observed between
  ladder stages (parity with the `withTaskCancellationHandler` forwarding
  in Swift today).

### 3. `gallery-index`

- Sorted photo list: date desc, **URL-path tiebreak** (byte-wise compare on
  the same strings Swift compares — fixture with equal-date photos pins the
  order so rescans don't shuffle the grid).
- `TagIndex`: port as `HashMap<String, Vec<PhotoId>>` + shared photo table
  — i.e., take the known follow-up ("TagIndex stores full PhotoFile copies
  per bucket") as part of the port rather than replicating the memory
  waste. This is the one sanctioned behavior *improvement* in the phase;
  it's invisible to callers.
- Search corpus build + query: port matching semantics exactly (fixtures:
  query → expected photo id list, generated from current Swift).
- Async tag aggregation: core-side worker, results delivered as one batch
  per rebuild (feeds the existing `TagGridView`/suggestions via the same
  Store properties).

### 4. FFI + Swift swap

```
library_open(snapshot_path, cache_db_path) -> Library      // owns photos + indexes
library.set_photos(batch)            // called from apply(_:) after scans
library.search(query, page) -> [PhotoId]
library.tag_photos(tag_path, page) -> [PhotoId]
library.tag_suggestions() -> [TagSuggestion]
memories_generate(inputs) -> [Memory]                      // pure; Coordinator calls it
```

- `MemoryCoordinator.makeInputs` now serializes its snapshot into the FFI
  input record — the existing "engine inputs are snapshotted via a closure"
  design maps 1:1.
- Delete `MemoryEngine*.swift`, `SearchIndex.swift`, `TagIndex.swift` and
  their unit tests (conformance fixtures replace them; coordinator tests
  stay in Swift and now exercise the FFI engine underneath).

## Testing / acceptance

- [ ] Every exported fixture green in `cargo test` and via FFI in
      `LocalGalleryTests` (Swift Testing suites kept as harnesses over the
      fixtures).
- [ ] Same-day parity run: fixture library + fixed clock + persisted
      seen/cooldown state → Rust engine emits identical memory ids,
      photo lists, covers, subtitles to the recorded Swift baseline.
- [ ] Widget scheduled-days parity: pre-published day N memory id equals
      the id generated live on day N (the finalize-path invariant).
- [ ] Search/tag query latency on the 10k library ≤ Swift baseline;
      TagIndex memory footprint measured (expect large win).
- [ ] Grid-order stability: rescan of unchanged library produces
      byte-identical sorted id list.

## Risks

| Risk | Mitigation |
|---|---|
| Jitter/RNG mismatch breaks id parity | SeededRNG ported first with its own vectors; jitter fixtures before ladder port |
| Subtle scoring drift (float vs Double) | Score ladder uses the same f64 ops in the same order; fixtures assert scores, not just selections, on edge cases |
| Search semantics regressions (diacritics, case) | Query fixtures generated from current behavior including Unicode cases |
| FFI latency on search-as-you-type | Query calls are single-batch, off-main; measured in acceptance; page results |
| Timezone regressions | Keep the UTC-fixture discipline; add one non-UTC calendar fixture per memory type |

## After Phase 4 — portability checkpoint (not scheduled work)

What a Linux/Android/Mac app needs at this point: a `Vfs` impl, the model
packs, and UI over `Library`/`memories_generate`/`TaggingSession`/
`FaceSession`. Remaining Swift-only conveniences a new app would reimplement:
thumbnails, materialization/cloud, coordinator-level gating, widgets. That
is the intended boundary — revisit moving thumbnails into the core only if
a second app actually needs it.
