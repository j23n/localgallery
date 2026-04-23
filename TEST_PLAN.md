# LocalGallery test plan

Goal: catch the *kinds* of regressions that have bitten this project so far —
date/sort logic, metadata parsing, SwiftUI/UIKit layout bridging, performance
cliffs on 20k-photo libraries, and keyboard/viewer UX.

Not aiming for coverage %. Each tier is independently valuable; stop wherever
the cost/benefit stops paying off.

## Setup

No test target exists yet. Add one:

1. Edit `project.yml` — add an `LocalGalleryTests` target (unit test bundle,
   depends on `LocalGallery`, iOS 17+).
2. Create `LocalGalleryTests/` alongside `LocalGallery/`.
3. `xcodegen` to regenerate the project.
4. Build with: `xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery -destination "platform=iOS Simulator,name=iPhone 15"`.

Flip these from `private` to `internal` so tests can reach them:
- `GalleryManager.readImageMetadata(url:)`
- `GalleryManager.readXMPSidecar(for:)`
- `GalleryManager.readVideoDate(url:)`

`earliestFilesystemDate`, `PhotoFile.stableID`, `PhotoSection.group` are
already accessible.

## Tier 1 — pure-logic unit tests

Fast, no fixtures needed. These would have caught the majority of today's bugs.

| Test file | What it locks in | Regression it guards against |
|-----------|------------------|------------------------------|
| `EarliestFilesystemDateTests` | all 4 nil combos, picks `min` when both present | AirDrop / chat-save date drift (photos sorted as "today") |
| `PhotoSectionGroupTests` | descending sort, `yyyy-MM` section keys, `unknown` bucket for nil dates, stable across already-sorted input | Viewer swipe order drifting from grid order |
| `HierarchicalTagTests` | `People/Johannes`, `Places/Italy/Lazio/Rome`, flat tag, trimming | Namespace parsing breakage — People| convention |
| `PhotoFileIDTests` | `stableID` deterministic per URL, differs across URLs, idempotent across rescans | Grid flicker, selection loss |
| `FilterKeyEqualityTests` | same input → equal, changed query/tag/count/date → not equal | `.task(id:)` over- or under-firing |
| `TripLabelTests` | `deepestSharedPlacesPrefix` with mixed Places paths, empty, single-country, 2-country, 3+-country, no-Places fallback | Memory labelling regressions |

Aim: ~6 files, ~200 lines total, ~1 hour.

## Tier 2 — metadata integration tests

Needs committed fixture files in `LocalGalleryTests/Fixtures/`. Keep them small.

Files to create (reproducibly — document *how* each was produced):
- `jpeg_with_exif.jpg` — has `DateTimeOriginal=2023:08:15 14:30:00`, GPS, digiKam `TagsList=[People/Alice, Places/Italy/Rome]`
- `jpeg_no_exif.jpg` — stripped metadata, filename-dated
- `jpeg_with_sidecar.jpg` + `jpeg_with_sidecar.jpg.xmp` — XMP sidecar carries the tags
- `video_with_creationdate.mp4` — small MP4 (≤100 KB), embedded `creationDate=2024:01:10 09:00:00`
- `video_no_creationdate.mp4` — stripped video
- A folder tree fixture: `FixtureLibrary/A/B/*.jpg` covering live-photo pairing (`IMG_1.heic` + `IMG_1.mov`)

How to produce (put this in the fixtures README):
- Use `exiftool -DateTimeOriginal="..." -Keywords+="..." foo.jpg`
- For XMP sidecar: raw XML, commit as-is
- For videos: `ffmpeg -i in.mov -metadata creation_time="2024-01-10T09:00:00Z" -t 1 out.mp4`

Tests:
- `ReadImageMetadataTests`
  - `jpeg_with_exif` → dateTimeOriginal parsed, tags extracted, country code uppercase, GPS present with correct signs for N/S/E/W
  - `jpeg_no_exif` → date is nil (caller falls back)
  - `jpeg_with_sidecar` → tags come from sidecar, merged with embedded
- `ReadVideoDateTests`
  - `video_with_creationdate` → returns embedded date, **not** filesystem date — this test would have caught "video dated today"
  - `video_no_creationdate` → returns nil
- `ScanFolderTests`
  - Fixture tree → correct photo count, live-photo pairing works, standalone videos kept separate
  - Cache roundtrip: scan → `saveCache` → wipe in-memory → `loadCache` → equal photos and folder tree
  - Cache version mismatch → cache discarded

~2 hours once fixtures exist.

## Tier 3 — performance regression guards

`XCTestCase.measure { }` blocks. Run locally only — don't gate CI (device
variance makes thresholds flaky). Baselines set on your dev machine.

- `recomputeFilter` with 20k synthetic `PhotoFile`s
  - query empty: target < 100ms
  - query "rome": target < 150ms
  - 3 active tags: target < 150ms
- `PhotoSection.group(presorted:)` with 20k: target < 30ms
- `GalleryManager.rebuildSortAndIndex` with 20k: target < 250ms
- Tag aggregation task (the detached block inside `rebuildSortAndIndex`): < 300ms

Synthetic photos: `PhotoFile(id: UUID(), url: URL(fileURLWithPath: "/tmp/p\(i).jpg"), ..., dateTaken: Date().addingTimeInterval(-TimeInterval(i * 60)))`.

## Tier 4 — UI smoke tests (XCUITest) — optional

One happy-path test. Seed a small fixture library, drive it end-to-end:

1. Launch → at least one thumbnail appears in All Photos.
2. Tap first photo → viewer appears. Assert pixels aren't all-black at centre
   of screen (catches `ZoomableImageView` layout regression).
3. Swipe right → second photo index shown in top counter.
4. Dismiss → tap *same* photo again → still non-black. This is the specific
   reopen-black-screen regression you reported today.
5. Tap search field → type "a" → result count decreases.
6. Clear → keyboard dismisses within 500ms.
7. Tap toolbar up-arrow → top of list visible. No UI freeze >200ms.

Keep to ONE test. XCUITests cost ~30s each and are flaky on device.

## Tier 5 — SwiftUI preview harness + snapshot — optional

Add a `PreviewHelpers.swift` in `LocalGalleryTests/` that builds a seeded
`GalleryManager` without hitting disk, and add `#Preview` blocks to each view
using it. Manual visual QA, nothing automated.

If you want automation later: `pointfreeco/swift-snapshot-testing` against
these previews.

## Suggested order

1. Tier 1 — ~1 hour, immediately prevents whole categories of bugs.
2. Flip the three `private` → `internal` accessors.
3. Tier 2 — the hardest-to-reason-about paths (metadata parsing, cache). This is where silent corruption lives.
4. Decide on Tiers 3–5 based on whether perf or UI regressions keep biting.

## What this plan deliberately does NOT do

- No test-target setup for the preview app (too much Xcode project surgery
  for the value).
- No mocking of `FileManager` / security-scoped URLs — use real fixtures.
- No CI integration for perf tests (device variance).
- No line-coverage target — coverage is a lagging indicator of quality here.
