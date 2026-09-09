# ADR 0003: Validation-only tagged builds

- Status: Accepted
- Date: 2026-09-09

## Context

The family CI template archives an unsigned IPA and uploads it to the
GitHub Release on `v*` tags. An unsigned zip is not an installable
distribution, and this repo has no signing pipeline, App Store record,
or published IPA channel. A tagged job that looks like a release
implies a product that is not being shipped.

On-device tagging also depends on a model pack that is not committed
(~157 MB). The default full pack includes insightface `buffalo_sc`
weights that are research / non-commercial. CI cannot honestly "ship
the app with tagging" without a licensed pack policy.

## Decision

1. **A git tag is a validation pin, not a distribution.** Tagged CI
   may generate the project, compile, archive, and run tests. It must
   not publish an IPA or other installable artifact.
2. **Any human distribution is manual** and out of band. See
   [docs/release.md](../release.md).
3. **The model pack is optional.** A build without a pack is valid:
   browse, search, memories, and Places still work; tagging and faces
   stay off. Staging a pack is a local, explicit step.
4. **Anything given to other people uses a tagging-only pack** (no
   `buffalo_sc` faces) or substituted face models whose license
   permits that distribution.

## Consequences

- README and the release runbook describe validation, not a download
  page.
- `project.yml` still lists `build/pack` as a resource path; operators
  create or stage that directory before `xcodegen`. Absence of models
  is a runtime feature gap, not a failed product.
- `.github/workflows/build.yml` archives unsigned and checks layout.
  It must not assemble, upload, or publish an IPA.
