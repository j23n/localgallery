# ADR 0004: MPL-2.0 licensing

- Status: Accepted
- Date: 2026-09-09

## Context

The repository root `LICENSE` is Mozilla Public License 2.0. Cargo
workspace metadata and the Linux AppStream component previously
declared MIT. That split is a legal defect: crates.io, `cargo
package` metadata, and Flathub/AppStream consumers would advertise
the wrong license.

Dependencies used for HEIC (`heif-oxide`, `rust_h265`) and ONNX
Runtime are permissive and statically linked. libheif/libde265
(LGPL-3.0) are deliberately not linked so a static iOS binary does
not inherit a relink obligation.

## Decision

1. **The project license is MPL-2.0**, matching root `LICENSE`.
2. **Cargo `license` fields and AppStream `project_license` /
   `metadata_license` use the SPDX id `MPL-2.0`.**
3. **HEIC decode stays on the permissive + ImageIO seam**
   (`gallery_ml::preprocess::ImageDecoder`). Do not take LGPL
   decoders into the shipping binary.
4. **Third-party model weights are not covered by MPL-2.0.** Face
   models in the default full pack remain insightface research /
   non-commercial; see ADR 0003.

## Consequences

- File-level MPL notices are not required when `LICENSE` is shipped
  with the source (MPL Exhibit A).
- Downstream packagers should copy `LICENSE` and the AppStream
  `project_license`.
- A decoder swap back to libheif would be a new license decision,
  not a local implementation detail.
