# WP4 — Tag-reader interop with mainstream photo apps

Goal: extend `MetadataReader` so LocalGallery can surface people, place,
landmark, object, and scene tags written by the major photo-management
tools — not just photo-tools' own output. The model
(`HierarchicalTag` + the five taxonomy roots) stays as-is; the work is
in the *input layer* — multi-source XMP parsing and a normalizer that
flattens foreign conventions into the existing slash-separated path
form.

File paths and line numbers reflect the branch state at plan authoring;
expect drift after each pass.

---

## Design summary

- **Single-source today.** `MetadataReader.readImageMetadata`
  (LocalGallery/Services/MetadataReader.swift:22) reads exactly two tag
  fields: `digiKam:TagsList` (slash-separated paths) and
  `photo-tools:CountryCode`. Face regions come from
  `mwg-rs:RegionInfo`. Everything downstream — search, tag picker,
  contact linking, place clustering — is keyed off the photo-tools
  five-root model in `HierarchicalTag` (LocalGallery/Models/HierarchicalTag.swift:5):
  People, Places, Landmarks, Objects, Scenes.
- **Real-world libraries carry several formats.** A photo round-tripped
  through Lightroom, digiKam, Mylio, or Photo Mechanic will typically
  carry `lr:HierarchicalSubject` (`|`-separated), `dc:subject` (flat),
  `Iptc4xmpCore:Location` + `photoshop:City/State/Country`, and
  optionally `mwg-rs:RegionInfo` for faces. None of those are read
  today, so a Lightroom-tagged photo shows zero tags in LocalGallery.
- **Normalize at read, not at storage.** A small `TagNormalizer`
  rewrites foreign paths into the photo-tools five-root form
  (`Places/Italy/Lazio/Rome`, `People/Alice`, …). The model on disk
  and in-memory stays photo-tools-shaped; downstream code is
  unchanged.
- **Synthesize `Places/...` from IPTC location fields.** This is the
  highest-leverage change: every Lightroom / Bridge / Photo Mechanic /
  Capture One photo carries
  `photoshop:Country/State/City` + `Iptc4xmpCore:Location`. Stitching
  those four fields into a single `Places/Country/State/City/Sublocation`
  path makes Place-based memories and the country flag UI work for
  ~all DAM-tagged libraries with no further changes.
- **Read-only on photos.** The app stays read-only on photo metadata.
  photo-tools remains the only writer in the ecosystem.
- **Out of scope: Windows Photo Gallery / Live Photo Gallery.** Dead
  since 2017; photo-tools doesn't write its fields either (see
  ../photo-tools/docs/xmp-schema.md §1.5). Skipping
  `MicrosoftPhoto:LastKeywordXMP`, `MPRI:Regions`, and
  `MicrosoftPhoto:City/Country` keeps the parser surface small. If a
  user reports a real archive that needs them we can revisit.

---

## What real-world photos carry

Synthesis from the dominant tools (Lightroom Classic + CC, Apple
Photos / iOS camera, digiKam, Adobe Bridge, Capture One, ON1, ACDSee,
Photo Mechanic, Mylio, plus MWG / ExifTool conventions). Each row is
something a reader needs to handle to cover the format in practice.

### Hierarchical keywords

| Field | Separator | Written by |
| --- | --- | --- |
| `digiKam:TagsList` | `/` | digiKam, photo-tools (already supported) |
| `lr:HierarchicalSubject` | `\|` | Lightroom Classic, Bridge, Capture One, ON1, Mylio, ACDSee, photo-tools |
| `mediapro:CatalogSets` | `\|` | iView Media Pro, Expression Media, digiKam ≥7.7 |
| `acdsee:Categories` | nested XML tree (`<Category Assigned="0\|1">`) | ACDSee |
| `acdsee:Keywords` | `\|` (path inside a flat string) | ACDSee |
| `dc:subject` containing `/` or `\|` | both seen | Bridge with "Write Hierarchical Keywords" enabled |

### Flat keywords

- `dc:subject` — universal.
- `IPTC:Keywords` — legacy IIM, still read by everyone.

### People / face regions

- `mwg-rs:RegionInfo` (already supported) — Lightroom, digiKam,
  Mylio, Apple iPhone capture, ACDSee mirror.
- `acdsee-rs:Regions` — same shape as MWG, different namespace URI;
  ACDSee.
- `Iptc4xmpExt:PersonInImage` — Bag of names, no coordinates;
  Photo Mechanic, Mylio, photo-tools projection, osxphotos.
- Plus the existing `People/<Name>` convention as a hierarchical entry.

### Location

- `kCGImagePropertyGPS*` (already supported).
- `Iptc4xmpCore:Location` (sublocation), `Iptc4xmpCore:CountryCode`.
- `photoshop:City`, `photoshop:State`, `photoshop:Country`.
- `Iptc4xmpExt:LocationShown` / `LocationCreated` — structured
  (Sublocation, City, ProvinceState, CountryName, CountryCode,
  WorldRegion); Photo Mechanic, recent Lightroom.

### Landmarks / scene / object recognition

No standardized field. Auto-tagging tools (ACDSee, ON1, Mylio,
photo-tools) emit them as ordinary hierarchical keywords (e.g.
`Landmarks/Colosseum`). Nothing extra to read — they ride the
hierarchical-keyword channel above.

### Sidecar quirks

- Mylio, ON1, Capture One, digiKam often write *only* to a sidecar.
- `.xmp` case variants (`.XMP`) on Windows-originated files.
- Lightroom's default sidecar for raw files strips the original
  extension (`IMG_1234.xmp` instead of `IMG_1234.NEF.xmp`). photo-tools
  already documents this read-side compatibility (see
  ../photo-tools/docs/xmp-schema.md §1.4).
- ON1's `.on1` is proprietary — skip.

### Interop conflicts to keep in mind

- **Pipe vs slash.** `lr:HierarchicalSubject` and `mediapro:CatalogSets`
  use `|`; `digiKam:TagsList` uses `/`. Bridge sometimes writes `/`
  paths into `dc:subject`. Normalizer must handle both.
- **Region coordinate origin.** MWG `stArea:x/y` is centre-relative,
  normalized 0–1. `acdsee-rs` follows MWG. Existing parser is correct;
  no change needed for the formats we plan to read.
- **Sidecar vs embedded.** Current code: sidecar wins for tags,
  embedded wins for country code. Extend: union flat keywords and
  hierarchical entries across both sources (different writers omit
  different fields); for IPTC location fields, prefer the more
  specific source (sidecar over embedded only when sidecar has the
  field at all).
- **digiKam writes the same path 3–4 times** in different namespaces.
  The existing case-insensitive path dedup handles this once paths are
  separator-normalized.

---

## Architecture

### 1. Split `MetadataReader` into source parsers + normalizer

`MetadataReader` becomes an orchestrator that calls per-source parsers
and a normalizer:

```
MetadataReader.readImageMetadata(url)
  → CGImageSource read
  → for each known XMP source: parse into RawTagRecord
  → readXMPSidecar (multi-path) → merge into RawTagRecord
  → TagNormalizer.normalize(RawTagRecord) → existing Result tuple
```

Where:

```swift
struct RawTagRecord {
    var flatKeywords: [String]                   // dc:subject + IPTC:Keywords
    var hierarchicalEntries: [HierarchicalEntry] // source kept for diagnostics
    var faceRegions: [FaceRegion]                // already exists
    var personNames: [String]                    // iptcExt:PersonInImage
    var location: LocationFields                 // see §3
    var countryCode: String?
    var gpsLat: Double?
    var gpsLon: Double?
}

struct HierarchicalEntry {
    let path: [String]      // already split + Titlecased + namespace-promoted
    let source: TagSource   // .digiKam, .lightroom, .mediaPro, .acdseeKeywords, .acdseeCategories, .bridgeFlat
}
```

`Result` (LocalGallery/Services/MetadataReader.swift:9) keeps its
existing shape so callers (`FolderScanner`, `EnrichmentService`)
don't change.

### 2. New `TagNormalizer`

Pure functions. Two responsibilities:

**a) Path normalization** for hierarchical entries:

- Replace `|` separators with `/`.
- Trim whitespace per segment, drop empty segments.
- Apply Titlecase to roots so `people/alice` and `People/Alice` collide
  on dedup. Leaf casing is preserved (the writer's choice usually
  matches photo-tools' Titlecase rule).
- **Namespace promotion** — rewrite the first segment when foreign
  conventions don't match our five roots:
  - `Person`, `Persons`, `Faces` → `People`.
  - `Location`, `Locations`, `Place` → `Places`.
  - `Landmark` → `Landmarks`.
  - `Object` → `Objects`.
  - `Scene` → `Scenes`.
  - First segment already one of the five roots (case-insensitive) →
    keep, normalized to canonical Titlecase.
  - Otherwise → leave the path as-is. It's a flat foreign hierarchy
    (e.g. an event-organized library); the user still gets to search
    on it, but it doesn't get a namespace icon.

**b) Dedup** across all sources by case-insensitive joined path. The
existing dedup loop in `MetadataReader` (lines 95–102) moves into
`TagNormalizer.normalize` and keys off the post-normalization path.

### 3. Synthesize `Places/...` from IPTC location fields

Add `LocationFields` struct populated by a new `IPTCLocationParser`:

```swift
struct LocationFields {
    var sublocation: String?      // Iptc4xmpCore:Location, Iptc4xmpExt:LocationShown[1]/Sublocation
    var city: String?             // photoshop:City, LocationShown[1]/City
    var state: String?            // photoshop:State, LocationShown[1]/ProvinceState
    var country: String?          // photoshop:Country, LocationShown[1]/CountryName
    var countryCode: String?      // Iptc4xmpCore:CountryCode, LocationShown[1]/CountryCode
}
```

Source priority: `Iptc4xmpExt:LocationShown[1]` (most specific) >
`photoshop:*` + `Iptc4xmpCore:*`. Sidecar overrides embedded when the
field exists.

Then in `TagNormalizer.synthesizePlaces(from:)`:

1. If a `Places/...` hierarchical entry already exists (from a
   tagger that wrote one explicitly, e.g. photo-tools or digiKam),
   *don't* synthesize — trust the curated tag.
2. Otherwise, build `["Places", country, state, city, sublocation].compactMap`
   and emit it as a synthesized `HierarchicalEntry` with
   `source = .syntheticIPTC`.
3. `countryCode` falls back to `LocationFields.countryCode` when
   `photo-tools:CountryCode` is absent (current behavior preserved
   when present).

This is the highest-impact change for users coming from Lightroom /
Bridge / Capture One / Photo Mechanic / Mylio.

### 4. Face-region multi-source

Extend `parseMWGRegions` (LocalGallery/Services/MetadataReader.swift:209)
into a `RegionParser` namespace that runs on the same XMP string and
returns the union:

- `parseMWGRegions` (unchanged).
- `parseAcdseeRegions` — same shape, different namespace prefix
  (`acdsee-rs:` instead of `mwg-rs:`).
- `parseIptcExtPersonInImage` — names without coordinates; emitted as
  `People/<Name>` hierarchical entries (no `FaceRegion`), so
  `ContactLinker` keeps working without touching the face-crop path.

Merge by `(name, IoU > 0.7)` to dedup MWG vs acdsee-rs duplicates.
Names without rectangles never collide with named rectangles.

### 5. Sidecar discovery

Extend `readXMPSidecar` (LocalGallery/Services/MetadataReader.swift:154):

- Try `<file>.xmp` (current), `<file>.XMP`, then `<basename>.xmp`
  (Lightroom's raw-sidecar default — drop the original extension).
  First hit wins.
- Skip `.on1`.
- Sidecar-vs-embedded merge policy moves into `RawTagRecord.merge` —
  union for keyword/region/person fields, sidecar-wins for scalars
  (country code).

### 6. Diagnostics

Add a row in the per-photo EXIF/diagnostics panel listing tag
provenance: "5 tags from `lr:HierarchicalSubject`, 1 from
`digiKam:TagsList`, 1 synthesized from IPTC location". Cheap to
compute since `RawTagRecord.hierarchicalEntries` carries `TagSource`.
Helpful for users debugging mixed-tool libraries.

No new user-facing settings in v1 — defaults should "just work."
Optional later: a toggle to disable IPTC→Places synthesis if a user
has curated `Places/*` tags and explicitly doesn't want auto-derived
ones added.

---

## File-level impact

| File | Change |
| --- | --- |
| `LocalGallery/Services/MetadataReader.swift` | Slim down to orchestrator. Move per-source parsing out. |
| **new** `LocalGallery/Services/TagSourceParser.swift` | One function per source: `parseLightroomHierarchical`, `parseDigiKamTagsList` (existing, moved), `parseMediaProCatalogSets`, `parseAcdseeKeywords`, `parseAcdseeCategories` (real XML walker — `XMLParser`), `parseDcSubject`, `parseIptcKeywords`. |
| **new** `LocalGallery/Services/TagNormalizer.swift` | Pure functions: separator normalization, namespace promotion, dedup, IPTC→Places synthesis. |
| **new** `LocalGallery/Services/RegionParser.swift` | Existing `parseMWGRegions` + new `parseAcdseeRegions` + `parseIptcExtPersonInImage`. |
| **new** `LocalGallery/Services/IPTCLocationParser.swift` | `LocationFields` struct + parsers for `Iptc4xmpCore:*`, `photoshop:*`, `Iptc4xmpExt:LocationShown`. |
| `LocalGallery/Models/HierarchicalTag.swift` | No model change. Optionally add `init(segments:)` so the normalizer doesn't re-stringify. |
| `LocalGallery/Services/EnrichmentService.swift` | Unchanged — still consumes the `Result` tuple. |
| `LocalGallery/Services/SidecarSyncService.swift` | Re-route `parseXMPBytes` calls to the new entry point if the function moves. |
| `LocalGallery/Models/FaceRegion.swift` | No change — coordinate convention stays MWG centre-normalized. |
| `LocalGallery/Views/EXIFPanelView.swift` | Add tag-provenance section (small). |
| **new** `LocalGalleryTests/TagInteropFixtures/` | Real sample XMPs from each app. A half-dozen real samples is far more valuable than synthetic ones. |
| **new** `LocalGalleryTests/TagNormalizerTests.swift` | Unit tests on the normalizer with the fixtures above. |

---

## Rollout order

Each step is its own PR; each is independently shippable.

1. **TagNormalizer + multi-source hierarchical reader.**
   `lr:HierarchicalSubject`, `mediapro:CatalogSets`, `dc:subject` with
   `/` or `|`. Highest hit-rate. Doesn't touch face regions or
   location.
2. **IPTC location → `Places/...` synthesis.** Touches MemoryEngine
   indirectly via the GPS-clustering fallback paths — verify "home"
   detection still behaves on photos that gain a synthesized
   `Places/Country/State/City` path.
3. **Face-region multi-source.** `acdsee-rs`, `iptcExt:PersonInImage`.
4. **`acdsee:Categories` XML walker.** Smaller user base; defer.
5. **Sidecar path variants + diagnostics row.** Small PR.

---

## Things explicitly out of scope

- **Writing** any of these formats. Read-only on photo metadata.
- **Microsoft Photo Gallery / Windows Live Photo Gallery formats.**
  `MicrosoftPhoto:LastKeywordXMP`, `MPRI:Regions`,
  `MicrosoftPhoto:City/Country`. Dead since 2017; photo-tools
  doesn't write them either.
- **Apple Photos library import.** Apple Photos doesn't embed
  people on export; that's a separate `osxphotos`-shaped problem.
- **OCR text.** photo-tools writes OCR to `photo-tools:OCRText` and
  IPTC `ImageRegion` (see ../photo-tools/docs/xmp-schema.md §2.6),
  not as keyword tags. Reading OCR text into LocalGallery search
  is its own work package; it's not part of the
  people/object/scene/location/landmark interop story.
- **MWG digest reconciliation** for `dc:subject`/`IPTC:Keywords`.
  Most readers ignore it; we union both. Documented, not implemented.
- **`acdsee:Categories` `Assigned="0"` ancestors.** Treated as "not
  assigned to this photo," consistent with ACDSee's UI. Only emit
  categories with `Assigned="1"`.

---

## References

- ../photo-tools/docs/xmp-schema.md — canonical photo-tools schema.
  §1.1 keyword fields, §1.3 IPTC structured location, §1.5 fields
  photo-tools deliberately doesn't write, §2 taxonomy.
- [Lightroom XMP schema](https://exiv2.org/tags-xmp-lr.html)
- [digiKam XMP schema](https://exiv2.org/tags-xmp-digiKam.html)
- [iView MediaPro schema](https://exiv2.org/tags-xmp-mediapro.html)
- [MWG Regions schema](https://exiv2.org/tags-xmp-mwg-rs.html)
- [ExifTool MWG composite tags](https://exiftool.org/TagNames/MWG.html)
- [MWG Guidelines 2.0 (PDF)](https://s3.amazonaws.com/software.tagthatphoto.com/docs/mwg_guidance.pdf)
- [Adobe Bridge nested keywording](https://helpx.adobe.com/bridge/kb/nested-hierarchal-keywording-bridge.html)
- [ACDSee hierarchical keywords help](https://help.acdsystems.com/en/acdsee-pro-3-mac/Content/1Topics/2_Manage_mode/Organizing/hierarchical_keywords.htm)
- [acdsee-rs faces (ExifTool forum)](https://exiftool.org/forum/index.php?topic=15376.0)
- [Mylio: Understanding XMP files](https://manual.mylio.com/24.3/en/topic/understanding-xmp-files)
- [Photo Mechanic IPTC/XMP preferences](https://camerabits.freshdesk.com/support/solutions/articles/48001146198-iptc-xmp-preferences)
- [IPTC Photo Metadata User Guide](https://www.iptc.org/std/photometadata/documentation/userguide/)
- [IPTC Extension schema](https://exiv2.org/tags-xmp-iptcExt.html)
