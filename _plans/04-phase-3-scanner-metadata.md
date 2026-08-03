# Phase 3 — Scanner + metadata read move into the core

First extraction of *existing* behavior: `MetadataReader` and
`FolderScanner` (plus the mechanical parts of the scan pipeline) are
reimplemented in Rust behind the VFS trait, and Swift's copies are deleted.
`GalleryStore` keeps orchestration (scan-kind resolution, dedupe, two-phase
sequencing, `apply(_:)` choke point) in this phase — only the pure
"walk the tree, read the metadata, produce the diff" machinery moves.

**Exit criterion:** the app runs on the Rust scanner with the Swift
`FolderScanner`/`MetadataReader` deleted; the existing `LocalGalleryTests`
scanner/metadata suites pass against the FFI implementation (via conformance
fixtures); a warm relaunch decodes the **pre-existing** `LibrarySnapshot`
JSON written by the Swift version (no forced rescan on upgrade).

## Non-goals

- Moving scan *policy* (light/full/auto resolution, 48h promotion, dedupe,
  two-phase ordering, sidecar-sync/memories/widget post-steps) — stays in
  `GalleryStore+Scanning.swift`, now calling core primitives.
- Enrichment scheduling, materialization, file-provider probing — Swift.
  The core scanner reports `is_placeholder`/size/mtime; locality transitions
  keep their Swift triggers.
- Any behavior change. This phase is a pure port; improvements are banked
  for later.

## Order of work

### 1. Conformance fixtures *before* any porting

- **Metadata**: a Swift debug harness runs the current `MetadataReader`
  over the synthetic test library (extended with adversarial fixtures:
  non-Gregorian-locale dates, missing EXIF, XMP-only, sidecar-vs-embedded
  conflicts for every field with documented precedence, MWG regions,
  GPS edge values, videos) and dumps
  `metadata_conformance.json`: `[{file, expected: {dates, gps, tags,
  country, regions, …}}]`. This file is the spec; the Rust port must match
  it exactly.
- **Scanner**: same approach — fixture trees (nested folders, empty dirs,
  unreadable dir to exercise the failed-directory carry-forward, files
  added/removed/modified between two passes) → dump expected
  `(rootFolder, flatPhotos, added/removed/modified, failedDirectoryPaths)`.
- **Snapshot JSON**: commit a real `LibrarySnapshot` file produced by the
  current app as a fixture; Rust must decode it losslessly and re-encode to
  a form Swift decodes identically (field-for-field — the hand-written
  `Codable` in `PhotoFile` is the reference; date encoding strategy and
  URL encoding must match exactly).

### 2. `gallery-vfs` grows the scanner surface

```
trait Vfs {
    fn list(&self, dir: &str) -> Result<Vec<Entry>>;   // name, kind, size, mtime,
                                                       // is_placeholder, content_version?
    fn open(&self, path: &str) -> Result<Box<dyn ReadSeek>>;
    ...
}
```

- iOS impl stays path-based under an active security scope (simulator-only
  decision); the trait shape is what keeps Android/SAF possible later.
- `is_placeholder`/content-version on iOS: Swift pre-resolves via the
  existing `FileProviderDetector` values? No — that would reintroduce
  chatter. Instead the iOS `Vfs` impl calls the same `URLResourceKey`s from
  Swift *inside* the callback implementation. Callback-per-directory (not
  per-file) keeps FFI traffic at directory granularity.

### 3. Port `gallery-meta` read side

- EXIF via `kamadak-exif` (already a dependency from Phase 1 orientation);
  date parsing with a **fixed-format parser** equivalent to the
  `en_US_POSIX` `exifDateFormatter` (the whole point of that formatter —
  no locale, no calendar surprises — is native to Rust's chrono with
  explicit formats; add the subsecond/timezone fallbacks the Swift reader
  has).
- Video dates: AVFoundation is Swift-only. Two options; pick at
  implementation time with a measurement: (a) parse MP4/QuickTime atoms in
  Rust (`mp4` crate — creation time is a standard atom), (b) Swift callback
  for videos only. Prefer (a); fixture-covered either way.
- Sidecar merge precedence: port exactly as documented at the merge site in
  `readImageMetadata`, then delete the Swift copy so the doc lives in one
  place (move the comment to the Rust merge site).
- **StableUUID/Unicode decision comes due**: scanner output IDs must equal
  Swift's on APFS (NFD names). Decision: hash the path **as the platform
  reports it** (current behavior, pinned by Phase 0 vectors). Cross-platform
  identity of the *same* file tree on different filesystems is explicitly
  out of scope — sidecars, not IDs, are the portable layer.

### 4. Port `gallery-scan`

- Iterative traversal mirroring `FolderScanner` (same ordering guarantees —
  the sort lives in `SearchIndex` but folder child order must stay stable),
  failed-directory carry-forward semantics identical (throwing directory ⇒
  excluded from removal accounting).
- Light-scan semantics: reuse cached `PhotoFile` when size+mtime match —
  including the documented blind spot (no content check). Full scan:
  re-probe + re-read everything, second pre-pass behavior stays Swift-side.
- Snapshot store: read/write `LibrarySnapshot` JSON via serde against the
  fixture from step 1. Keep `JSONDiskCache` versioned-envelope semantics
  (version probe before payload decode) — port the envelope, not the
  debounce (Swift keeps calling save at the times it does today).

### 5. FFI + Swift swap

```
scanner_open(vfs: Box<dyn VfsCallback>, snapshot_path) -> Scanner
scanner.scan(root, kind: Light|Full, progress) -> ScanOutcome
   // ScanOutcome: rootFolder + flatPhotos (batched), needsEnrichment,
   //              sidecarManifest, added/removed/modified, failedDirectoryPaths
scanner.load_snapshot() / save_snapshot(...)
```

- `GalleryStore+Scanning` swaps its calls; `apply(_:)`, dedupe, two-phase,
  post-scan steps untouched. Delete `FolderScanner.swift`,
  `MetadataReader.swift` (and its tests, replaced by conformance fixtures
  running against FFI).
- Bridge types once at the boundary (`PhotoFile` ⇄ FFI record); the Swift
  `PhotoFile` stays the app's currency in this phase.

## Testing / acceptance

- [ ] All conformance fixtures green against the Rust implementation (run
      in `cargo test` on the Mac host *and* via FFI in `LocalGalleryTests`).
- [ ] Upgrade test: snapshot written by the last Swift build loads warm
      (no rescan) in the Rust build.
- [ ] Perf: full scan + light scan of the 10k-photo synthetic library
      benchmarked before/after; regression budget ±20%, expect improvement.
- [ ] FFI traffic measured: O(directories + batches), not O(files).
- [ ] Simulator soak: repeated foreground light scans, pull-to-refresh,
      Reload Library — no diffs vs. baseline behavior notes.

## Risks

| Risk | Mitigation |
|---|---|
| Silent metadata divergence on weird files | Fixtures are generated from the *current* implementation, adversarial cases included; any file class not covered gets a fixture before its code is ported |
| Snapshot JSON incompatibility → surprise full rescans | Byte-level fixture round-trip tests both directions; eviction machinery is the safety net, not the plan |
| Date parsing subtleties (timezones, subseconds, 24:00) | Port the Swift fallback chain case-by-case with a fixture per branch |
| Video date atom parsing gaps | Fixture set from real camera MP4/MOVs; Swift-callback fallback (option b) kept as escape hatch |
| Callback-VFS deadlocks (Swift → Rust → Swift re-entrancy) | VFS callbacks are synchronous, non-main-actor, and never call back into the core; enforced by design review + a stress test |
