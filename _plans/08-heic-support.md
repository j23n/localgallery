# Phase 6 — HEIC: metadata first, then pixels

iPhones shoot HEIC by default, and the core can neither decode one nor read
the XMP inside one. On a library shot on a modern iPhone that is not an edge
case — it is most of the library, silently absent from tagging, faces, and any
tag another tool wrote into the file rather than a sidecar.

**Exit criterion:** a HEIC photo is tagged, has its faces detected, and has its
embedded `digiKam:TagsList` read, on the same terms as a JPEG — and enabling
this re-decodes nothing that was already scored.

## Two changes, deliberately separable

They share a container format and nothing else, and the first is worth landing
on its own:

1. **Metadata** — find the XMP and Exif items in the ISO-BMFF `meta` box.
   Pure Rust, ~300 lines, no dependency, no licence question. Closes "an iPhone
   HEIC carrying embedded `digiKam:TagsList` reads as untagged"
   (`media/container.rs`'s own doc comment).
2. **Decode** — HEVC. A C dependency, a licence question, and a real
   cross-compile. This is the part that needs a decision.

## Current state

| path | HEIC today |
|---|---|
| `preprocess::extension_supported` | `heic` is not in `SUPPORTED_EXTENSIONS`; a `.heic` never gets opened — the file is not even hashed (`preprocess.rs:106`) |
| `preprocess::sniff` | `ftypheic` returns `None`, asserted by a test (`preprocess.rs:530`) — a `.jpg` that is really HEIC fails rather than being mis-decoded |
| `engine.rs` | the row is written `skipped` with the current decoder generation and re-opened when that generation changes (`engine.rs:308,410`) |
| `face` queue | same skip path, same mechanics (`face_reopen_skipped_for_decoder`) |
| `media/container.rs` | JPEG `APP1`, PNG `iTXt`, TIFF tag 700. HEIF/AVIF: **not handled**, documented as a gap |
| `media/exif_read.rs` | `kamadak-exif`, which does read HEIF — so **dates and GPS already work**; only XMP is missing |
| `media/prefix.rs` | unrecognised containers get `DEFAULT_PREFIX_BYTES`, sized so a whole HEIC fits |

So the honest statement of the gap: **HEIC photos have dates and appear in the
library; they are never tagged, never scanned for faces, and any tags embedded
in the file itself are invisible.**

## Decision 1: the decoder generation must split from the preprocess version

This is the finding that shapes the whole phase, and it is not obvious.

`reopen_skipped_for_decoder(PREPROCESS_VERSION)` re-opens a `skipped` row when
the version it was skipped under differs from the current one. So picking up
previously-skipped HEICs requires bumping `PREPROCESS_VERSION`.

But `PREPROCESS_VERSION` is *also* half the embedding-cache key (the other half
is the encoder's SHA-256). Bumping it invalidates every cached embedding in the
library and re-runs inference on every JPEG that was already scored — hours of
CPU, on a change that alters nothing about how a JPEG is decoded or resized.

**Introduce `DECODER_VERSION`, separate from `PREPROCESS_VERSION`:**

- `DECODER_VERSION` — bumped when the *set of formats the core can open*
  changes. Used by `finish_skipped` / `reopen_skipped_for_decoder` (both
  queues), and by nothing else.
- `PREPROCESS_VERSION` — bumped when the *pixel pipeline* changes (resize
  kernel, normalisation, orientation handling). Stays in the embedding-cache
  key.

Adding HEIC bumps the first and not the second: the skipped HEICs re-open, the
scored JPEGs keep their embeddings, and no inference is repeated. The two
happen to be equal at 1 today, which is exactly why conflating them was easy
and why a test should assert they are read from different constants.

`cache.rs`'s `decoder_version` column is already named for the right thing — it
is only the value passed into it that is wrong.

## Decision 2: how to decode

### Option A — libheif + libde265, statically linked (recommended)

HEVC decoding is bit-exact by specification: a conformant decoder produces
identical pixels everywhere. A pinned decoder version is therefore *more*
deterministic than the JPEG path already is (where IDCT implementations legally
differ). This is the option that fits the doctrine rather than bending it.

- Build: vendored C via the `cc`/`cmake` crate, or `libheif-sys` + `libde265-sys`
  with a vendored feature. The precedent is already in the tree — `build_core.sh`
  merges ONNX Runtime's static archive with `libtool -static` because Cargo will
  not fold an external static library into a `staticlib`, and rusqlite already
  bundles SQLite's C. The merge step grows two more archives; nothing structural
  changes.
- Size: libde265 ~1.5 MB, libheif ~1 MB static, and the linker keeps far less.
  Against ONNX Runtime's ~30 MB this is noise.
- Cross-compile: both are plain autotools/CMake C++ with no platform
  assumptions; the arm64-ios and arm64-ios-sim slices are the same recipe
  `build_core.sh` already runs twice.
- **Licence: both are LGPL-3.0.** Static linking under LGPL obliges the
  distributor to let a user relink against a modified library — satisfiable by
  publishing object files, and a known friction point for App Store binaries.
  Today the app is simulator-only and personal, so this is a documented future
  constraint, not a blocker. If it ever becomes one, the escape is to swap
  libde265 for a permissively-licensed HEVC decoder behind the same
  `ImageDecoder` trait, not to redesign the pipeline.

### Option B — platform decode through an FFI callback

Swift decodes via `CGImageSource` and hands RGB back, the way `CoreProviderProbe`
hands back file-provider facts the core cannot get.

Rejected. Not because it is hard — it is the easy one — but because it makes
tag results a function of the device's ImageIO version. The doctrine's promise
is that a content hash determines a result; hysteresis (emit ≥T, retract <T−ε)
absorbs *small* score drift on a tag already emitted, but it does not make two
devices agree on a borderline tag they are each seeing for the first time, and
it does nothing for face embeddings, where the same face decoded two ways lands
at two points and can cluster differently. It also leaves Linux and Android
with no decoder at all, which is the thing the whole core exists to avoid.

Worth keeping in the file as a documented fallback for a future platform where
option A cannot be built, behind the same trait.

### Option C — pure Rust

There is no production-quality pure-Rust HEVC decoder. (`rav1d`/`dav1d` are
AV1, which is AVIF, not HEIC.) Not available; revisit if that changes.

> **CORRECTION, at implementation time: it changed, and this is what shipped.**
>
> `heif-oxide` (ISO-BMFF container) over `rust_h265` (HEVC Main/Main 10, 4:2:0)
> now exists and does the job. It was measured before being taken, against the
> real files this phase is about:
>
> | file | result |
> |---|---|
> | 1920×1080 8-bit single-item HEIC | RMSE 1.02 vs ImageIO, 31 ms |
> | 4000×2250 **grid-tiled** | RMSE 0.79 vs ImageIO, 54 ms |
> | `irot`-rotated | RMSE 0.83, dimensions transposed correctly |
> | 25 repeat decodes of each | one digest each — bit-stable |
>
> The residual is chroma upsampling, not decode error: HEVC is bit-exact at the
> YUV level by specification, which is the same property that made Option A
> attractive.
>
> Every reason Option A was recommended survives the swap, and most of them get
> *better*:
>
> - **Cross-compile** — the "riskiest hour" is zero hours. No build script, no
>   C, no CMake (which is not even installed on the build machine). Both
>   `aarch64-apple-ios` and `aarch64-apple-ios-sim` build from plain `cargo
>   build --target`. `build_core.sh` is untouched: no extra archives to merge,
>   no `HEIF_LIB_LOCATION` env override to invent.
> - **Licence** — MIT OR Apache-2.0 instead of LGPL-3.0. The "documented future
>   constraint" on an App Store release does not need documenting, because it
>   does not exist. This is the single biggest win and it was not the reason for
>   the swap.
> - **Doctrine** — zero `unsafe` in either crate and no SIMD dispatch, so it is
>   *more* deterministic than the JPEG path, whose resize kernel is already
>   architecture-selected. Linux and Android get a real decoder.
>
> Two things it costs, both handled rather than hoped about:
>
> 1. **It panics on malformed input where the incumbents do not.** Measured on
>    an identical 10 705-case corruption sweep: `image`'s JPEG and PNG decoders
>    panicked **0** times, this one **1 388**. That is not survivable by
>    default — the engine's `catch_unwind` wraps the *whole worker scope*, so
>    one bad file would abort the run, and the row would be re-claimed and abort
>    the next one. `heif::HeifDecoder::decode` therefore catches its own panic
>    and reports `ErrorCode::Decode` for that one photo. Worth noting the
>    counterfactual: libde265's equivalent failure is a segfault, which cannot
>    be caught at all.
> 2. **4:2:0 only.** A 4:4:4 HEIC (macOS's own `DefaultDesktop.heic`) is
>    refused. That is precisely the "Apple ships a HEIC variant libheif does not
>    read" row of the risk table below, and its response is unchanged: a
>    `skipped` row stamped with the current `DECODER_VERSION`, which re-opens by
>    itself the day a wider decoder ships.
>
> Both crates are at 0.1.0, which is the real risk. It is contained by the very
> seam this plan asked for: swapping the backend is one `impl` plus a
> `DECODER_VERSION` bump, and that bump re-opens the skipped rows without
> invalidating a single cached embedding. Option A remains the fallback, with
> its recipe intact above.

## Order of work

### 1. HEIC metadata (`gallery-meta`) — lands alone

- New `core/gallery-meta/src/media/isobmff.rs`: a bounded box walk —
  `ftyp` brand check (`heic`/`heix`/`mif1`/`msf1`/`avif`), then `meta` →
  `iinf` (item ids and their types) → `iloc` (offsets/lengths) → the item whose
  type is `mime` with content-type `application/rdf+xml` for XMP, and `Exif`
  for the Exif item.
- `container::extract_xmp` dispatches on the `ftyp` prefix. Content sniffing,
  not extension — the module's existing rule.
- **Bounding.** `iloc` offsets point anywhere in the file, including past its
  end and at each other. Every read is clamped to the file length, item lengths
  are capped (a 16 MB XMP is not a thing), construction methods other than
  `0` (file offset) are refused rather than followed, and the box walk carries
  a depth limit and refuses a zero/negative advance. The MP4 infinite-loop
  finding from the Phase-3 review is the template: `media/video.rs` already got
  this wrong once and its fix is the shape to copy.
- `prefix.rs`: HEIF currently gets `DEFAULT_PREFIX_BYTES` "generous enough to
  contain a whole HEIC". Once `iloc` is parsed the *right* bound is
  offset+length of the located item, so read the prefix, locate, and re-read
  precisely when the item lies beyond it.
- Fixtures: two small hand-built HEICs in `core/fixtures/scan-conformance/assets/`
  — one with embedded XMP carrying `digiKam:TagsList`, one with Exif only —
  plus a set of malformed ones as unit-test byte arrays (truncated `iloc`,
  offset past EOF, self-referential box length, `meta` with no `iinf`).
  The conformance fixture gains cases; note that the Swift side of that
  comparison is `swift_xmp`'s parser, which is unchanged.

### 2. Decoder plumbing (no HEIC yet)

- `DECODER_VERSION` split out, `engine.rs` and the face engine switched to it,
  a test asserting the two constants are independent, and a test that a bump of
  one re-opens skipped rows while leaving embeddings cached.
- An `ImageDecoder` seam in `preprocess.rs` so the HEVC backend is swappable
  (the `tract` escape hatch's shape, applied to decode).

Landing this before the C dependency means the risky part arrives against
plumbing that is already proven.

### 3. HEIC decode

> **As built:** `heif-oxide` + `rust_h265` instead of the vendored C — see the
> correction under Option C. `build_core.sh` needed no change at all, so the
> first bullet below did not happen. Everything after it did.

- ~~`libheif`/`libde265` vendored; `build_core.sh` merges the extra archives and
  validates the slices with the existing `lipo`/`otool` checks.~~
- `preprocess.rs`: `ImageKind::Heic`, `heic` + `heif` in `SUPPORTED_EXTENSIONS`,
  `sniff` recognising the brand set (and the existing "must sniff as
  unsupported" test inverted, deliberately, with a comment saying why).
- **Orientation.** HEIC carries `irot`/`imir` in the item properties *and* may
  carry EXIF orientation. libheif applies the transform properties itself;
  applying EXIF on top would double-rotate. Decide once, in one place: take
  libheif's oriented output and ignore EXIF orientation for HEIC, with a test
  on a rotated fixture. This matters beyond tagging — face regions are written
  in normalised coordinates of the *oriented* image, so a wrong rotation puts
  every box in the wrong place.
- **Bit depth.** iPhone HDR photos are 10-bit. Convert to 8-bit by a fixed rule
  (right-shift, not a tone map) and pin it in a test — a tone map is where a
  platform-specific curve would sneak back in.
- **Limits.** `MAX_PIXELS` / `MAX_RESIZE_PIXELS` apply unchanged, checked from
  the container's declared dimensions *before* decode, so a malicious `ispe`
  cannot ask for a 4 GB buffer.
- Grid/tiled images (`grid` derived items — how iPhone stores large HEICs) must
  work; a single-tile-only decoder would fail on real photos. libheif handles
  this; the fixture set must include a tiled image so it is actually exercised.

### 4. Face path

Nothing to write: the face engine shares `preprocess`. But the queue's skipped
rows re-open on `DECODER_VERSION` too, and a HEIC-heavy library will produce a
large first face run — worth a line in the Settings summary rather than a
surprise.

> **Not done, deliberately.** The re-open is in and tested on both queues
> (`the_face_queue_re_opens_skipped_rows_on_the_same_decoder_dial`), but the
> *Settings line* reporting how many rows re-opened is not. It is a count
> `reopen_skipped_for_decoder` already returns and currently discards; surfacing
> it means widening `RunSummary` **and** `FaceRunSummary`, both FFI records,
> both error-path constructions, both Swift services and two `SettingsView`
> rows. That is an eight-file change through the FFI for a progress label, and
> it is not worth making it at the end of the phase that also swapped the
> decoder. The first run after this ships is long either way; this only decides
> whether the user is told why.

## Test plan

- Rust: the malformed-container battery, orientation, bit depth, tiling,
  `DECODER_VERSION`-vs-`PREPROCESS_VERSION` independence, and a
  decode-determinism test comparing a HEIC's decoded bytes against a committed
  hash (the same technique the resize kernel already uses).
- `expected_tags.json` gains a HEIC case, so the simulator and host must agree
  on the tags produced from a HEIC, not just on the fact that it decoded.
- Xcode `TaggingSessionTests` / `FaceSessionTests` against the committed test
  packs, with the HEIC fixture in the folder reference.
- exiftool as the oracle for the metadata half, as in Phase 1.

## Risks

| Risk | Response |
|---|---|
| ~~LGPL static linking blocks a future App Store release~~ | **Gone.** The decoder that shipped is MIT/Apache-2.0. |
| ~~Cross-compiling two C libraries for four slices~~ | **Gone.** Pure Rust; `cargo build --target` and nothing else. The `ImageDecoder` seam still earns its keep — it is what makes swapping back to Option A, or forward to something else, a contained change. |
| A 0.1.0 decoder is wrong in a way the fixtures do not catch | The new risk, taken knowingly. Bounded by: goldens on three fixtures, a corruption sweep, an ImageIO cross-check before adoption, and a swap that costs one `impl` and a `DECODER_VERSION` bump. |
| A HEIC-heavy library re-opens thousands of skipped rows at once | Correct behaviour, but the first run after this ships is long. The queue is resumable and cancellable already; the Settings summary should say how many rows re-opened. |
| Apple ships a HEIC variant libheif does not read | It becomes a `skipped` row with the current `DECODER_VERSION`, which is exactly the mechanism this phase is built on. |
| Double-rotation between `irot` and EXIF | One decision, one test, one fixture — called out above because face regions inherit the error invisibly. |
