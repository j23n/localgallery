# LocalGallery test strategy

## Current state

- Test target `LocalGalleryTests` is wired up in `project.yml`.
- Two unit-test files exist, both for widget helpers only:
  - `WidgetRotationTests.swift` — `pickRotation`, `SeededRNG`, `WidgetDayKey`
  - `WidgetDeepLinkTests.swift` — `localgallery://` URL round-trips
- Everything in the main app target is uncovered: `GalleryManager`
  (~2500 LOC), `Models`, `AppRouter`, search/filter, memory generation,
  metadata parsing, cache, widget snapshot exporter, all views.

## Goals

Catch the kinds of regressions that have actually bitten this project:

- Date / sort drift (AirDrop dates, video creation dates, viewer order
  not matching grid order).
- Metadata parsing errors (EXIF, XMP sidecars, digiKam tag namespacing).
- Cache corruption / version mismatch on disk.
- Widget snapshot drift between host app and extensions.
- Memory-generation logic (birthday, trip, on-this-day) producing
  empty / duplicate / mislabelled memories.
- SwiftUI/UIKit bridging hazards (PhotoViewerView paging, zoomable
  image black-screen on reopen).
- Performance cliffs on 20k-photo libraries.

## Non-goals

- Coverage % targets. Coverage is a lagging indicator of quality.
- Unit-testing system frameworks (`CNContactStore`, `BGTaskScheduler`,
  `AVAudioEngine`, `UIDocumentPickerViewController`,
  `UIActivityViewController`).
- Mocking `FileManager` / security-scoped URLs. Use real fixture dirs.
- Gating CI on performance baselines (device variance).
- Snapshot pixel diffing of every view.

## Test pyramid

```
              ^
              |   Tier 4: UX (XCUITest)        — ~3-5 tests, ~2 min total
              |   Tier 3: Snapshot/Preview     — manual visual QA
              |   Tier 2: Integration          — ~30-50 tests, fixtures on disk
              |   Tier 1: Unit (pure logic)    — ~150-250 tests, sub-second
              |   Tier 0: Already-tested       — Widget rotation + deep links
```

Every tier is independently valuable. Stop at whichever tier the
cost/benefit stops paying off — Tier 1 alone would have caught the
majority of historical bugs.

## Sections

- [Tier 1 — Unit tests](#tier-1--unit-tests-pure-logic)
- [Tier 2 — Integration tests](#tier-2--integration-tests-fixture-based)
- [Tier 3 — Snapshot / preview harness](#tier-3--snapshot--preview-harness)
- [Tier 4 — UX tests (XCUITest)](#tier-4--ux-tests-xcuitest)
- [Test infrastructure](#test-infrastructure)
- [Required source changes](#required-source-changes)
- [Implementation order & effort](#implementation-order--effort)
- [Out of scope](#out-of-scope)

## Tier 1 — Unit tests (pure logic)

Fast, no fixtures needed. These would have caught the majority of
historical bugs and cost roughly an afternoon to write.

Conventions:
- One XCTestCase per logical concern, named `<Concern>Tests`.
- Files live in `LocalGalleryTests/Unit/`.
- Use `@testable import LocalGallery` — make `internal` (not `public`)
  any types/functions tests need to reach. See [Required source
  changes](#required-source-changes).
- Build fixture data with small factory helpers in
  `LocalGalleryTests/Support/Fixtures.swift` (e.g.
  `PhotoFile.fixture(date:tags:gps:)`).

### 1.1 Models & identity

| Test file | What it locks in |
|-----------|------------------|
| `HierarchicalTagTests` | `People/Johannes`, `Places/Italy/Lazio/Rome`, flat tag, leading/trailing slashes, whitespace trim, namespace mapping for People/Places/Events/other |
| `TagNamespaceIconTests` | `icon(for:)` for each namespace; `placesIcon(depth:)` for depth 0..N (country flag vs. region vs. city) |
| `TagSuggestionIconTests` | Computed `icon` resolves Places depth correctly; non-Places falls back to namespace icon |
| `PhotoFileIDTests` | `stableID(for:)` deterministic per URL, differs across URLs, idempotent across rescans (catches grid flicker / selection loss) |
| `PhotoFolderIDTests` | `stableID(for:)` includes `folder:` prefix, never collides with `PhotoFile.stableID` for same URL |
| `FolderSortOrderTests` | `.label` for each case; raw values stable (UserDefaults key compatibility) |
| `CodableRoundTripTests` | `PhotoFile`, `PhotoFolder`, `Memory`, `EXIFData`, `PhotoToolsMetadata`, `PersonLink`, all `Widget*` snapshot structs encode→decode equal |

### 1.2 Dates, sort, section grouping

| Test file | What it locks in |
|-----------|------------------|
| `EarliestFilesystemDateTests` | All four nil combos for (created, modified); picks `min` when both present (catches AirDrop / chat-save dates sorting as today) |
| `PhotoSectionGroupTests` | Descending sort; `yyyy-MM` section keys; `unknown` bucket for nil dates; stable on already-sorted input; viewer-page index aligns with grid index |
| `SortPhotosTests` | `GalleryManager.sortPhotos(_:)` — descending by `dateTaken`, nils last, stable secondary sort by URL |
| `SortFoldersTests` | `GalleryManager.sortFolders(_:)` — each `FolderSortOrder` case (name asc/desc, date asc/desc, count) |

### 1.3 Search & filter

| Test file | What it locks in |
|-----------|------------------|
| `SearchQueryTests` | `GalleryManager.search(query:requiredTags:)` — empty query returns all; case-insensitive; matches filename / folder name / tag display name; multi-word AND |
| `RequiredTagsTests` | All required tags must match (AND semantics); Places prefix match (`Places/Italy` matches `Places/Italy/Rome`); People is exact-path match |
| `FilterKeyEqualityTests` | Same inputs → equal; changed query / tag set / count / date range → not equal (`.task(id:)` over- or under-firing) |
| `RecomputeFilterTests` | `PhotoGridScreen.recomputeFilter()` — fixture allPhotos + fixture FilterKey → expected ordered IDs; empty result handling |

### 1.4 Tag aggregation, people, featured

| Test file | What it locks in |
|-----------|------------------|
| `PeopleTagsTests` | `peopleTags` filters `allTags` to `namespace == .people`; sorted by count desc |
| `VisiblePeopleTests` | Hides `hiddenPeople`; floats `featuredPeople` to top in insertion order; preserves rest |
| `VisibleMemoriesTests` | Filters `memories` by `hiddenMemories` set |
| `HiddenPeopleTagsTests` | Resolves hidden paths → `TagSuggestion`s; unknown paths produce graceful fallback |
| `HideFeatureTogglesTests` | `hidePerson`, `unhidePerson`, `toggleFeaturePerson`, `isFeatured` — observable side effects on `@Published` sets |
| `FeaturedPhotoResolutionTests` | `featuredPhoto(for:)` returns explicit override when set; otherwise most-recent for tag; nil when no photos |

### 1.5 Memory generation (the highest-leverage area)

`generateMemories(...)` is huge but its sub-helpers are
`private nonisolated static` and pure. Test the helpers directly.

| Test file | What it locks in |
|-----------|------------------|
| `BirthdayMemoryTests` | `generateBirthdayMemories` — fires when contact birthday matches today's MM-DD; merges across multiple year-folders; respects `birthdayMemoriesEnabled`; respects `personContactLinks` (.disabled blocks, .manual overrides .auto); skips when no photos for the person |
| `TripDetectionTests` | `generateTripMemories` — clusters consecutive days (≤ N day gap) of GPS-tagged photos; minimum-photo and minimum-day-span thresholds; splits when gap exceeded |
| `TripLabelTests` | `tripLabel(for:)` — single-country trip → country name; 2-country → `"A & B"`; 3+ → `"A, B & C"`; no GPS → falls back to deepest shared Places prefix; empty → nil |
| `DeepestSharedPlacesPrefixTests` | All photos same Places path → full prefix; mixed → longest common prefix; some without Places → ignored or returns shorter prefix; empty input → empty array |
| `ConsecutivePlacesSegmentsTests` | Walks photos, emits run-length segments by Places path; preserves order |
| `ConsecutiveCountrySegmentsTests` | Same but on `countryCode` |
| `HaversineKmTests` | Known city-pair distances (Rome→Milan ~478 km; same point → 0; antipodes); symmetric |
| `FormatDateRangeTests` | Same day → single date; same month → `"3-7 Aug 2024"`; cross-month → `"30 Jul - 3 Aug 2024"`; cross-year → both years; locale-stable |
| `SubtitleWithCountTests` | `"5 photos"` vs `"1 photo"` pluralization; combined with date / location subtitles |
| `MemoryGenerationGateTests` | `generateMemoriesIfNeeded()` skips when `memoriesGeneratedDay == today`; runs when nil or different day; `forceRegenerateMemories()` clears the gate |
| `BirthdayRelevantSignatureTests` | `birthdayRelevantSignature(_:)` — same set of birthdays → same signature regardless of contact order; ignores name changes; differs when birthday added/removed |

### 1.6 Navigation & deep linking

| Test file | What it locks in |
|-----------|------------------|
| `AppRouterHandleTests` | `.memory(id:)` → switches to Collections tab + applies; `.folder(id:)` → switches to Folders tab + applies; `.tags(paths:)` → switches to All Photos + sets `pendingPhotosTagFilter` |
| `AppRouterApplyFolderTests` | DFS finds folder by `stableID` UUID string; missing → queues `pendingFolderId`; nested folder → builds correct `foldersPath` |
| `AppRouterApplyMemoryTests` | Found memory → pushes onto `collectionsPath`; missing → queues `pendingMemoryId` |
| `AppRouterConsumePendingTests` | After scan completes, `consumePendingIfReady` resolves queued IDs and clears them; idempotent if called twice |
| `AppRouterFindFolderTests` | Recursive DFS finds nested folder; nil for unknown; respects first-match on duplicate IDs (shouldn't happen but defined behavior) |
| `AllPhotosViewApplyPendingTests` | `applyPendingTagFilter()` resolves string paths against `manager.allTags` → `seedTags`; unknown paths dropped silently |

(`WidgetDeepLink` round-tripping is already covered by
`WidgetDeepLinkTests.swift` — no changes.)

### 1.7 Contacts & people linking

| Test file | What it locks in |
|-----------|------------------|
| `ContactInfoTests` | `fullName` combines given + family with single space, trims; `hasUsableBirthday` true only when both `month` and `day` present |
| `ContactsAuthorizationTests` | `ContactsService.isAuthorized(_:)` — `.authorized` true; `.limited` true (iOS 18+); `.denied`/`.restricted`/`.notDetermined` false |
| `LinkStateTests` | `linkState(forPersonPath:displayName:)` — no entry → `.unlinked`; `.disabled` → `.disabled`; `.auto(name)` → resolves via lowercased name match in `_contactsByLowerName`; `.manual(id)` → resolves via `_contactByID`; both miss → `.unlinked` |
| `EffectiveContactTests` | `.disabled` → nil; `.auto`/`.manual` resolved → contact; mismatched id → nil |
| `RebuildContactsByLowerNameTests` | After `contacts` setter, `_contactsByLowerName` keyed by lowercased fullName, last-write-wins on duplicate names; `_contactByID` keyed by `id`; cleared when contacts reset to `[]` |
| `BirthdayLineTests` | `birthdayLine(for:)` — with year → `"Jan 5, 1990"`; without year → `"Jan 5"`; missing month/day → empty string |
| `IsBirthdayTodayTests` | Matches when contact M/D == today's M/D; ignores year; false when missing M or D |
| `LinkPersonMutationsTests` | `linkPerson`, `unlinkPerson`, `resetPersonLink` — mutations on `personContactLinks` and observable signal fired |

### 1.8 Widget snapshot logic

`WidgetSnapshotExporter` is an actor; test its pure helpers directly
where possible, and `export` integration-style in Tier 2.

| Test file | What it locks in |
|-----------|------------------|
| `ContentFingerprintTests` | Same inputs → same fingerprint; reordering photos changes it (it's a content hash, ordering matters for index); changing day key changes it; tag set membership reflected |
| `TopRecentPhotosTests` | Returns N most recent by `dateTaken`; nils filtered out or sorted last; stable for ties |
| `BuildFolderIdMapTests` | DFS builds URL → folder UUID map; nested folders included; root included |
| `BuildMemoryItemsTests` | Maps `Memory` → `MemorySnapshotItem` with priority window (e.g., birthday today = high; on-this-day = medium); preserves IDs |
| `BuildFolderCatalogTests` | Only leaf folders ≥ threshold; sorted by name; mapped to `FolderCatalogEntry` |
| `WidgetIndexFilterTests` | `WidgetIndex.photos(matchingAllTags:)` — AND across paths; Places prefix match; `photos(inFolder:)` exact folder UUID match |

### 1.9 Grid layout

| Test file | What it locks in |
|-----------|------------------|
| `GridLayoutConfigTests` | All 4 size tiers × portrait/landscape × `columnCount`; `cellSize(for:)` math at known widths; `columns(for:)` array length matches `columnCount`; `gridIconName` per tier |

### 1.10 EXIF formatting helpers

| Test file | What it locks in |
|-----------|------------------|
| `EXIFFormattersTests` | `dimensionsText` — `1920×1080`, `nil` → empty; `formattedFileSize` — `<1KB`, KB/MB/GB boundaries; `apertureText` — `f/2.8`, missing → empty; `shutterSpeedText` — `1/250`, `2"`, `1/3"`; `cameraText` — `make + model`, model only, neither |

### 1.11 Audio synthesis math (no engine)

| Test file | What it locks in |
|-----------|------------------|
| `SlideshowMusicThemeTests` | Each theme's `rootMidi` in valid MIDI range (57–67); `progression` non-empty; `chordDuration > 0`; `displayName`/`blurb` non-empty |
| `RenderBufferTests` | Buffer length matches `progression.count * chordDuration * sampleRate`; samples in `[-1, 1]`; deterministic per theme (no RNG) |
| `SynthSampleTests` | `synth(midiRoot:intervals:time:)` at known time inputs returns expected sample magnitudes; intervals shift pitch correctly |

(The `AVAudioEngine`-driven `SlideshowMusicPlayer.play/stop` is
out of scope — see [Out of scope](#out-of-scope).)

### 1.12 Slideshow state transitions

| Test file | What it locks in |
|-----------|------------------|
| `SlideshowStateTests` | `goNext`/`goPrev` increment/decrement index with wrap; `resetSlide` zeroes timer state; `nextDuration` returns configured hold; bounds at first/last slide |

(Timer scheduling and audio playback are integration concerns —
test the index math here, leave the rest to XCUITest.)

### 1.13 Existing coverage (unchanged)

- `WidgetRotationTests` — `pickRotation`, `SeededRNG`, `WidgetDayKey`
- `WidgetDeepLinkTests` — `localgallery://` URL round-trips

---

**Tier 1 totals:** ~30 test files, ~150-250 individual cases,
~200-400 LOC of fixtures + factory helpers, sub-second runtime.

<!-- TIER 2 BODY -->

<!-- TIER 3 BODY -->

<!-- TIER 4 BODY -->

<!-- INFRA BODY -->

<!-- SOURCE CHANGES BODY -->

<!-- ORDER & EFFORT BODY -->

<!-- OUT OF SCOPE BODY -->
