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

`MemoryGenerationInputs` carries four fields the sketch did not anticipate, all
of them consequences of the review below: `photoTimeZoneOffsets` (per-photo UTC
offsets — Finding R2), `folderPlaceholderPhotos` +
`folderPlaceholderTimeZoneOffsets` (the cloud placeholders the coordinator
filters out, which the folder-event ladder still has to see — Finding R1), and
**not** `contactsByLowerName`, which the engine now derives from `contacts`
itself.

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
| ↳ *of which on the main actor* | all of it | the `[UUID: PhotoFile]` table build only; marshalling and id resolution moved off in R-S3 |
| Scheduled-memories horizon (7 days) | ~9 s, **main thread** | 61–144 ms, **off main** |
| Search query, 20k | n/a | 3–50 ms cold, ~0.001 ms warm |
| Main-thread FFI in scroll/search | — | none (`sample`, 12 s: only the synchronous `photoByID` table build, ~0.1% of samples) |

The index-build wall clock did not drop below the 0.3 s gate, and that is the
honest result: the core's own work is **2× faster** than the Swift index
(130–303 ms vs 250–300 ms) but the port adds two costs the Swift never paid —
marshalling 20k photos into `ScanPhoto` records and resolving 20k ids back to
`PhotoFile`s. What the gate was protecting (a stalled first frame after every
scan) is met by a wider margin than the number suggests, because the wall clock
is off the main thread.

*Corrected after review (R-S3):* when this table was first written, those two
costs were **not** off it — the marshalling ran before the detached hop and the
id resolution after it, so 14–22 ms plus a 20k-entry dictionary walk were still
main-actor work on every rebuild, and the same was true of
`CoreMemories.record(from:)` on the horizon path. Both now happen inside the
detached task. What remains on the main actor is the `[UUID: PhotoFile]` table
build, deliberately: `photo(byID:)` must not lag `allPhotos`. Shrinking the wall clock further means shrinking
the marshalling, not the algorithm — the next lever is handing the core the
photos once and mutating deltas, which is `set_photos(batch)` from the sketch
above, and it is not worth doing until something needs it.

## Risks

| Risk | Mitigation |
|---|---|
| Jitter/RNG mismatch breaks id parity | SeededRNG ported first with its own vectors; jitter fixtures before ladder port |
| Subtle scoring drift (float vs Double) | Score ladder uses the same f64 ops in the same order; fixtures assert scores, not just selections, on edge cases |
| Search semantics regressions (diacritics, case) | Query fixtures generated from current behavior including Unicode cases |
| FFI latency on search-as-you-type | Query calls are single-batch and unpaged; **not** off-main, because they are called from `View` bodies where an `async` hop would flash empty results — instead they are memoised **from one publish to the next**, so a repeated body evaluation crosses the boundary zero times. Measured in acceptance. |
| Timezone regressions | Keep the UTC-fixture discipline; add one non-UTC calendar fixture per memory type. **The fixtures cannot reach DST** — both fixture zones are fixed-offset — so per-photo offsets are guarded by Rust unit tests instead (see R2 below). |

## Review findings, and what changed

Two skeptical reviews of the shipped swap. Everything below is fixed; the
fixtures stayed green throughout and none was regenerated.

### Bridge

- **R-S1 Query memos outlived the rebuild they were taken during.**
  `tagPhotoCache` / `searchCache` were cleared when a rebuild *started*, which
  left the whole core-build window open: `photoByID` already held the new
  library while the core still held the old one, so a query in between resolved
  stale ids against a fresh table, got nothing, and cached that nothing *after*
  the clear. Blank `PersonCard`s until the next rescan. They are now dropped
  inside the publish block, in the same main-actor turn as the new arrays.
  (`CoreLibraryBridgeTests.testAQueryDuringARebuildDoesNotSurviveThePublish`)
- **R-S2 Overlapping rebuilds could leave the core one generation behind.**
  The generation counter guards the *publish*; it cannot order the core's own
  index swap, which happens when each build finishes. A slow stale build
  finishing after a fast fresh one left the app rendering one library and
  querying another. Core builds are now serialised — each rebuild awaits the
  previous one before calling in — so last-started is last-swapped.
  (`…testAStaleRebuildCannotPublishOverAFreshOne`, extended to assert `search`
  and `photosForTag`, plus `…testTheLastStartedRebuildIsAlwaysTheOneTheCoreHolds`)
- **R-S3 Marshalling and id resolution ran on the main actor.** The
  `allPhotos.map(CoreScanner.record(of:))` (14–22 ms at 20k) happened *before*
  the detached hop, and the 20k `UUID(uuidString:)` parses plus dictionary hits
  happened *after* it. Both moved inside; the hop now returns a `Sendable`
  `Built` of app types, because UniFFI's records are not `Sendable` and passing
  the summary out was what forced the resolution back onto the main actor. The
  table's `[UUID: PhotoFile]` copy is still built synchronously — `photo(byID:)`
  must not lag `allPhotos`. `CoreMemories` got the same treatment: `record(from:)`
  now runs inside the detached task rather than on the caller's actor.
- **R-S4 Cold-launch "No photos match." flash.** `sortedPhotos` is empty both
  before the first publish and for an empty library, and `AllPhotosView` could
  not tell those apart, so a warm-cache launch rendered `PhotoGridScreen`'s
  *filter* empty-state over a full library for the length of the first build.
  `CoreLibraryIndex.hasEverPublished` (surfaced as `store.hasSortedPhotos`) now
  gates it; the view shows a spinner until the first publish. Rendering
  `allPhotos` unsorted was rejected: the grid would visibly reshuffle when the
  sort landed. (`…testTheIndexSaysWhetherItHasPublishedYet`)
- **R-S5 `scheduledInputs` subset is now fenced.** It deliberately omits
  `seed`, `leafFolders`, the seen/cool-down maps and `mePersonPath`; only the
  last is read anywhere in the engine (trip titles), and nothing enforced that
  the horizon never grows a use for it.
  `…testTheScheduledInputsSubsetIsSafeToOmitMePersonPath` runs the horizon with
  and without it and fails if they diverge.
- **R-S6 / R-S7 Doc drift.** The bridge reads `Calendar.current.timeZone`, not
  `TimeZone.current` (the latter is cached and ignores an `NSTimeZone.default`
  override, which would silently run the Tokyo scenario in UTC); two comments
  claimed otherwise. `settle()` claimed `runScheduledMemoryRefresh` waits on it
  — nothing does, and nothing should.

### Engine

- **R-R1 Folder events silently dropped cloud placeholders.** The port resolved
  `folder.photo_ids` through `inputs.photos`, which `MemoryCoordinator` had
  already filtered; the deleted Swift read `folder.photos`, the folder's own
  unfiltered array. A placeholder-heavy folder fell below the 15-photo floor and
  vanished, and a surviving one came back with a different photo list, cover and
  subtitle under the same `folder-<id>` id. `GenerationInputs` now carries the
  placeholders as a tail on the photo table with `ladder_photo_count` marking
  where the scored pool ends; **only** the folder-event stage looks past it.
  (Rust: `a_folder_event_counts_its_cloud_placeholders_exactly_as_the_swift_did`,
  `withholding_the_placeholders_deletes_the_folder_event_entirely`,
  `placeholders_stay_out_of_every_other_ladder`. Swift:
  `…testAFolderEventKeepsItsCloudPlaceholders` and the coordinator-level
  `…testTheCoordinatorRoutesPlaceholdersToTheFolderLadder`.)
- **R-R2 One UTC offset for all of history.** `time.rs` resolved the offset once
  at `now`. For a DST user that means a July photo buckets on a different local
  day depending on which season the generation runs in — `density-*` and
  `trip-*` ids, and therefore cluster keys, flip twice a year, so the seen (−30)
  and cool-down (−25) penalties stop matching the history the user's own taps
  wrote. `time::Zone` now carries a per-photo offset table: **photo bucketing
  uses the photo's offset, today/horizon math uses `now`'s**. Swift computes
  them with `Calendar.current.timeZone.secondsFromGMT(for: photo.dateTaken)`
  inside the detached task (~20 ms at 20k). *Honest remainder:* subtitle
  **rendering** still uses the `now` calendar, because `finalize` sees a date
  range and not the photos behind it — a Berlin user reading a July memory in
  January sees a one-hour skew in the printed date on two days a year. Fixing
  that means putting offsets on `Memory` itself. (Rust:
  `a_berlin_summer_photo_buckets_the_same_in_january_and_in_july`,
  `a_single_run_offset_moves_a_berlin_density_id_between_seasons`,
  `per_photo_offsets_pin_a_berlin_density_id_across_seasons`.)
- **R-R3 Trip people tiebreak diverged from `localizedCaseInsensitiveCompare`.**
  A lowercased byte compare puts `Émile` after `Eve`, `Özlem` after `Peter` and
  `åsa` after `Bob`; ICU does the opposite, and with equal counts that decides
  which names survive the truncation to three. `text::collation_key` (NFD, strip
  combining marks, lowercase) matches ICU on the probed pairs. *Honest
  remainder:* it is not full ICU collation — no locale tailorings (Swedish sorts
  `å` after `z`), no `ß` → `ss`, non-Latin scripts by code point.
  (`the_people_tiebreak_collates_accented_names_the_way_icu_does`,
  `the_tiebreak_decides_which_names_survive_the_truncation`,
  `a_higher_count_still_beats_the_collation_order`.)
- **R-R4 Quadratic scans.** `dedupe_folder_names` was O(folders²) and the two
  trip counters were a linear `find` per tag occurrence. All three are now
  insertion-ordered `Vec` + `HashMap` index, with the tie semantics pinned
  *first*: `max(by:)` keeps the first maximal element, so a later equal-sized
  duplicate never displaces an earlier one.
  (`same_name_folders_collapse_to_the_biggest_and_ties_keep_the_earlier`,
  `the_dedupe_preserves_candidate_order_and_ignores_other_kinds`.)
- **R-R5 `format_day` did not pad the year.** ICU's `yyyy` is a padded field, so
  a photo whose EXIF year came back as 875 renders `"Jan 1, 0875"` in the
  shipping app and `"Jan 1, 875"` from a bare `{}`. No fixture goes below year
  2014. (`the_year_is_padded_to_four_digits_the_way_icu_pads_yyyy`.)
- **R-R6 Byte-keyed maps where Swift compared canonically.** Swift's
  `Set<String>` and `Dictionary` hash by canonical equivalence, so a decomposed
  `People/José` tag (what a filename yields on Apple platforms) matched a
  precomposed hidden entry, link or contact name. `PersonKeys` folds all four
  lookups once per generation — `nfc` for tag paths and memory ids (case is part
  of their identity), `match_key` for contact names (Swift lowercased them
  itself). The folder-title dedupe key and the `seen_memory_ids` /
  `surfaced_clusters` maps are folded too: **birthday ids embed the person path**
  (`birthday-People/José`), so those maps were *not* safe, and `cluster_key`
  passes the id through unchanged. `contactsByLowerName` left the wire entirely
  — the engine derives it, so the app's copy and the core's cannot disagree.
  (`a_decomposed_person_tag_matches_a_precomposed_contact`,
  `hiding_a_person_by_either_spelling_hides_both`,
  `a_person_link_matches_across_spellings_too`,
  `folder_titles_dedupe_across_normalisation_forms`.)
- **R-R7 `search`'s tag branch re-normalised every tag, per query.**
  `photo_carries` ran `match_key` — a `to_lowercase` plus an NFC pass, both
  allocating — per photo per query, so a 20k library with three tags each folded
  ~60,000 strings on every keystroke. The keys are precomputed at build time
  into `LibraryIndex::tag_keys`. Deliberately **not** answered from the tag
  buckets: those prefix-expand `objects`/`scenes` as well as `places`, while
  `photo_carries` expands `places` alone, and that asymmetry is pinned Swift
  behaviour (landmines 18/19). (`gallery-index/tests/search_perf.rs`.)

Shared plumbing: the NFC/collation folds live in `gallery_model::text` and
`gallery_index::text` re-exports them, because `gallery-memories` needs the
identical fold and two copies would eventually disagree.

## After Phase 4 — portability checkpoint (not scheduled work)

What a Linux/Android/Mac app needs at this point: a `Vfs` impl, the model
packs, and UI over `Library`/`memories_generate`/`TaggingSession`/
`FaceSession`. Remaining Swift-only conveniences a new app would reimplement:
thumbnails, materialization/cloud, coordinator-level gating, widgets. That
is the intended boundary — revisit moving thumbnails into the core only if
a second app actually needs it.
