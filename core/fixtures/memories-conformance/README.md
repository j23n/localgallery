# Phase-4 memories / indexes conformance fixtures

The spec for `_plans/05-phase-4-indexes-memories.md` §1. Everything here was
generated from the **shipping Swift** `SeededRNG`, `MemoryEngine`,
`GalleryStore.computeScheduledMemories`, `SearchIndex` and `TagIndex` before
any of them was ported, so the Rust implementation can be checked against
something other than opinion. Where the Swift behaviour is buggy, the bug is
pinned — fixing it is a separate, deliberate change.

One copy in the repo, two readers:

| reader | how |
|---|---|
| `LocalGalleryTests` (simulator) | this directory is a folder reference in `project.yml`, bundled verbatim |
| `cargo test` (host) | `core/gallery-model/tests/memories_conformance_fixtures.rs`, read by relative path |

Same arrangement as `scan-conformance/`, `stable_uuid_vectors.json` and
`expected_tags.json`. Duplicating expectations per language puts nothing on the
line.

## Contents

| file | pins | produced by |
|---|---|---|
| `seeded_rng.json` | 8 seeds × 8 draws: FNV-1a → SplitMix64 vectors, the daily-jitter draws, the day-seed construction | `SeededRNGConformanceTests` |
| `memory_engine.json` | 15 `MemoryEngine.generate` scenarios: inputs snapshot → selected memories | `MemoryEngineConformanceTests` |
| `scheduled_memories.json` | 4 scenarios of the widget's 7-day pre-publish horizon + the day-N parity check | `ScheduledMemoriesConformanceTests` |
| `search_index.json` | 16 photos: the sorted order, the corpus, 16 query → result-list cases | `IndexConformanceTests` |
| `tag_index.json` | 15 buckets: tag → photos, canonical spellings, `TagSuggestion` aggregation | `IndexConformanceTests` |

Tests that read them:

- `LocalGalleryTests/Unit/SeededRNGConformanceTests.swift`
- `LocalGalleryTests/Unit/MemoryEngineConformanceTests.swift`
- `LocalGalleryTests/Unit/ScheduledMemoriesConformanceTests.swift`
- `LocalGalleryTests/Unit/IndexConformanceTests.swift`
- `core/gallery-model/tests/memories_conformance_fixtures.rs` — shape,
  invariants, landmine guard rails, **and a real Rust `SeededRNG` checked
  against the vectors**

Shared plumbing: `LocalGalleryTests/Support/MemoriesConformance.swift` (record
types, the UTC date helpers, the process time-zone override) on top of
`ConformanceFixtures` (the Phase-3 assert/regenerate mechanism, now
parameterised by fixture directory).

## Regenerating

The expectation files are written **by the tests**, from the live
implementation. Nothing here is hand-edited.

```sh
# 1. rerun xcodegen if you added a test file
xcodegen

# 2. regenerate — this run FAILS on purpose: it writes the new files into the
#    repo, and the assertion still compares against the copy already inside the
#    built test bundle.
TEST_RUNNER_CONFORMANCE_REGEN=1 xcodebuild test \
  -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:LocalGalleryTests/SeededRNGConformanceTests \
  -only-testing:LocalGalleryTests/MemoryEngineConformanceTests \
  -only-testing:LocalGalleryTests/ScheduledMemoriesConformanceTests \
  -only-testing:LocalGalleryTests/IndexConformanceTests

# 3. run it again without the flag — now it must be green
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"

# 4. and the Rust side
cd core && cargo test --workspace
```

`xcodebuild` only forwards host environment variables carrying the
`TEST_RUNNER_` prefix, which it strips — hence the odd spelling.

The rules from `ConformanceFixtures` apply unchanged:

- **A mismatch never rewrites the fixture.** Only `CONFORMANCE_REGEN=1` (or a
  missing file) writes. Auto-healing on mismatch would make the suite go red
  once and green forever after.
- Every dump is echoed to stdout between `===BEGIN <name>===` / `===END <name>===`
  and written to the simulator's temp dir, so it survives a sandbox refusal.
- All five files are canonical (`.sortedKeys`, `.prettyPrinted`,
  `.withoutEscapingSlashes`, trailing newline) and a test enforces it, so a
  regeneration is a readable diff.

## The `notes` fields are part of the fixture

Every scenario carries a `notes` array that is compared like any other field,
and the Rust harness fails if one goes empty. The notes live in the test
sources and survive regeneration. They are the only place several of these
behaviours are written down; deleting one is a test failure, not a cleanup.

## Environment: this fixture has a locale

`memory_engine.json` and `scheduled_memories.json` carry an `environment`
block, and it is **`en_US`**.

`MemoryEngine.subtitleWithCount` formats its date range with
`DateFormatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")`, and
`MemoryEngine.countryName(from:)` is
`Locale.current.localizedString(forRegionCode:)`. Both are ICU. So
`"Jun 11, 2019 · 12 photos"` and `"Argentina & Chile with Anna & Ben"` are
**localised strings that the fixture pins**, and a run under a different
locale fails on them.

That is the intended signal, not an accident: the port has to answer the
locale question explicitly (bundle ICU? take the formatted strings from the
platform? move subtitle composition to the UI layer?) rather than inherit an
answer silently. Whatever it decides, `en_US` output must still be
reproducible or this fixture cannot be used.

The **calendar** is not an input the engine takes — see landmine 1.

## What a port must implement first

In order, because each depends on the one before it:

1. `seeded_rng.json` — the generator, the FNV-1a seeding, **and Swift's
   `Double.random(in:using:)`**, whose formula is recorded in
   `algorithm.jitterFormula` and verified by a Rust implementation in
   `memories_conformance_fixtures.rs`. Every memory the engine selects depends
   on it.
2. `search_index.json` / `tag_index.json` — pure functions of `allPhotos`, no
   clock, no RNG.
3. `memory_engine.json` — the ladder, then the penalties, then selection.
4. `scheduled_memories.json` — reuses the calendar generators and `finalize`.

## The landmines, in one place

Everything below is **pinned as-is**. A Rust implementation that "fixes" any of
it diverges from the shipped app.

### Time, calendars and ids

1. **`MemoryEngine.generate` does not take a calendar.** It reads
   `Calendar.current` — despite the sub-generators (`generateOnThisDay`,
   `generateYearsAgo`, `generateBirthdayMemories`, `flushTrip`) all taking one
   as a parameter. The plan's claim that "the engine already takes an explicit
   calendar" is true of the parts and false of the whole. The fixtures
   therefore record a `timeZone` per scenario and the Swift harness moves the
   *process* (`NSTimeZone.default`) to produce them. In Rust this becomes an
   explicit input, which is strictly better — but it must be threaded to every
   stage, including the ones that currently read the ambient calendar.
2. **A memory id's date is rendered in GMT; the day it is about is local.**
   `onThisDay-<date>` and `yearsAgo-<n>-<date>` format `day` with an
   `ISO8601DateFormatter` whose time zone defaults to GMT. In the
   `non-utc-timezone-asia-tokyo` scenario the engine correctly selects the
   photos from **June 12 local** and calls the memory
   `onThisDay-2024-06-11`.
3. **…and that makes the widget's pre-published ids wrong in every zone ahead
   of GMT.** `computeScheduledMemories` walks days from
   `Calendar.current.startOfDay(for: now)` — local midnight, which in Tokyo is
   15:00 GMT the *previous* day. `scheduled_memories.json`'s
   `asia-tokyo-horizon` scenario records the consequence: for three of the
   seven horizon days, `scheduledButNotGeneratedLive` is non-empty and
   `matchedIDs` is empty — the pre-published id is one day behind the id the
   app generates live on that day, so **the widget deep link does not
   resolve**. Worse, day +4's pre-published `onThisDay-2024-06-11` and day
   +3's live `onThisDay-2024-06-11` are the *same id with different photos*.
   In UTC (and behind GMT) parity holds and the Swift test asserts it.
   This is a real bug in the shipping app, found by writing this fixture. It is
   pinned rather than fixed: fixing it changes which widget deep links resolve
   and belongs in its own change, ideally as part of the port.
   Birthday ids carry no date and are immune.
4. **The day seed is the local calendar day.** `WidgetDayKey.string(for:)`
   renders `Calendar.current`'s y/m/d, so the same instant seeds differently in
   different zones (`seeded_rng.json` → `daySeeds`). The force-regenerate seed
   is instead `"\(now.timeIntervalSinceReferenceDate)"` — a Swift `Double`
   interpolation, so `"760000000.0"`, with the `.0`.
5. **`density-<y>-<m>-<d>` ids are not zero-padded** (`density-2022-3-5`) while
   the calendar ids are ISO (`onThisDay-2024-06-11`). Trip keys follow the
   density style (`trip-2023-9-1`), and `clusterKey` splits them on `-`, which
   is only unambiguous because every component is numeric.

### Selection and scoring

6. **`Memory.score` is the score before the jitter.** The 0–12 jitter is never
   stored; its only observable effect is the *order* of the selected list. Both
   are pinned: `expected[].score` and the array order. A port that gets the
   ladder right and the RNG wrong fails on order alone — which is the point.
7. **Jitter draws are consumed in candidate-array order**, one per candidate,
   before any sorting. Candidate order is therefore part of the contract: on
   this day, `[onThisDay, yearsAgo…, folderEvents…, density…, trips…,
   birthdays]`, in the order those loops append.
8. **The seen penalty (−30) is keyed by memory id; the cool-down (−25) is keyed
   by cluster.** `trip-parent-seen-penalty-promotes-a-subtrip` shows the first
   flipping a *selection* (a sub-trip takes the cluster its parent lost);
   `trip-cluster-cooldown-penalty` shows the second demoting all three trip
   memories below a folder event whose raw score is lower.
9. **A cluster is claimed by whoever sorts first, and the rest are dropped
   silently.** In `trip-with-subtrips-cluster-uniqueness` two sub-trips are
   generated, scored, and never appear in any output.
10. **Same-name folder memories collapse to the one with the most photos**,
    compared on `title.lowercased()` and *after* `finalize` — so the 75-photo
    cap can change which folder wins. The survivor keeps its own spelling.
11. **`finalize` samples `Int(i × count / 75)`** and re-points the cover only
    when the sampling drops it, to `photoIDs[count / 2]` **of the sampled
    list**. `finalize-caps-at-75-and-repoints-the-cover` uses 151 photos
    precisely because index 75 — the cover — is one of the indices the sampling
    skips. The subtitle counts the capped photos, not the originals.
12. **Undated photos are invisible to every generator except birthdays.**
    Birthday memories are built from `allPhotos`; undated photos sort to the
    *front* (`.distantPast`), the cover is `ids.last`, and the date range spans
    only the dated ones so a single undated photo cannot collapse the subtitle.
13. **`.disabled` and hidden people are checked in that order**: the hidden set
    is consulted before the link, and a `.manual` link beats the name
    auto-match — but the title still uses the **tag's** display name, not the
    contact's (`birthday-People/Dave` → "Happy birthday, Dave", linked to a
    contact called Daniel Nomatch).
14. **Milestones are exactly `[1, 2, 3, 5, 10, 15, 20]`.** Six years ago
    produces nothing. `onThisDay`'s score counts distinct *years*, not photos.
15. **The dedup window is 60 s and runs before every count check**, so
    `minPhotos` is a post-dedup threshold. A 12-frame burst is one photo.

### Indexes

16. **Substring matching is Swift's, i.e. canonical equivalence, not byte
    equality.** The query `"café"` (precomposed) matches a filename stored
    decomposed on disk. A byte-comparing Rust port silently stops finding
    accented names — the single most likely regression in the index port.
    Recorded alongside it: `"cafe"` does *not* match `"café"` (equivalence is
    not folding), and `"istanbul"` *does* match `"İstanbul"`, whose lowercase
    is `i` + U+0307. The mechanism is not documented anywhere; the three cases
    are recorded so the port can be tested against them rather than reasoned
    about.
17. **The corpus is one string per photo**: filename, then `displayName` and
    `fullPath` per tag, joined with `\n` and lowercased. A query is a single
    substring — `"beach italy"` matches a filename, `"italy beach"` matches
    nothing, and no query can ever span two terms.
18. **An exact tag-path query switches branches.** If `query` equals a known
    tag path (from the Store's aggregated list) the search filters by tag
    instead of by substring, and for `Places/*` it also matches everything
    nested underneath. Virtual prefix tags that no photo carries exactly
    (`places/italy/lazio`) are in that list and are queryable.
19. **Prefix expansion is `TagNamespace.matchesByPrefix` only** (places,
    objects, scenes) and only from depth 2, so the bare namespace is never a
    bucket. A photo carrying both a parent and a leaf tag is credited to each
    key exactly once.
20. **`canonicalPath` disagrees with itself by key kind**: for a leaf key the
    *last* spelling written wins; for a virtual prefix key the *first* wins.
21. **The sort tiebreak is `url.path` ascending**, applied to equal dates *and*
    to the undated tail (all `.distantPast`). It exists so a rescan cannot
    reshuffle the grid.

## Nondeterminism found, and what is pinned instead

Three places where the Swift output is not reproducible. In each case the
fixture pins the **observable contract** and says so, rather than recording a
coin flip.

1. **`generateBirthdayMemories` walks a `Dictionary`** (person tag → photo
   bundle), and **the density loop walks a `Dictionary`** (day → photos). Swift
   seeds `Hasher` per process, so the *candidate order* out of those two loops
   varies between runs — and candidate order decides which jitter draw each
   candidate gets, which decides the rail order.
   *Pinned instead:* every scenario in `memory_engine.json` is built so at most
   **one** memory comes out of each of those loops. Scenarios with more than one
   person having a birthday, or more than one qualifying dense day, are
   deliberately absent because they cannot be pinned.
   `MemoryEngineConformanceTests.testScenariosAreOrderStable` re-runs every
   scenario and fails if one stops being reproducible.
   **For the port:** the Rust engine will have a deterministic iteration order
   (`BTreeMap`, or a sort before the jitter). That is a *tightening*, not a
   divergence — but it means the Rust output for a two-birthday day is a
   specific order where the Swift's was arbitrary, and no fixture can say
   whether it is the "right" one.
2. **`TagIndex.aggregateTagsAndPeople` sorts by `count` alone**, with Swift's
   non-stable `sorted`, over a `Dictionary` walk. Equal-count entries come out
   in an unspecified order that varies between processes.
   *Pinned instead:* `tag_index.json` stores the suggestions re-sorted by
   `(count desc, id asc)`, and the Swift harness canonicalises the observed
   output the same way before comparing. The port must reproduce the counts and
   the count-descending grouping; the tie order is free, exactly as it is in
   Swift today. (The UI shows these lists, so "free" here means "the user
   already sees an arbitrary order".)
3. **`tripLabel`'s dominant-country pick is `Dictionary.max(by:)`**, which on a
   tie returns an arbitrary key. It only matters when a tie also clears the 90%
   dominance rule, which cannot happen with two or more countries — so it is
   unreachable today. Left unpinned and noted here in case a port refactors the
   branch.

Not nondeterminism but the same shape of trap: `Memory`'s `==` and `hash` are
**id-only**. Two memories with different photo sets compare equal. The fixtures
compare field by field and never rely on `Memory: Equatable`.

## Floats: compare bit patterns, not decimals

`seeded_rng.json` records every draw twice — as a decimal and as its IEEE-754
bit pattern (`jitter0to12Bits`, `unit0to1Bits`) — because **serde_json 1.0.151
parses at least one of these decimals one ULP low**: `1.9994953124891874`
round-trips through Rust's own `str::parse::<f64>` exactly and through
`serde_json` as `…872`. Rust's native parser is correct; serde_json's is not,
for 17-significant-digit inputs.

One ULP of jitter is enough to swap two candidates whose ladder scores are
equal — which is exactly the situation in `ten-memory-greedy-cutoff`, where
twelve folder events all score 12. So:

- the Rust harness compares **bit patterns**;
- the Swift harness compares the decimals, which `JSONDecoder` round-trips
  exactly;
- any float the port reads out of these fixtures for comparison (`score`, GPS
  coordinates) should be treated the same way, or parsed with
  `str::parse::<f64>` rather than through serde's number type.

Scores in `memory_engine.json` are short decimals (`55`, `30.5`, `18.6`) and
are not affected, but the Rust harness still compares them against computed
expressions (`20.0 + 7.0 * 1.5`) rather than against re-serialised text.

## What the fixtures do *not* pin

Listed so the next person knows these are gaps rather than decisions.

| area | not covered | why |
|---|---|---|
| `MemoryCoordinator` | the daily gate, epoch invalidation, seen/cool-down persistence, the hidden set, `visible` filtering, the cloud-placeholder input filter | stays in Swift (plan non-goal). `inputs.photos` is already past the placeholder filter. |
| trip home detection | the global-median fallback branch (`homeRegions.isEmpty`) | every trip scenario has a real home cluster; the fallback needs a sparse-GPS library of its own |
| `Collection.shuffle` / `Int.random(in:)` | not pinned at all | `MemoryEngine` never uses them; only `WidgetRotation.pickRotation` does, and widgets stay Swift. Swift's integer-range algorithm is a stdlib detail that would break this fixture on a toolchain bump for no benefit. |
| hidden memories | `computeScheduledMemories` filters `memories.hiddenMemories`; no scenario exercises it | hiding from a test store fires `onMemoriesPublished` → the widget exporter → App Group I/O |
| videos | no scenario has `isVideo: true` | the engine has no video branch; the filtering happens upstream |
| cancellation | `Task.isCancelled` checks between ladder stages | not observable from a completed run; the port owns its own cancellation test |
| scale | biggest scenario is 204 photos | Finding 3's `< 100 ms for a 7-day horizon` gate is a benchmark, not a fixture |
