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

<!-- TIER 1 BODY -->

<!-- TIER 2 BODY -->

<!-- TIER 3 BODY -->

<!-- TIER 4 BODY -->

<!-- INFRA BODY -->

<!-- SOURCE CHANGES BODY -->

<!-- ORDER & EFFORT BODY -->

<!-- OUT OF SCOPE BODY -->
