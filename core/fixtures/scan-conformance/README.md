# Phase-3 scanner / metadata conformance fixtures

The spec for `_plans/04-phase-3-scanner-metadata.md` §1. Everything here was
generated from the **shipping Swift** `MetadataReader`, `FolderScanner` and
`LibrarySnapshot` before any of them was ported, so the Rust implementation
could be checked against something other than opinion. Where the Swift
behaviour was buggy, the bug is pinned — fixing it is a separate, deliberate
change with its own version bump.

Since step 5 those three Swift types are **gone**: the app runs on the core
scanner, and the Swift-side harnesses now drive `CoreScanner` /
`GalleryCore.readImageMetadata` with their assertions unchanged. That is the
arrangement these files exist for — the same expectations, produced by a
different implementation, reached through the path the app actually uses.

One copy in the repo, two readers:

| reader | how |
|---|---|
| `LocalGalleryTests` (simulator) | this directory is a folder reference in `project.yml`, bundled verbatim |
| `cargo test` (host) | `core/gallery-model/tests/scan_conformance_fixtures.rs`, read by relative path |

Same arrangement as `stable_uuid_vectors.json` and `expected_tags.json`.
Duplicating expectations per language puts nothing on the line.

## Contents

| file | kind | produced by |
|---|---|---|
| `assets/` | input | `scripts/gen_conformance_assets.py` |
| `metadata_conformance.json` | expectation | `MetadataConformanceTests` |
| `scanner_tree.json` | input | hand-written |
| `scanner_conformance.json` | expectation | `ScannerConformanceTests` |
| `library_snapshot_v20.json` | expectation | `LibrarySnapshotFixtureTests` |

Tests that read them:

- `LocalGalleryTests/Unit/MetadataConformanceTests.swift`
- `LocalGalleryTests/Unit/ScannerConformanceTests.swift`
- `LocalGalleryTests/Unit/LibrarySnapshotFixtureTests.swift`
- `LocalGalleryTests/Unit/PathNormalizationTests.swift` (no fixture; pins the
  Unicode behaviour the other three depend on)
- `core/gallery-model/tests/scan_conformance_fixtures.rs` (shape + landmine
  guard rails)
- `core/gallery-meta/tests/metadata_conformance.rs` — runs the Rust reader over
  `assets/` and compares every field
- `core/gallery-scan/tests/scanner_conformance.rs` — materialises
  `scanner_tree.json`, runs the same four passes, compares every field
- `core/gallery-scan/tests/classification_conformance.rs` — checks the Rust
  extension table against the `scannerKind` column
- `core/gallery-model/tests/library_snapshot_roundtrip.rs` — decodes and
  re-encodes `library_snapshot_v20.json`

## Regenerating

The expectation files are written **by the tests**, from the live
implementation. Nothing is hand-edited.

```sh
# 1. assets only, if you added or changed a fixture file (needs exiftool)
python3 scripts/gen_conformance_assets.py

# 2. rerun xcodegen if you added a test file
xcodegen

# 3. regenerate the expectations — this run FAILS on purpose: it writes the
#    new files into the repo, and the assertion still compares against the
#    copy already inside the built test bundle.
TEST_RUNNER_CONFORMANCE_REGEN=1 xcodebuild test \
  -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:LocalGalleryTests/MetadataConformanceTests \
  -only-testing:LocalGalleryTests/ScannerConformanceTests \
  -only-testing:LocalGalleryTests/LibrarySnapshotFixtureTests

# 4. run it again without the flag — now it must be green
xcodebuild test -project LocalGallery.xcodeproj -scheme LocalGallery \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"

# 5. and the Rust side
cd core && cargo test --workspace
```

`xcodebuild` only forwards host environment variables that carry the
`TEST_RUNNER_` prefix, which it strips — hence the odd spelling.

Notes on the mechanism, in `LocalGalleryTests/Support/ConformanceFixtures.swift`:

- A **mismatch never rewrites the fixture.** Only `CONFORMANCE_REGEN=1` (or a
  missing file) writes. Auto-healing on mismatch would make the suite go red
  once and green forever after, which is the exact failure this directory
  exists to prevent.
- Every dump is also echoed to stdout between `===BEGIN <name>===` /
  `===END <name>===` and written to the simulator's temp dir, so the output
  survives even if the sandbox refuses the repo write.
- `metadata_conformance.json` and `scanner_conformance.json` are canonical
  (`.sortedKeys`, `.prettyPrinted`, `.withoutEscapingSlashes`, trailing
  newline) and a test enforces it, so a regeneration is a readable diff.
  `library_snapshot_v20.json` is **not** — it is raw wire format, see below.

## The `notes` fields are part of the fixture

Each metadata entry and each scanner pass carries a `notes` array that is
compared like any other field. The notes live in the test sources
(`MetadataConformanceTests.notes`, `ScannerConformanceTests.passNotes`) and
survive regeneration. They are the only place several of these behaviours are
written down; deleting one is a test failure, not a cleanup.

## `library_snapshot_v20.json` — the encoding contract

Produced by the app's real save path: `JSONDiskCache<LibrarySnapshot>.save`,
i.e. a stock `JSONEncoder()` over `struct Payload { version, value }`. The
library it encodes came out of a real `FolderScanner.scan`, with the temp-dir
paths rebased onto `/fixtures/PhotoLibrary` and a few photos decorated so both
encoder branches (optional present / absent) appear.

What the Rust port must reproduce:

| aspect | contract |
|---|---|
| envelope | `{"version": Int, "value": LibrarySnapshot}`. The version is decoded **first**, on its own; only then the payload. An incompatible payload must still report as a version mismatch, not a corrupt file. |
| version | `20`. A mismatch **evicts the file** (and the memories cache with it). |
| `LibrarySnapshot` | three keys: `rootFolder`, `allPhotos`, `sidecarManifest` — the last one optional and omitted when `nil` (see below) |
| dates | JSON **numbers**: `JSONEncoder`'s default `.deferredToDate`, i.e. seconds since **2001-01-01T00:00:00Z** (Unix 978307200). Not ISO 8601, not the Unix epoch. Fractional seconds are kept (`651234567.25`). |
| URLs | `absoluteString` of a file URL: `"file:///fixtures/PhotoLibrary/…"`, percent-encoded (`%20` for spaces). |
| UUIDs | uppercase hyphenated strings |
| `Int64` | JSON numbers |
| nil optionals | **omitted**, not `null` — the synthesized encoder uses `encodeIfPresent`. Applies at every level, including `HierarchicalTag.namespace` and `FaceRegion.name`. |
| key order | **not part of the contract.** `JSONEncoder`'s default output orders a keyed container's members unpredictably, and not even stably within one process. Comparisons are on the decoded JSON *object*. serde may emit any order. |

Documented, legal loss on a save/load round trip:

- `PhotoFile.locality` and `PhotoFile.sidecarStatus` are **not** in
  `CodingKeys`. They are dropped on save and come back as `.local` / `.absent`.
  The fixture was built with non-default values on purpose so a test can prove
  it.
- `PhotoFile.dimensions` and `PhotoFile.exif` are runtime-only and likewise
  never persisted.
- Nil-vs-absent is not distinguishable after a round trip, and does not need
  to be.

### `sidecarManifest` — landed, without a version bump

`_plans/06-performance-baseline.md` Finding 2 added
`sidecarManifest: [SidecarCandidate]?` to `LibrarySnapshot` as an **optional**
field with **no version bump**: a bump would have forced a full rescan on every
install to save a single pass. The fixture keeps its `v20` name because the
version genuinely did not change, and it now carries one row so the field is
exercised rather than merely present.

Two things about that row are contract, not decoration:

| aspect | contract |
|---|---|
| `downloadStatus` | a **bare string** (`"local"`). A Swift enum without raw values synthesises `{"local": {}}` for a payload-less case, and `gallery_model::snapshot::DownloadStatus` emits the string. `FileProviderDetector.DownloadStatus` therefore has `String` raw values. |
| `currentVersion.contentIdentifier` | a **string**, even though `fileContentIdentifierKey` vends an `Int64` on APFS. SAF and every non-Apple provider hand back opaque tokens. `ContentVersion`'s Swift decoder accepts a bare JSON number too, so sidecar caches written before the change still load. |

Both halves of the no-bump decision have a test:
`LibrarySnapshotFixtureTests.testAV20SnapshotWithoutTheManifestStillLoadsWarm`
and `library_snapshot_roundtrip.rs::the_committed_snapshot_decodes` each strip
the key and check the file still loads warm with `nil`.

## Adversarial asset inventory (`assets/`)

Built by `scripts/gen_conformance_assets.py` — deterministic: the 8×8 base
images are base64 blobs in the script (no ImageMagick, no encoder drift), the
videos and HEIFs are hand-assembled ISO-BMFF containers, and every XMP packet
is embedded byte-for-byte via `exiftool -xmp<=`, which is what lets the region
fixtures pin element order.

The HEIFs carry **no pixels**: the metadata reader never decodes, and a real
HEVC payload would cost more than the whole 2 MB fixture budget. Their Exif
item is lifted out of a JPEG exiftool wrote in the same run, so one invocation
is the source of both files' EXIF.

| group | count | covers |
|---|---|---|
| `exif/` | 7 | date fallback chain, subseconds + offset dropped, `0000:00:00`, hour 24, month 13, no EXIF |
| `gps/` | 5 | N/E, S/W with altitude ref, latitude-only, missing refs, lowercase refs |
| `xmp/` | 7 | embedded TagsList, competing tag vocabularies, CountryCode + IPTC namespace conflict, embedded regions in both orders, everything-at-once |
| `sidecar/` | 16 | sidecar-only, every-field conflict, region/country gap filling, ignored dates+GPS, alternate prefix, attribute-bearing open tag, empty entries, case dedup, UTF-16, rdf:Bag, truncated, garbage, `mwg-rs` with no areas |
| `regions/` | 9 | digiKam vs exiftool ordering, name as attribute, element-form coordinates, unit variants, name beyond the look-behind window, malformed first/last, non-numeric coords, unnamed |
| `containers/` | 10 | PNG, PNG+XMP, zero byte, truncated, wrong extension both ways, and four HEIFs — XMP item, Exif item, both at once, `mif1`-major brand |
| `names/` | 4 | spaces, parentheses, emoji, uppercase extension, multiple dots |
| `video/` | 6 | QuickTime `©day` with UTC / non-UTC offset / no offset / absent, QuickTime-branded `.mp4`, ISO-branded `.mp4` |

~90 files, ~75 KB total.

## The landmines, in one place

Everything below is **pinned as-is**. A Rust implementation that "fixes" any of
it diverges from the shipped app.

### Metadata

1. **MWG region names are shifted by one whenever `<mwg-rs:Area>` precedes
   `<mwg-rs:Name>`.** The parser finds each Area, then searches *backwards* for
   the nearest name — which in that ordering is the previous region's. Region 0
   ends up unnamed and the last name is lost.
2. **…and that is the only ordering embedded XMP ever produces.** ImageIO
   re-serialises struct fields alphabetically in
   `CGImageMetadataCreateXMPData`, so `Area` always precedes `Name` regardless
   of how the file was written: *every* embedded region in this app is
   currently mis-named. Only the sidecar path gets names right.
3. **An unterminated `<mwg-rs:Area` that is followed by a well-formed one
   swallows it.** The look-ahead for `</mwg-rs:Area>` reaches across into the
   next region; the coordinates come from the malformed Area and the second
   region disappears. If the malformed Area is *last*, it is simply skipped.
4. **The name look-behind window is 2000 characters.** A verbose serialisation
   can push the name out of range and the region comes back unnamed.
5. **`stArea:unit`**: absent is accepted, `"normalized"` is accepted
   case-insensitively, anything else drops the region.
6. **Only `digiKam:TagsList` feeds tags.** `lr:hierarchicalSubject` and
   `dc:subject` are invisible even when they disagree. The match is on the
   *leaf name* `TagsList`, so any namespace declaring one would also be read.
7. **`CountryCode` is also matched by leaf name**, so IPTC's
   `Iptc4xmpCore:CountryCode` competes with `photo-tools:CountryCode`; the
   first tag ImageIO enumerates wins. Values are uppercased.
8. **A sidecar contributes exactly three things**: `digiKam:TagsList`,
   `photo-tools:CountryCode` (or `phototools:`), MWG regions. Dates and GPS in
   a sidecar are ignored entirely.
9. **Sidecar-vs-embedded precedence**: tags are a union with the embedded ones
   first and a case-insensitive first-wins dedup (so the *embedded* spelling
   survives a conflict); `countryCode` prefers embedded; `faceRegions` are
   replaced wholesale by the sidecar when it has any, and left alone when it
   has none.
10. **EXIF date parsing is strict about months and days but lenient about
    hours.** `0000:00:00 00:00:00` and `2021:13:45` are rejected and fall
    through to the next candidate; `2021:07:04 24:00:00` is accepted and rolls
    into 2021-07-05T00:00:00.
11. **Subseconds and `OffsetTimeOriginal` are dropped.** The format string is
    exactly `yyyy:MM:dd HH:mm:ss`.
12. **EXIF dates are interpreted in the *device* time zone** (no `timeZone` on
    the formatter). The fixture therefore records a wall clock, not an instant.
13. **A zone-less QuickTime `©day` is read as UTC**, not device-local — so the
    image and video date paths disagree about what a zone-less timestamp means.
    The video fixture records UTC instants.
14. **GPS refs are compared case-sensitively** (`latRef == "S"`). Raw lowercase
    `"s"`/`"w"` do not negate. Both coordinates are required; a lone latitude
    yields nothing. Altitude and its ref are never read. A southern zero
    latitude serialises as `-0`.
15. **AVFoundation only honours `moov/udta/©day` for QuickTime-branded
    files.** The same atom in an ISO-branded `.mp4` reads as nil. A Rust atom
    parser that accepts it unconditionally is *more* permissive than the
    baseline — a behaviour change, not a bug fix.
16. **ImageIO sniffs content, the scanner sniffs extensions.** A PNG named
    `.jpg` is read fine by `MetadataReader` but classified by `UTType`; a JPEG
    named `.txt` never reaches the scanner at all.
17. **A truncated or non-XML sidecar yields zero tags silently** — there is no
    error surface, the photo just looks untagged.

### Scanner

18. **The light-scan blind spot is total.** For a URL already in the cache the
    classify pass reuses the cached size and mtime and never stats the file, so
    a light scan can *never* detect a change to a file it already knows — not
    even a size change. Only a full scan stats.
19. **Neither scan kind hashes content.** A rewrite that preserves size *and*
    mtime is invisible to both.
20. **A directory whose listing throws is excluded from removal accounting.**
    Its photos vanish from `flatPhotos` but must not appear in `removedURLs`,
    or a transient I/O error wipes a subtree's tags and enrichment. The
    directory still becomes a (photo-less) node — it is stat-able even when it
    is not listable.
21. **Subdirectory order is specified**, ascending by
    `localizedStandardCompare` (implemented as a descending sort pushed onto a
    DFS stack). **Within-folder photo order is not** — it is the raw
    `contentsOfDirectory` order. The fixtures sort those lists and say so; the
    port may emit any within-folder order, but must keep the folder order.
    `coverPhotoURL` is `photos.first`, i.e. also unspecified — the fixture
    records the *rule* (`ownPhotos` / `subfolder:<name>` / `none`), not the URL.
22. **A standalone video's `filename` is lowercased** (`Clip.MOV` → `"clip"`),
    because that branch assigns `videoStem(url)`. An image keeps its case.
23. **A video never gets a sidecar manifest row.** The manifest is emitted only
    inside the image loop, so `Clip.MOV.xmp` is silently ignored.
24. **The sidecar manifest keys on the lowercased *full* basename**:
    `IMG_1234.heic` → `IMG_1234.heic.xmp`, and `dotted.name.v2.jpg` →
    `dotted.name.v2.jpg.xmp`.
25. **`.skipsHiddenFiles`** drops dotfiles; extension-less files and unknown
    extensions are skipped; an orphan `.xmp` produces nothing.

### Unicode (pinned by `PathNormalizationTests`)

26. **`URL.path` and `URL.standardized.path` preserve the on-disk bytes;
    `URL.standardizedFileURL.path` and `resolvingSymlinksInPath().path`
    DECOMPOSE them.** `PhotoFile.stableID` hashes `standardized.path`, so ids
    follow the on-disk spelling — but `FolderScanner.failedDirectoryPaths` (and
    the Store's carry-forward prefix check) go through `standardizedFileURL`
    and are therefore NFD. Both sides of that comparison normalize the same
    way, so it is internally consistent; a byte-exact Rust implementation is
    consistent too. Mixing the two is what breaks.
27. **Anything written through a Foundation path API lands on disk
    decomposed.** A library created *by this app* is all-NFD; NFC names only
    arrive from outside. That is why the fixture tree is built with `open(2)`
    and byte-exact names.
28. **APFS is normalization-insensitive**: both spellings of `café.jpg` are one
    directory entry, and the entry keeps the spelling it was *created* with. So
    a single folder can never hold both, and the NFC/NFD id divergence pinned by
    `stable_uuid_vectors.json` is a cross-filesystem concern.
29. **Swift's `String ==` is canonical equivalence**, so comparing paths cannot
    detect a normalization change. That is why every scanner photo record
    carries a `pathNormalization` token (`ascii` / `NFC` / `NFD`) — an ASCII
    string the comparison *can* see. Rust's `==` is byte equality and does not
    need the crutch, but must keep emitting the token.

## What the fixtures do *not* pin

Cases the Rust port had to decide for itself, listed so the next person knows
these are judgement calls rather than observations. Each is implemented the
conservative way — the one that refuses rather than the one that guesses.

| area | undecided | port's reading |
|---|---|---|
| EXIF hour | anything above 24 | rejected (`25:00:00` → nil). 24 rolls, as pinned |
| EXIF minute/second | 60+ | rejected |
| EXIF trailing junk | `"2021:07:04 08:09:10 extra"` | rejected; the string must be exactly 19 chars |
| GPS | a coordinate with fewer than 3 rationals | missing components read as 0 |
| region name lookback | the 2000 "characters" on a non-ASCII packet | counted in Unicode scalars, not grapheme clusters |
| embedded regions | a malformed packet | a packet that does not parse yields no regions at all |
| embedded XMP | a HEIF item using `construction_method` 1 or 2 | **not followed** — the `idat` and item-relative forms are legal, nothing that writes this metadata emits them, and a form nothing exercises is a form nothing checks. See `gallery-meta/src/media/isobmff.rs` |
| `localizedStandardCompare` | locale-sensitive collation | Unicode order with numeric runs and case folding; no ICU |
| extension table | anything outside `assets/` | a curated list in `gallery-scan/src/classify.rs`, erring narrow |
| `DownloadStatus` | `downloading` / `stale` | collapsed into `placeholder`; nothing in the app reads them. The Swift probe collapses them at the boundary too (`status != .local`), so a manifest row is now only ever `local` or `placeholder`. |
| GPS last bits | rational→float folding order | the port's values differ from ImageIO's by **one ULP** on two fixture files (`gps/south_west.jpg`, `gps/zero_and_lowercase_ref.jpg`) — 1e-14 degrees. The Rust host test compares at 1e-9; the byte-exact Swift fixture records the port's numbers, with a note on each entry saying so. |
