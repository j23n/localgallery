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

## Tier 2 — Integration tests (fixture-based)

Real I/O against committed fixture files. Every test gets its own
temp dir; nothing leaks between tests.

Conventions:
- Fixtures live in `LocalGalleryTests/Fixtures/` and ship in the
  test bundle's `Resources` build phase.
- A `TempDir` helper (in `LocalGalleryTests/Support/`) creates &
  tears down a unique dir per test under `NSTemporaryDirectory()`.
- A `TestUserDefaults` helper returns a `UserDefaults(suiteName:)`
  that's wiped on `tearDown`.
- A `TestGalleryManager` factory builds a `GalleryManager` pointed
  at temp dirs (cache URL, memories URL, bookmark URL, widget
  shared container) — see [Required source changes](#required-source-changes)
  for the small init surface this needs.

### 2.0 Fixture library

Document *how* each fixture was produced in
`LocalGalleryTests/Fixtures/README.md`. Reproducibility matters —
when a parser regresses, regenerating the fixture is the first
diagnostic.

| Fixture | Produced with |
|---------|---------------|
| `jpeg_with_exif.jpg` | `exiftool -DateTimeOriginal="2023:08:15 14:30:00" -GPSLatitude=41.9 -GPSLatitudeRef=N -GPSLongitude=12.5 -GPSLongitudeRef=E -Keywords+="People/Alice" -Keywords+="Places/Italy/Rome" foo.jpg` |
| `jpeg_no_exif.jpg` | `exiftool -all= bar.jpg` |
| `jpeg_with_sidecar.jpg` + `jpeg_with_sidecar.jpg.xmp` | Stripped JPEG + raw XMP XML (committed verbatim) carrying digiKam:TagsList and photo-tools:CountryCode |
| `heic_with_exif.heic` | `exiftool` against a sample HEIC; same EXIF tags as the JPEG fixture |
| `live_photo/IMG_1.heic` + `live_photo/IMG_1.mov` | Pair with matching basenames for live-photo pairing |
| `video_with_creationdate.mp4` | `ffmpeg -i in.mov -metadata creation_time="2024-01-10T09:00:00Z" -t 1 -c:v libx264 -pix_fmt yuv420p out.mp4` |
| `video_no_creationdate.mp4` | Same, with `-map_metadata -1` |
| `xmp_phototools_full.xmp` | Hand-crafted XMP carrying every photo-tools field listed in the schema (countries, regions, cities, events, ratings) |
| `corrupt_truncated.jpg` | First 200 bytes of a real JPEG |
| `FixtureLibrary/` | Tree of A/B/C subfolders mixing all the above; covers leaf-folder detection, live-photo pairing inside subfolders |

Keep total fixture size under ~2 MB. Use 1×1 or 16×16 pixel images
where pixel content doesn't matter; only metadata matters.

### 2.1 Image metadata reading

| Test file | What it locks in |
|-----------|------------------|
| `ReadImageMetadataTests` | `jpeg_with_exif` → `dateTimeOriginal` parsed (timezone handled), GPS lat/lon with correct sign for N/S/E/W, country code uppercased, digiKam tags extracted into `hierarchicalTags`; `jpeg_no_exif` → date nil, tags empty (caller falls back); `heic_with_exif` → same fields as JPEG; `corrupt_truncated.jpg` → returns empty result, doesn't crash |
| `ReadXMPSidecarTests` | `jpeg_with_sidecar` → tags from sidecar **merged** with embedded; sidecar country code overrides EXIF when both present; missing sidecar → no error; malformed XML → returns empty, logs |
| `XMPStringArrayTests` | `xmpStringArray(_:)` against `CFArray<CFString>`, single `CFString`, `nil` → expected `[String]` outputs |
| `PhotoToolsMetadataTests` | `xmp_phototools_full.xmp` → all schema fields decoded (countries, regions, cities, events, ratings, keywords); empty XMP → empty struct, not nil |

### 2.2 Video metadata

| Test file | What it locks in |
|-----------|------------------|
| `ReadVideoDateTests` | `video_with_creationdate` → embedded date parsed (catches "video dated today" regression); `video_no_creationdate` → nil (caller falls back to filesystem) |

### 2.3 Folder scan

| Test file | What it locks in |
|-----------|------------------|
| `ScanFolderTests` | `FixtureLibrary/` → expected photo count, expected folder tree shape; live-photo pairing (`IMG_1.heic` + `IMG_1.mov` → one `PhotoFile` with `livePhotoVideoURL` set); standalone `.mov` → kept as separate video; non-image files ignored |
| `ScanFolderConcurrencyTests` | Two overlapping `scanFolder(at:)` calls for same URL → only one `performScan` runs (coalesced by `activeScanTask`); two calls for *different* URLs → second cancels first |
| `ScanFolderCancellationTests` | Cancel mid-scan → `isScanning` returns to false; partial state not published |
| `EnrichMetadataTests` | After initial fast scan, `enrichMetadata()` populates `dateTaken`, GPS, tags on each photo without losing IDs (grid stable) |

### 2.4 Cache persistence

| Test file | What it locks in |
|-----------|------------------|
| `LibraryCacheRoundTripTests` | scan → `saveCache` → wipe in-memory state → `loadCache` → photos and folder tree equal; `lastSyncedAt` preserved |
| `LibraryCacheVersionTests` | Cache file with wrong `version` field → `loadCache` returns false, in-memory state untouched |
| `LibraryCacheCorruptTests` | Truncated / non-JSON cache file → `loadCache` returns false, doesn't crash, logs |
| `MemoriesCacheRoundTripTests` | `saveMemoriesCache` → wipe → `loadMemoriesCache` → `memories` equal; `memoriesGeneratedDay` survives via UserDefaults |
| `BookmarkRoundTripTests` | `saveBookmark(for:)` against a temp dir → `resolveBookmark()` returns the same URL; deleted dir → returns nil, doesn't throw; corrupt bookmark data → returns nil |

### 2.5 Persisted UserDefaults state

| Test file | What it locks in |
|-----------|------------------|
| `FolderSortOrderPersistenceTests` | Set `folderSortOrder` → defaults written; new manager pointed at same defaults reads it back |
| `HiddenFeaturedPersistenceTests` | `hiddenPeople`, `featuredPeople`, `hiddenMemories` round-trip via `didSet` writes |
| `FeaturedPhotoPersistenceTests` | `featuredPhotoByPerson` JSON round-trip |
| `PersonContactLinksPersistenceTests` | `personContactLinks` (enum with associated values) JSON round-trip; legacy raw shapes still decode |
| `BirthdayMemoriesEnabledPersistenceTests` | Toggle persists; default is `true` on first launch |

### 2.6 Thumbnail pipeline

| Test file | What it locks in |
|-----------|------------------|
| `ThumbnailGenerationTests` | `thumbnail(for:size:isVideo:)` returns image of approximately requested size; cache hit on second call (no disk read); cache eviction under memory pressure (call `clearThumbnailCache` and verify miss) |
| `ThumbnailDiskCacheTests` | First call writes JPEG to disk thumbnail dir; restart simulation (new manager, same dir) → loads from disk without regenerating |
| `OpaqueJPEGDataTests` | `opaqueJPEGData(from:quality:)` produces JPEG with no alpha channel; quality argument respected (size monotonic with quality) |

### 2.7 Memory generation end-to-end

| Test file | What it locks in |
|-----------|------------------|
| `GenerateMemoriesIntegrationTests` | `FixtureLibrary/` + fixed `Date()` (injected via clock seam) → expected memory count and labels; on-this-day memory matches photos taken on this MM-DD across years; trip memories cluster correctly; respects `hiddenMemories` filter at output time |
| `MemoryRegenerationTriggerTests` | Same-day call → `lastGeneratedDay` unchanged, no work; date advance + `runScheduledMemoryRefresh()` → memories regenerated, snapshot exported; `forceRegenerateMemories()` always regenerates |

### 2.8 Widget snapshot export & read

| Test file | What it locks in |
|-----------|------------------|
| `WidgetSnapshotExportTests` | `WidgetSnapshotExporter.export(_:)` against fixture inputs → writes `index.json`, `memories.json`, `folders.json`, `tags.json` to temp shared container; thumbnails written to `thumbs/<photoID>.jpg`; subsequent export with same fingerprint is a no-op (skip flag respected); changing inputs forces a rewrite |
| `WidgetSnapshotGCTests` | `garbageCollectThumbs(thumbsDir:keepIDs:)` deletes orphan files; preserves files in `keepIDs`; survives missing dir |
| `WidgetSnapshotReadTests` | Round-trip: write fixture JSON → `WidgetSnapshotReader.loadIndex/loadMemories/loadFolders/loadTags` decode equal; missing file → returns nil; corrupt JSON → returns nil |
| `WidgetIndexQueryIntegrationTests` | Loaded `WidgetIndex` + `photos(matchingAllTags:)` returns expected refs end-to-end |

### 2.9 SharedContainer

| Test file | What it locks in |
|-----------|------------------|
| `SharedContainerTests` | `prepareDirectories()` is idempotent; creates `thumbs/` subdir; works against an injected root URL (so tests don't need the real App Group) |

### 2.10 Performance regression guards (local-only)

`XCTestCase.measure { }` blocks. **Do not gate CI** on these —
device variance makes thresholds flaky. Run on dev machine to
catch order-of-magnitude regressions.

| Measurement | 20k photos baseline target |
|-------------|---------------------------|
| `recomputeFilter` empty query | < 100 ms |
| `recomputeFilter` query "rome" | < 150 ms |
| `recomputeFilter` 3 active tags | < 150 ms |
| `PhotoSection.group(presorted:)` | < 30 ms |
| `rebuildSortAndIndex` (sort + search index + tag aggregation) | < 250 ms |
| Tag aggregation alone (the detached block) | < 300 ms |
| `WidgetSnapshotExporter.export` (no thumb regen) | < 200 ms |
| Thumbnail generation × 100 (cold) | < 5 s |

Synthetic photos:
```swift
let photos = (0..<20_000).map { i in
    PhotoFile.fixture(
        url: URL(fileURLWithPath: "/tmp/p\(i).jpg"),
        dateTaken: Date().addingTimeInterval(-TimeInterval(i * 60)),
        tags: tagPoolPick(i)
    )
}
```

---

**Tier 2 totals:** ~25 test files, fixture library ~2 MB, 5-15 s
runtime (most cost is `XCTestCase.measure` warmup).

## Tier 3 — Snapshot / preview harness

Goal: cheap visual QA during development, with an upgrade path
to automated snapshot diffing if it ever earns its keep.

### 3.1 Seeded preview helper

Add `LocalGallery/Previews/PreviewSupport.swift` (compiled into
debug builds only):

```swift
#if DEBUG
extension GalleryManager {
    static func previewSeeded(
        photos: [PhotoFile] = .previewSet,
        memories: [Memory] = .previewSet,
        topPeople: [TagSuggestion] = .previewSet
    ) -> GalleryManager { /* in-memory only, no disk, no scan */ }
}
#endif
```

This lets every view ship a `#Preview` block with realistic state
without hitting disk. It also doubles as the seed for Tier 4
launch-arg fixtures.

### 3.2 #Preview blocks to add

One per top-level screen, each demonstrating empty/loading/error
where applicable:

| View | Preview variants |
|------|------------------|
| `AllPhotosView` | populated, empty library, mid-scan, with active tag filter |
| `PhotoGridScreen` | populated, search active, no results, year scrubber visible |
| `FolderBrowserView` | nested, single folder, empty |
| `CollectionsView` | with memories + people, empty (no library), permission-denied for contacts |
| `MemorySlideshowView` | playing, paused, last slide |
| `PhotoViewerView` | photo with EXIF, photo without metadata, video, live photo |
| `EXIFSheetView` | full metadata, partial, none |
| `LinkedContactsList` | linked / disabled / unlinked rows mixed |
| `ContactsPermissionPrimer` | first-launch, denied state |
| Each widget entry view | realistic snapshot, missing-thumbnail fallback |

### 3.3 Optional: automated snapshot diffing

If visual regressions become a recurring problem, add
[`pointfreeco/swift-snapshot-testing`](https://github.com/pointfreeco/swift-snapshot-testing)
as an SPM dep on the test target and feed it the seeded previews
above. Recommended scope:

- One reference snapshot per `#Preview` × `[light, dark]` ×
  `[iPhone 15, iPad 11"]`.
- Commit reference images under `LocalGalleryTests/__Snapshots__/`.

Don't do this preemptively — only when a visual regression slips
through twice. Snapshot tests are high-maintenance.

## Tier 4 — UX tests (XCUITest)

XCUITests cost ~30 s each and are flaky on real devices. Keep the
suite **small and focused on bugs that have actually shipped or
nearly shipped**. Add a new test only when a regression slips past
Tiers 1-2 — never for hypothetical UX coverage.

Add a separate target `LocalGalleryUITests` (`type: bundle.ui-test`)
to `project.yml`. It must NOT `@testable import LocalGallery`; it
drives the app via `XCUIApplication`.

### 4.1 Test-mode launch arguments

Wire a single launch-arg pathway in `LocalGalleryApp.swift`:

```swift
#if DEBUG
if ProcessInfo.processInfo.arguments.contains("--ui-test") {
    GalleryManager.shared.installFixtureLibrary(
        named: ProcessInfo.processInfo.environment["UI_TEST_FIXTURE"]
            ?? "default"
    )
}
#endif
```

`installFixtureLibrary(named:)` copies a fixture tree from the
test bundle into a temp dir and seeds the manager with it. Each
named fixture is a different starting state — `default`,
`empty`, `oneMemory`, `withVideo`, `permissionDenied`.

This is the seam every UX test uses. No mocking, no swizzling, no
test-only branches inside production views.

### 4.2 The minimum viable UX suite

Five tests. Each owns one specific historical regression.

| Test | Specific regression it guards |
|------|-------------------------------|
| `PhotoViewerReopenTest` | Open photo → dismiss → reopen *same* photo: pixels at viewer center are not all-black (the `ZoomableImageView` reopen black-screen bug from earlier this month) |
| `ViewerPagingOrderTest` | Open first photo in grid → swipe right N times → the photo shown matches the (N+1)th cell in the grid (catches viewer-vs-grid sort drift) |
| `SearchAndClearTest` | Tap search → type "a" → result count drops; tap clear → keyboard dismisses within 500 ms; result count restores |
| `WidgetMemoryDeepLinkTest` | Launch with `localgallery://memory/<id>` → Collections tab is selected, that memory is on top of the nav stack (`AppRouter` end-to-end) |
| `RescanPullToRefreshTest` | Pull-to-refresh on All Photos → progress overlay shows → completes → grid re-renders with same scroll position; no UI freeze >200 ms |

Aim for total UI suite runtime < 3 minutes on the iOS Simulator.

### 4.3 What stays *out* of XCUITest

- Anything driven by `CNContactStore` permission prompts (the
  system alert can't be reliably driven; use the
  `permissionDenied` fixture seed instead).
- Anything that depends on the system share sheet or document
  picker mid-flow.
- Performance assertions — Tier 2 owns those.
- Pixel-level visual checks — Tier 3 owns those if anything does.

## Test infrastructure

### Test bundle layout

```
LocalGalleryTests/
  Unit/                      # Tier 1 — XCTestCase subclasses by topic
    HierarchicalTagTests.swift
    BirthdayMemoryTests.swift
    ...
  Integration/               # Tier 2 — fixture-driven
    ReadImageMetadataTests.swift
    LibraryCacheRoundTripTests.swift
    WidgetSnapshotExportTests.swift
    ...
  Performance/               # Tier 2.10 — XCTestCase.measure
    FilterPerformanceTests.swift
    ScanPerformanceTests.swift
  Support/                   # Helpers used across tiers
    Fixtures.swift           # Factory: PhotoFile.fixture(...), etc.
    TempDir.swift            # Per-test temp dir lifecycle
    TestUserDefaults.swift   # Suite-name-scoped defaults
    TestGalleryManager.swift # Manager pointed at temp paths
    Clock.swift              # Injectable clock for date-sensitive tests
  Fixtures/                  # Real binary files
    README.md                # How each fixture was produced
    jpeg_with_exif.jpg
    jpeg_with_sidecar.jpg
    jpeg_with_sidecar.jpg.xmp
    video_with_creationdate.mp4
    FixtureLibrary/A/B/...
  WidgetRotationTests.swift  # existing, untouched
  WidgetDeepLinkTests.swift  # existing, untouched

LocalGalleryUITests/         # Tier 4 — separate target
  PhotoViewerReopenTest.swift
  ViewerPagingOrderTest.swift
  SearchAndClearTest.swift
  WidgetMemoryDeepLinkTest.swift
  RescanPullToRefreshTest.swift
  Support/
    XCUIApplication+Launch.swift
```

### Fixture & data seeding

`Fixtures.swift` exposes ergonomic factories so unit tests don't
spell out every property:

```swift
extension PhotoFile {
    static func fixture(
        url: URL = URL(fileURLWithPath: "/tmp/p.jpg"),
        dateTaken: Date? = nil,
        tags: [String] = [],
        gps: (lat: Double, lon: Double)? = nil,
        countryCode: String? = nil,
        isVideo: Bool = false
    ) -> PhotoFile { /* ... */ }
}

extension Memory { static func fixture(...) -> Memory }
extension PhotoFolder { static func fixture(...) -> PhotoFolder }
extension ContactInfo { static func fixture(...) -> ContactInfo }
```

### Clock injection

Memory generation, the daily-gate check, and birthday matching
all read `Date()`. Inject a clock so tests don't depend on the
wall clock:

```swift
protocol Clock { func now() -> Date }
struct SystemClock: Clock { func now() -> Date { Date() } }
struct FixedClock: Clock { let date: Date; func now() -> Date { date } }
```

`GalleryManager` gets an internal `var clock: Clock = SystemClock()`
seam. Production code unchanged; tests inject a `FixedClock`.

### UserDefaults isolation

```swift
final class TestUserDefaults {
    static func make() -> UserDefaults {
        let suite = "LocalGallery.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
```

Pass into `GalleryManager` via a `defaults: UserDefaults` init
parameter (default `.standard`). All `didSet` writers use
`self.defaults` instead of `.standard` directly.

### Accessibility identifiers (for Tier 4)

Currently zero `accessibilityIdentifier` modifiers in the codebase.
Add them only where Tier 4 tests need them — don't sprinkle.

| Element | Identifier |
|---------|-----------|
| All Photos tab root | `tab.allPhotos` |
| Folders tab root | `tab.folders` |
| Collections tab root | `tab.collections` |
| Search field on `PhotoGridScreen` | `search.field` |
| Search clear button | `search.clear` |
| Photo grid cell | `photo.\(stableID)` |
| Memory card on `CollectionsView` | `memory.\(id)` |
| Photo viewer container | `viewer.root` |
| Photo viewer counter label (`3 of 12`) | `viewer.counter` |
| Photo viewer center hit-test image | `viewer.image` |
| Pull-to-refresh sentinel | `allPhotos.refresh` |
| Settings rescan button | `settings.rescan` |

### Mocking strategy

| Concern | Strategy |
|---------|----------|
| `FileManager` | **Don't mock.** Use real temp dirs (`TempDir`). Anything that needs a file gets one. |
| `UserDefaults` | Suite-scoped instance per test. |
| `Date()` | `Clock` protocol, `FixedClock` in tests. |
| `CNContactStore` | Wrap in a `ContactsService` protocol; production uses `LiveContactsService`, tests use `StubContactsService` returning fixture `[ContactInfo]`. |
| `BGTaskScheduler` | Don't test directly. Test `runScheduledMemoryRefresh()` directly; trust the OS to invoke it. |
| `AVAudioEngine` | Don't mock. Test `renderBuffer` math; treat `play/stop` as out of scope. |
| `ImageIO` / `AVAsset` | Don't mock. Use real fixture files. |
| Security-scoped URLs | Don't test. Tests use plain temp URLs; `startAccessingSecurityScopedResource()` becomes a no-op when called on non-bookmarked URLs. |

### Running tests

```bash
# All unit + integration tests
xcodebuild test \
  -project LocalGallery.xcodeproj \
  -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 15" \
  -only-testing:LocalGalleryTests

# UX tests only (slow)
xcodebuild test \
  -project LocalGallery.xcodeproj \
  -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 15" \
  -only-testing:LocalGalleryUITests

# Single test file (fastest dev loop)
xcodebuild test \
  -project LocalGallery.xcodeproj \
  -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 15" \
  -only-testing:LocalGalleryTests/BirthdayMemoryTests
```

### CI

Recommended GitHub Actions workflow gate:
- PR opened/updated → run `LocalGalleryTests` (unit + integration,
  no performance, no UX). Should finish in <30 s.
- Nightly → run `LocalGalleryUITests` on `iPhone 15` simulator.
- Performance tests stay local-only.

<!-- SOURCE CHANGES BODY -->

<!-- ORDER & EFFORT BODY -->

<!-- OUT OF SCOPE BODY -->
