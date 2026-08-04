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

Planned shape:

```
library_open(snapshot_path, cache_db_path) -> Library      // owns photos + indexes
library.set_photos(batch)            // called from apply(_:) after scans
library.search(query, page) -> [PhotoId]
library.tag_photos(tag_path, page) -> [PhotoId]
library.tag_suggestions() -> [TagSuggestion]
memories_generate(inputs) -> [Memory]                      // pure; Coordinator calls it
```

**As shipped** (`core/gallery-ffi/src/library.rs`, `LocalGallery/Services/
CoreLibraryIndex.swift`, `LocalGallery/Services/CoreMemories.swift`):

```
LibraryIndex()                                       // no paths — see below
  .build(photos: [ScanPhoto]) -> LibraryIndexSummary // sortedPhotoIds + tags + people + buildMillis
  .search(query:requiredTagPaths:) -> [String]
  .photoIdsForTag(fullPath:)        -> [String]
  .tagSuggestions()                 -> LibraryTagSuggestions
  .photoCount()                     -> UInt64
generateMemories(inputs:)                        -> [MemoryRecord]
MemoryGenerator().generate(inputs:) / .cancel()   // same, with a cancel flag
computeScheduledMemories(inputs:horizonDays:hiddenMemoryIds:) -> [ScheduledMemoryRecord]
scheduledMemoryHorizonDays() / memoryClusterKey(memoryId:) / memoryCountryName(code:)
```

Four deviations from the sketch, each deliberate:

1. **No `library_open(snapshot_path, cache_db_path)`.** The index is a pure
   function of `allPhotos` and is rebuilt on every `apply(_:)`; giving it a
   snapshot path would have made it a second owner of a file `gallery-scan`
   already owns, and a second cache to invalidate. `build` replaces the whole
   table, which is what `set_photos(batch)` would have had to do anyway.
2. **Queries answer in ids, not pages.** Paging was in the sketch to keep the
   boundary cheap; measurement says it is not needed (worst case below), and
   an unpaged answer is what the callers — which hand a whole `[PhotoFile]` to
   a `LazyVGrid` — actually want. The app resolves ids through its own
   `photoByID`; no `PhotoFile` crosses back.
3. **`search` takes no `allTags`.** The Swift signature required the caller to
   pass the aggregated list; an empty or stale one silently degraded every tag
   query — including the *virtual* `Places/…` prefixes no photo carries — to a
   substring match. The core holds its own list.
4. **`MemoryGenerator` is an object.** `generateMemories` is a free function,
   but a generation that a background task can cancel needs a flag the Swift
   `withTaskCancellationHandler` can reach, and UniFFI has no other way to
   hand one out.

- `MemoryCoordinator.makeInputs` serializes its snapshot into the FFI input
  record — the "engine inputs are snapshotted via a closure" design mapped 1:1,
  minus `contactsByLowerName`, which the core now derives from `contacts` the
  way `ContactLinker.index` does. Passing both would let the two disagree
  across the boundary.
- Deleted: `MemoryEngine.swift` + `+Birthdays` / `+Calendar` / `+Selection` /
  `+Trips`, `SearchIndex.swift`, `TagIndex.swift`, and the four
  `MemoryEngine*Tests` suites. `SeededRNG` **stays** in `Shared/` — the widget
  extension uses it for rotation and does not link the core.
- Kept and rewired rather than deleted: `SortPhotosTests`, `SearchQueryTests`,
  `RequiredTagsTests`, `MemoryCoordinatorTests` — they assert behaviour, not
  internals, and now drive `CoreLibraryIndex` / `CoreMemories`.

## Testing / acceptance

- [x] Every exported fixture green in `cargo test` and via FFI in
      `LocalGalleryTests` (the four conformance harnesses — memory engine,
      scheduled memories, search index, tag index — were rewired to the FFI
      path with **every assertion untouched**; a green run is the parity
      proof, since the Swift they were generated from no longer exists).
- [x] Same-day parity run: fixture library + fixed clock + persisted
      seen/cooldown state → Rust engine emits identical memory ids,
      photo lists, covers, subtitles to the recorded Swift baseline.
      (`memory_engine.json`, 20 scenarios.)
- [x] Widget scheduled-days parity: pre-published day N memory id equals
      the id generated live on day N (the finalize-path invariant).
      (`scheduled_memories.json`, plus a live-run comparison in
      `CoreLibraryBridgeTests`.)
- [x] Search/tag query latency measured on a 20k library (the 10k target was
      raised to match the perf-baseline library): cold 3–50 ms per query
      end-to-end including id resolution, warm ~0.001 ms through the Swift
      memo. `TagIndex`'s per-bucket `PhotoFile` copies are gone — the core
      stores indices into one photo table.
- [x] Grid-order stability: `IndexConformanceTests.testRebuildIsStable`
      asserts two builds of the same library produce identical dumps, and
      the sorted id list is pinned by `search_index.json`.

### Measured, 20k-photo Release build on the simulator (2026-08-04)

| | baseline (`_plans/06`) | after Phase 4 |
|---|---|---|
| Index build (sort + corpus + tags) | 0.25–0.3 s, **main thread** | 357–419 ms end to end, **off main** — of which 14–22 ms marshalling in and 130–303 ms inside the core |
| Scheduled-memories horizon (7 days) | ~9 s, **main thread** | 61–144 ms, **off main** |
| Search query, 20k | n/a | 3–50 ms cold, ~0.001 ms warm |
| Main-thread FFI in scroll/search | — | none (`sample`, 12 s: only the synchronous `photoByID` table build, ~0.1% of samples) |

The index-build wall clock did not drop below the 0.3 s gate, and that is the
honest result: the core's own work is **2× faster** than the Swift index
(130–303 ms vs 250–300 ms) but the port adds two costs the Swift never paid —
marshalling 20k photos into `ScanPhoto` records and resolving 20k ids back to
`PhotoFile`s. What the gate was protecting (a stalled first frame after every
scan) is met by a wider margin than the number suggests, because none of it is
on the main thread any more. Shrinking the wall clock further means shrinking
the marshalling, not the algorithm — the next lever is handing the core the
photos once and mutating deltas, which is `set_photos(batch)` from the sketch
above, and it is not worth doing until something needs it.

## Risks

| Risk | Mitigation |
|---|---|
| Jitter/RNG mismatch breaks id parity | SeededRNG ported first with its own vectors; jitter fixtures before ladder port |
| Subtle scoring drift (float vs Double) | Score ladder uses the same f64 ops in the same order; fixtures assert scores, not just selections, on edge cases |
| Search semantics regressions (diacritics, case) | Query fixtures generated from current behavior including Unicode cases |
| FFI latency on search-as-you-type | Query calls are single-batch and unpaged; **not** off-main, because they are called from `View` bodies where an `async` hop would flash empty results — instead they are memoised per rebuild, so a repeated body evaluation crosses the boundary zero times. Measured in acceptance. |
| Timezone regressions | Keep the UTC-fixture discipline; add one non-UTC calendar fixture per memory type |

## After Phase 4 — portability checkpoint (not scheduled work)

What a Linux/Android/Mac app needs at this point: a `Vfs` impl, the model
packs, and UI over `Library`/`memories_generate`/`TaggingSession`/
`FaceSession`. Remaining Swift-only conveniences a new app would reimplement:
thumbnails, materialization/cloud, coordinator-level gating, widgets. That
is the intended boundary — revisit moving thumbnails into the core only if
a second app actually needs it.
