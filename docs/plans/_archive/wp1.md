# WP1 — User-testing polish & bugfixes

Source: [`docs/todo.md`](../todo.md). Four sequential passes, each landable as
its own PR. File paths/line numbers are anchored to the branch state at plan
authoring; expect drift after each pass.

---

## Pass 1 — Memories: engine, naming & diagnostics

### 1.1 Drop person-over-time memories
`MemoryEngine.swift:124-152` — delete the entire "Person Through the Years"
candidate generation block. Birthdays remain the only people-driven memory.
No model changes (`MemoryType.personOverTime` can stay in the enum for cache
back-compat; just stop generating new ones).

### 1.2 "Me" person concept
- Add `@AppStorage("mePersonPath") private var mePersonPath: String = ""` on
  `GalleryStore` (path = the `People/<name>` `fullPath`, empty = unset).
- Surface helpers on the store:
  - `var mePersonPath: String?` (nil-coerced getter)
  - `func markAsMe(_ personPath: String)`
  - `func unmarkAsMe()`
  - `func isMe(_ personPath: String) -> Bool`
- Add menu items in `CollectionsView.swift:272-289` `peopleRail` context menu:
  - `"Mark as Me"` (when not me) / `"Unmark as Me"` (when currently me).
  - Place above the Hide entry so it sits with identity-related actions.
- Add a Settings row under the People section in `SettingsView.swift:47-73`:
  - `"Me"` LabeledContent showing the current me person's `displayName` (or
    "Not set"). Tapping navigates to a small picker view listing all people
    tags so the user can change/clear it without going through the rail.

### 1.3 Trip naming changes
All in `MemoryEngine.tripLabel` (`MemoryEngine.swift:667-700`) and
`flushTrip` (`MemoryEngine.swift:510-591`).

**90% country rule (naming-only, photo set unchanged):**
- In `tripLabel`, before the existing multi-country branch, compute the
  dominant country: `let total = countryCounts.values.reduce(0, +)` and
  `let (topCode, topCount) = countryCounts.max(by: { $0.value < $1.value })`.
- If `Double(topCount) / Double(total) >= 0.90`, return that country's name
  immediately — even if the trip technically touches 2+ countries.
- Below the 90% bar, fall through to current logic.

**"Chile with X, Y, Z" person suffix:**
- New helper on `MemoryEngine`:
  ```swift
  static func tripPeopleSuffix(
      for photos: [PhotoFile],
      mePersonPath: String?,
      maxNames: Int = 3
  ) -> String?
  ```
  - Count `People/*` tags across `photos`, drop entries whose `fullPath`
    matches `mePersonPath`.
  - Sort by photo count desc, take top `maxNames`.
  - Apply first-name-with-disambiguation rules from §1.4 to each name.
  - Return `nil` when the suffix would be empty.
  - Format: `"Anna"`, `"Anna & Bob"`, `"Anna, Bob & Charlie"`.
- In `flushTrip`, after computing `locationLabel`:
  ```swift
  let title: String
  let base = locationLabel.map { "A trip to \($0)" } ?? "A trip"
  if let people = MemoryEngine.tripPeopleSuffix(
      for: sorted.map(\.0),
      mePersonPath: mePersonPath
  ) {
      title = locationLabel.map { "\($0) with \(people)" } ?? "A trip with \(people)"
  } else {
      title = base
  }
  ```
- Sub-trips (`MemoryEngine.swift:577`) get the same treatment.
- `mePersonPath` is plumbed in as a new parameter on `MemoryEngine.generate`
  and forwarded to `generateTripMemories` / `flushTrip`. `GalleryStore` reads
  its `mePersonPath` and passes through.

### 1.4 First-name + last-initial disambiguation
- New helper on `MemoryEngine`:
  ```swift
  /// Reduce full "First Last" tag display names to the shortest unambiguous
  /// form. Tags that are already single words pass through unchanged.
  static func disambiguateFirstNames(_ names: [String]) -> [String]
  ```
  Algorithm:
  1. Split each name on whitespace; capture `(first, lastInitial?)`.
  2. Group by lowercased first name. Single-element groups → return `first`.
  3. Multi-element groups where last-initials differ → return
     `"\(first) \(lastInitial)."` for each.
  4. Multi-element groups with no last name OR same last initial → return
     `first` (we accept ambiguity rather than invent disambiguators).
- Used in `tripPeopleSuffix` and any future people-in-title formatting.
- Birthday memory titles (`MemoryEngine.swift:455`) **keep the full
  displayName** — users want explicit recognition for the birthday person.

### 1.5 In-app log viewer (port from compass)

**New files (mirror compass structure):**

- `LocalGallery/Services/LogStore.swift` — port from
  `compass/Compass/Services/LogStore.swift`:
  - `@Observable final class LogStore: @unchecked Sendable` with
    `nonisolated(unsafe) static let shared`.
  - Capped at 5,000 entries (drop-oldest).
  - `Entry { id, timestamp, level, category, message }` with
    `Level: { debug, info, warning, error }`.
  - `func append(level:category:message:)` thread-safe via main-queue
    dispatch (compass pattern).
  - `var asText: String` for copy/share.
- `LocalGallery/Views/Settings/LogsView.swift` — port from
  `compass/Compass/Views/Settings/LogsView.swift`:
  - List with `ScrollViewReader` + auto-follow toggle.
  - `.searchable` for message/category filter.
  - Filter menu (level dropdown).
  - Toolbar buttons: follow toggle, copy, share-as-file.

**Wire it into existing `os.Logger` calls — don't duplicate logging:**

- Modify `LocalGallery/Logging.swift`:
  - Keep the `Log` namespace and existing `Logger` instances as-is so existing
    call sites don't change.
  - Add a thin tee layer that mirrors every Logger call into `LogStore.shared`.
    Cleanest path: replace each `Logger` field with a custom wrapper struct
    `TeeLogger` that exposes `debug/info/notice/warning/error` matching
    `os.Logger`'s API surface (the methods we actually use), forwarding to
    both `os.Logger` and `LogStore.shared.append(...)`.
  - Audit current call sites with `Grep "Log\\.[a-z]+\\."` to confirm coverage
    before swap.

**High-frequency safety:**

- Compass model already handles bursts (cap + drop-oldest). Two tweaks for
  this app:
  - **Coalesce repeated identical messages** — if the last entry has the same
    `(level, category, message)`, increment a `repeatCount` on the existing
    entry instead of appending. Display as `"× N"` suffix in the row. Avoids
    walls of identical scan logs flooding the buffer.
  - **Throttle main-queue dispatches** — if the call is already on the main
    thread, `insert` synchronously (compass already does this). Off-thread
    bursts coalesce naturally because of the dispatch hop.

**Settings entry:**

- Add at the bottom of `SettingsView` (`SettingsView.swift:75`), in a new
  `Section("Developer")`:
  ```swift
  NavigationLink("Logs") { LogsView() }
  ```

### 1.6 Verbose memory generation logging

In `MemoryEngine.generate`, add `Log.memory.info(...)` calls (now flowing
through the tee) at:

- Pipeline entry: total photos, leaf folder count, contacts count, seed,
  count of seen IDs.
- After each candidate-generation step: `"<step>: produced N candidates"`
  with brief details — e.g. trip detection logs each segment with country
  code, day span, photo count, dominant-country %.
- Selection: log each of the final top-10 with `id`, `score`,
  `jitteredScore`, whether it was deprioritised for being seen.
- Skipped: when a candidate is dropped by the overlap filter, log the id +
  overlap ratio. When 90% country rule fires, log `"Trip <key>: 90% rule →
  <country>"`.

These logs are debug-quality — keep them at `.info` level so they show in
the in-app viewer by default but can be filtered down.

### 1.7 Acceptance — Pass 1
- Memories rail no longer surfaces "<name> over the years".
- A trip with ≥90% photos in one country is titled as that country alone.
- Trip titles end with `" with Anna, Bob & Charlie"` (top 3 by photo count,
  excludes "me", first names with last-initial disambig).
- Settings → Developer → Logs shows live logs; filter, copy, share work;
  buffer is bounded; rapid-fire identical logs collapse.

---

## Pass 2 — Memory slideshow polish

All in `LocalGallery/Views/MemorySlideshowView.swift`.

### 2.1 Date+location pill, centered
- Drive from the **current** photo, not the memory:
  ```swift
  private var currentPhoto: PhotoFile? {
      guard photos.indices.contains(index) else { return nil }
      return photos[index]
  }
  ```
- Pill content (priority order):
  - Date: `currentPhoto.dateTaken` formatted via existing
    `MemoryEngine.formatDateRange` style (single-day: "5 May 2024").
  - Location: derive from `currentPhoto`:
    - If a `Places/*` path of depth ≥3 exists → `"<city>, <country>"`
      (segments at index 2 and 0 of the leaf-stripped path).
    - Else if depth ≥1 → just country name (via existing
      `MemoryEngine.countryName(from: photo.countryCode)` or top-level
      Places segment).
    - Else, omit location.
  - Joiner: `" · "`. Examples: `"5 May 2024 · Reykjavík, Iceland"`,
    `"5 May 2024 · Iceland"`, `"5 May 2024"`.
- Replace the existing center pill (`MemorySlideshowView.swift:145-163`,
  the music selector). Same styling: `Capsule()` with white 14% opacity
  background, 11pt medium text.
- Falls back to memory `subtitle` only when `currentPhoto` is nil (defensive
  — shouldn't happen).

### 2.2 More menu (replaces music + share)
- Right side of top bar (where "See all" currently lives, see
  `MemorySlideshowView.swift:167-180`): add a `Menu` with 3-dots icon
  before "See all":
  ```swift
  Menu {
      Button { showThemePicker = true } label: {
          Label("Music: \(theme.displayName)", systemImage: "music.note")
      }
      Button { showShareSheet = true } label: {
          Label("Share Photo", systemImage: "square.and.arrow.up")
      }
      // Future: more actions land here.
  } label: {
      Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(Color.white.opacity(0.16), in: Circle())
  }
  ```
- Share sheet uses `currentPhoto.url`.
- "See all" stays where it is.

### 2.3 Music theme diversification

Goal: the six themes feel meaningfully distinct, not just key-shifted pads.

In `LocalGallery/Services/SlideshowMusic.swift`:

- Extend `SlideshowMusicTheme` with per-theme **timbre** params:
  ```swift
  fileprivate struct Timbre {
      let partials: [Partial]      // (multiplier, gain, decayCurve)
      let attackSeconds: Double    // 0.05 = pluck, 4.0 = pad
      let lfoFrequency: Double     // breathing rate
      let lfoDepth: Float          // 0..1
      let detune: Float            // semitone spread between voices
      let hasArpeggio: Bool        // arpeggiate chord tones inside each beat
      let arpInterval: Double      // seconds per arp note (when arpeggio on)
  }
  fileprivate struct Partial { let multiplier: Double; let gain: Float; let decay: Float }
  ```
  The current synth is one fixed (fundamental + sub) recipe — replace it
  with a `Timbre`-driven loop.
- Pick distinct timbres per theme so they sound different at a glance:
  | Theme   | Character                                                              |
  |---------|------------------------------------------------------------------------|
  | wistful | Soft pad, slow attack 3s, sub + 5th partial, slight detune             |
  | bright  | Brighter pad with 3rd + 5th partial gain boost, faster LFO             |
  | hush    | Almost-silent drone, single sine + octave-down, deep LFO               |
  | folk    | **Plucked** arpeggio (attack 0.05, decay 1.5s), no sustain, arp 0.4s   |
  | drift   | Wide-detuned pad (±0.15 semitone), slow LFO, lydian color already set  |
  | hymn    | Organ-ish: 1× + 2× + 3× partials, no LFO, very slow attack             |
- Update `synth` and `renderBuffer` to honor the `Timbre`. For arpeggiated
  themes, instead of stacking all chord tones at once, sequence them by
  `arpInterval` over the chord's duration and apply a per-note ADSR.
- Buffer length: keep one full progression cycle so seamless looping still
  works. Arpeggio repeats land on the chord boundary — pick `arpInterval`
  values that divide `chordDuration` evenly to avoid pops at the loop seam.
- Verify no clipping on each theme; the existing `tanh` soft-clip stays.

### 2.4 Acceptance — Pass 2
- Top bar: close (left) · date+location pill (center) · more menu + see-all
  (right).
- Pill text updates as the slideshow advances through photos with different
  dates/places.
- Music + Share live in the more menu.
- Each music theme is *audibly* distinct on first listen — at minimum, the
  plucked arpeggio (folk) is unmistakable from the pads.

---

## Pass 3 — Photo viewer & sharing

### 3.1 Date+location pill (removes 1/N count)
In `PhotoViewerView.swift:228-233` and `:262-269`:
- Delete the `positionLabel` computed property and its capsule.
- Build the same pill view as §2.1 (extract the formatter into a small
  helper — e.g. a free function `func photoLocationLabel(_:) -> String?`
  in a new `LocalGallery/Views/Helpers/PhotoChrome.swift`, callable from
  both viewer and slideshow).
- Pill sits centered between left × button and right placeholder.

### 3.2 Filmstrip at bottom
Add below the existing bottom share/info row (`PhotoViewerView.swift:277-293`),
above the safe-area inset:
- Horizontal `ScrollView(.horizontal)` with `LazyHStack(spacing: 4)`.
- Each cell: 56×56 `ThumbnailView` (already cached via `ThumbnailService`),
  `cornerRadius: 6`. Selected cell gets a 2pt white stroke + slightly larger
  scale (`scaleEffect(1.08)`).
- Tap → updates `currentPhotoID` (the existing `Binding`); the
  `PagingPhotoView` already animates between ids.
- Auto-scroll the filmstrip to keep the selected cell centered when
  `currentPhotoID` changes:
  ```swift
  ScrollViewReader { proxy in
      ScrollView(.horizontal) { ... }
          .onChange(of: currentPhotoID) { _, id in
              withAnimation(.easeOut(duration: 0.2)) {
                  proxy.scrollTo(id, anchor: .center)
              }
          }
  }
  ```
- Visibility tied to `isChromeVisible` — slides up/down with the rest of
  the chrome.
- Performance: rely on `LazyHStack` + `ThumbnailService`'s 200×200 in-memory
  cache. For libraries with thousands of photos in one viewer context,
  `LazyHStack` only materializes visible cells.

### 3.3 Labeled share + info buttons
In `PhotoViewerView.swift:277-293`, replace the icon-only buttons with pill
buttons matching the Memory slideshow chrome style:
```swift
Button { showShareSheet = true } label: {
    Label("Share", systemImage: "square.and.arrow.up")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.16), in: Capsule())
}
```
Same treatment for Info. Layout: `HStack(spacing: 12)` instead of
`Spacer()`-separated, anchored to `leading` + a trailing spacer (or
centered — match what visually balances).

### 3.4 Share quality menu (Menu, not sheet)
Replace `Button { showShareSheet = true } label: ...` with:

```swift
Menu {
    Button("Original") { share(quality: .original) }
    Button("High (4096px)") { share(quality: .high) }
    Button("Medium (2048px)") { share(quality: .medium) }
    Button("Small (1024px)") { share(quality: .small) }
} label: {
    // same Share pill as above
}
```

`@State private var pendingShareItem: URL?` + `.sheet(item: $pendingShareItem)`
to present the system share sheet once the resized file exists.

**New service** — `LocalGallery/Services/PhotoExporter.swift`:
```swift
enum PhotoQuality: CaseIterable {
    case original, high, medium, small
    var maxEdge: CGFloat? {
        switch self {
        case .original: return nil
        case .high:     return 4096
        case .medium:   return 2048
        case .small:    return 1024
        }
    }
    var jpegQuality: CGFloat {
        switch self {
        case .original: return 1.0
        case .high:     return 0.90
        case .medium:   return 0.85
        case .small:    return 0.80
        }
    }
}

enum PhotoExporter {
    /// Returns the photo URL itself for `.original`. For resized qualities,
    /// renders to a temp JPEG and returns that URL.
    static func export(_ photo: PhotoFile, quality: PhotoQuality) async throws -> URL
}
```

Implementation notes:
- Use `CGImageSource` + `CGImageDestination` (jpeg) for resize — same path
  as `ThumbnailService` would use, no extra deps.
- `kCGImageSourceThumbnailMaxPixelSize = maxEdge` + `kCGImageSourceCreateThumbnailFromImageAlways`
  for fast in-line resize.
- Output filename: `<original-stem>-<quality>.jpg` in
  `FileManager.default.temporaryDirectory`.
- Skip resize entirely for `.original` — just hand back the source URL.
- Videos: `.original` always; the menu disables resize options when
  `currentPhoto.isVideo`.

UI flow on tap:
- Set a small `isPreparingShare = true` state and show a tiny spinner
  overlay if export takes >150ms (most resizes complete sub-100ms).
- On completion, set `pendingShareItem = url` to trigger the share sheet.

### 3.5 Acceptance — Pass 3
- No more "1 / 87" capsule. Top of viewer shows date+location pill.
- Filmstrip across the bottom; tapping a thumbnail jumps the pager.
- Share + Info appear as labeled pills.
- Tapping Share opens a 4-option quality menu; choosing one writes a temp
  JPEG (or hands back original) and presents the system share sheet.

---

## Pass 4 — Collections & event-row hit areas

### 4.1 Read MWG face regions

**Schema reference:** [photo-tools xmp-schema.md §2.1 People + §3 Regions](
../../../photo-tools/docs/xmp-schema.md). digiKam writes `mwg-rs:RegionInfo`
with normalized 0–1 coords; `Area.X`, `Area.Y` are **center**, `Area.W`,
`Area.H` are width/height.

**New model** — `LocalGallery/Models/FaceRegion.swift`:
```swift
struct FaceRegion: Codable, Hashable, Sendable {
    /// Person tag display name (matches `People/<name>` leaf), or nil for
    /// unnamed regions.
    let name: String?
    /// Center X in [0, 1], image-space, top-left origin.
    let centerX: Double
    /// Center Y in [0, 1], image-space, top-left origin.
    let centerY: Double
    /// Width in [0, 1].
    let width: Double
    /// Height in [0, 1].
    let height: Double
}
```

**Add to `PhotoFile`** (`LocalGallery/Models/PhotoFile.swift`):
- New stored property `var faceRegions: [FaceRegion] = []`.
- Add to `CodingKeys`, `init(...)`, and `init(from:)` (with `?? []` fallback
  so older cached payloads decode).

**Reader changes** in `MetadataReader.swift`:
- Extend `Result` typealias to add `faceRegions: [FaceRegion]`.
- In `readImageMetadata`, walk `CGImageMetadataCopyTags` looking for the
  `mwg-rs:RegionInfo` structured tag. The `RegionList` is a `Bag` of
  region structs; each region has `mwg-rs:Name` + nested `mwg-rs:Area`
  with `stArea:x/y/w/h/unit`. Only accept entries with
  `Area.unit == "normalized"`.
- Sidecar: add an `mwg-rs:RegionInfo` block parser to `readXMPSidecar`.
  Use a small SAX-style scan rather than full XML — same regex/range
  approach as the existing TagsList parser.
- Both paths feed into the same `[FaceRegion]` returned in the result.

**Wire through enrichment + scan:**
- `FolderScanner` and `EnrichmentService` consume the `Result` tuple — extend
  to forward `faceRegions` into `PhotoFile.faceRegions`.
- Bump `LibraryCacheStore` cache version (find the `version: Int` constant)
  so previously-cached payloads get re-enriched and pick up regions.

### 4.2 Person thumbnail auto-zoom

In `LocalGallery/Components/ThumbnailView.swift` (or a new
`PersonThumbnailView` if injecting a crop into the existing view is messy):

- Accept an optional `crop: CGRect?` parameter (image-space, normalized).
- When set, after loading the full image, crop using the rect with **2× the
  region size as padding on each side**:
  ```
  paddedRect = CGRect(
      x:  region.centerX - region.width  * 1.5,   // 0.5 (region) + 1.0 (padding)
      y:  region.centerY - region.height * 1.5,
      w:  region.width  * 3.0,                    // 1.0 region + 2*1.0 padding
      h:  region.height * 3.0
  )
  ```
  (Per the user's clarification: `[x(padding) – 2x(face region) – x(padding)]`
  on each axis. Region width = 1, padding = region width on each side, total
  span = 3× region width.)
- Clamp `paddedRect` to `[0, 1]²` before converting to pixel coords.
- If the padded crop would be smaller than the requested thumbnail size after
  clamping, fall back to fit-not-fill and overlay a softer center crop.

### 4.3 Featured-photo ranking
In `GalleryStore.featuredPhoto(for:)` (`GalleryStore.swift:743-748`):

Today the fallback is `.first`. Replace with a ranking pass when no manual
featured photo is set:

```swift
private func bestFeaturedPhoto(forPersonPath path: String, displayName: String) -> PhotoFile? {
    let now = Date()
    let candidates = searchService.photos(matchingPersonPath: path)  // existing or new
    return candidates.max { a, b in
        score(for: a, person: displayName, now: now)
            < score(for: b, person: displayName, now: now)
    }
}

private func score(for photo: PhotoFile, person: String, now: Date) -> Double {
    let region = photo.faceRegions.first { $0.name?.lowercased() == person.lowercased() }
    let area = region.map { $0.width * $0.height } ?? 0
    let recencyDays = photo.dateTaken.map { now.timeIntervalSince($0) / 86_400 } ?? 10_000
    let recency = max(0, 1 - recencyDays / (365 * 5))   // linear decay over 5y
    return area * 100 + recency * 10                    // area dominates; recency is tiebreaker
}
```

The crop passed to `PersonCard`'s `ThumbnailView` is the matched region.
Photos without a matching named region: `area = 0` → the photo ranks lowest,
and the thumbnail uses no crop (existing center-crop behavior). This matches
"prefer images where the region is large, the photo is recent" from the todo.

### 4.4 Event row hit area
`CollectionsView.swift:324-363` — `eventRow(_:)`:
- Add `.contentShape(Rectangle())` on the outer `HStack`. Currently, the
  area between the trailing `Spacer()` and the chevron isn't hit-testable
  because SwiftUI only registers taps on opaque content; the empty stretch
  swallows them.
- Same fix in `FolderBrowserView.swift:123-149` (`folderRow`).

### 4.5 Acceptance — Pass 4
- People rail tiles tightly frame faces; the framing comes from MWG region
  data, padded `1× region width` on each side.
- The default cover for a person prefers photos with a large face crop +
  recent date.
- Tapping anywhere across an Events list row (including whitespace gaps)
  navigates into the folder.

---

## Cross-pass concerns

**Cache versioning** — Pass 4 changes `PhotoFile`'s on-disk schema. Bump
`LibraryCacheStore.version` (and `MemoriesCacheStore.version` if it gates
on photo IDs) to invalidate cleanly. Photos rebuild on next launch.

**Widget snapshot** — `WidgetSnapshotExporter` ships memory cover photos to
the widget. Pass 1's "Person Through the Years" removal means widgets that
already have one cached will display until the next export cycle (~daily).
No code change needed; memories regenerate naturally.

**Concurrency** — `LogStore` uses compass's main-queue dispatch model. Under
Swift 6 strict concurrency, `nonisolated(unsafe) static let shared` is the
escape hatch — same pattern compass already uses. The `@unchecked Sendable`
conformance is justified by the main-queue serialization invariant.

**Testing surface** — focus manual testing on:
- Memory generation with a library that has multiple-country trips at
  varying dominance ratios (verify 90% rule).
- People with both single-name and full-name tags in the same library
  (verify disambiguation doesn't crash on edge cases).
- Photo viewer filmstrip with libraries of 1 / 10 / 1000 photos.
- Share quality on a 50MP HEIC source (verify resize speed and JPEG output).
- Person thumbnails with and without face regions in the source XMP.

**PR slicing** — each pass is independently shippable. If size becomes an
issue, Pass 1 splits cleanly into:
- 1a: drop person memories + 90% country rule + me concept.
- 1b: log viewer + verbose logging.
