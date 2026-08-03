# Phase 0 — Toolchain spike

Prove the whole build chain end to end before writing any real feature code:
Rust workspace → UniFFI Swift bindings → XCFramework → linked into
LocalGallery → a real logic-parity test (StableUUID) passing in both
languages in the simulator.

**Exit criterion:** `LocalGalleryTests` contains a test that calls Rust over
FFI and asserts byte-identical stable-UUID derivation against the Swift
implementation, green on `xcodebuild test` (iPhone 16 simulator), and
`cargo test` is green on macOS.

## Non-goals

- No device (arm64-ios) slice, no Android, no CI matrix — simulator +
  macOS-host only (standing decision 3).
- No real features. The only logic ported is `StableUUID`, chosen because it
  is small, pure, and the single most dangerous thing to get subtly wrong
  later (every photo/folder ID depends on it).

## Tasks

### 1. Workspace scaffold

- `core/Cargo.toml` workspace with members `gallery-model`, `gallery-ffi`.
  (Other crates are created by their phases.)
- Toolchain pinned via `core/rust-toolchain.toml` (stable, exact version).
  Targets: `aarch64-apple-darwin`, `aarch64-apple-ios-sim`.
- `gallery-model`: implement `stable_uuid::derive(input: &str) -> Uuid` —
  SHA-256, prefix 16 bytes, `bytes[6] = (b6 & 0x0F) | 0x50`,
  `bytes[8] = (b8 & 0x3F) | 0x80` (mirror of `PhotoFile.swift:137-148`).
- `gallery-ffi`: UniFFI proc-macro setup (`uniffi::setup_scaffolding!()`),
  exporting `core_version() -> String` and
  `stable_uuid(input: String) -> String` (lowercased hyphenated UUID).

### 2. Build script → XCFramework

`scripts/build_core.sh`:

1. `cargo build -p gallery-ffi --target aarch64-apple-ios-sim [--release]`
   producing `libgallery_ffi.a` (staticlib crate-type).
2. `uniffi-bindgen` (library mode, against the built dylib for macOS or the
   `--library` flag on the host build) → `GalleryCore.swift`,
   `GalleryCoreFFI.h`, `GalleryCoreFFI.modulemap`.
3. Assemble `build/core/GalleryCore.xcframework` (`xcodebuild
   -create-xcframework` with the sim static lib + headers; add more slices
   later by appending `-library` args).
4. Copy generated Swift to `build/core/Generated/`.

Notes:
- `build/` is already git-ignored territory (existing `build/` dir); keep
  generated artifacts out of git.
- Make the script idempotent and fast to re-run; it is the developer loop.

### 3. XcodeGen integration (`project.yml`)

- `LocalGallery` target: add `build/core/Generated` as a sources path and
  `build/core/GalleryCore.xcframework` as a framework dependency
  (`embed: false` — static lib).
- Do **not** invoke cargo from an Xcode script phase in this phase — Xcode 16
  script sandboxing (`ENABLE_USER_SCRIPT_SANDBOXING`) fights cargo's file
  access. The workflow is: `./scripts/build_core.sh && xcodegen && build`.
  Revisit a build-phase hook only if the two-step loop annoys in practice.
- Document the workflow in `.claude/CLAUDE.md` build section when the phase
  lands.

### 4. StableUUID conformance vectors

- New fixture `LocalGalleryTests/Support/Fixtures/stable_uuid_vectors.json`:
  `[{ "input": "...", "uuid": "..." }]`, ~30 cases generated **from the Swift
  implementation** (one-off script or a test that writes it), covering:
  - plain ASCII paths;
  - spaces, `#`, `%`, `+` (URL-encoding hazards — inputs are
    `url.standardized.path` strings, so record exactly what Swift feeds in);
  - **Unicode: NFC vs NFD forms of the same visible name** (APFS returns
    decomposed names; Linux/Android will return whatever was written). Record
    both forms as *distinct* vectors — deciding whether to normalize is a
    Phase 3 question; Phase 0 just pins current behavior;
  - emoji, CJK, very long paths, trailing slashes, `..` segments
    pre-standardization (documenting that standardization happens *before*
    hashing, in the caller).
- Rust: `gallery-model` test loads the same JSON (checked into `core/` via a
  symlink or a copy kept in sync by the test — prefer one canonical file
  under `LocalGalleryTests/Support/Fixtures/` read by both, path-relative).
- Swift: new test asserts `StableUUID.derive` matches every vector **and**
  that `GalleryCore.stableUuid(input:)` (over FFI) matches too.

### 5. Concurrency & lifetime sanity check

Small stress test in `LocalGalleryTests`: call the FFI from multiple
`Task.detached` contexts simultaneously (UniFFI-generated Swift must be
callable off the main actor under Swift 6 strict concurrency — the generated
types are `Sendable`; verify this compiles with
`SWIFT_STRICT_CONCURRENCY: complete` before building real APIs on it).

## Acceptance checklist

- [ ] `cargo test` green on macOS host (includes vector conformance).
- [ ] `./scripts/build_core.sh && xcodegen && xcodebuild test` green,
      including the FFI vector test and the concurrency smoke test.
- [ ] Clean checkout → working app in ≤ 3 documented commands.
- [ ] App size delta and cold-start impact noted (expect negligible; record
      the baseline for later phases).

## Risks specific to this phase

- **UniFFI + Swift 6 strict concurrency**: if generated code trips
  `complete` checking, options are a `@preconcurrency import` shim file or
  pinning a newer UniFFI; resolve here, not in Phase 1.
- **Static lib symbol collisions** (e.g. if a dependency bundles sqlite
  later): note `-force_load`/dedupe strategy now; Phase 1's rusqlite must use
  the bundled-sqlite feature compiled with a prefixed namespace only if a
  collision actually appears (iOS ships libsqlite3.dylib — prefer linking the
  system one via `rusqlite`'s `bundled` **off** on Apple platforms if
  practical).
