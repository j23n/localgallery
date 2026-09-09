# ADR 0005: Current-state-only documentation

- Status: Accepted
- Date: 2026-09-09

## Context

`_plans/` and `docs/plans/` mixed shipped work, future sketches, and
stale status. README claimed a read-only library, a pure-Rust HEIC
path on iOS, a bundled pack on every fresh install, and "no server"
while Places posts GPS to Nominatim. Source comments retained
migration novels (schema v13–v20, "ported from Swift") that hid the
live contract.

## Decision

1. **User-facing and contributor docs describe behavior that exists
   in this revision.** No roadmap, no "will", no "Phase N shipped."
2. **Why a constraint remains** lives in `docs/adr/`. Durable
   rationale from retired plan files is migrated here; the plan
   files are not part of the documentation surface.
3. **Fixture READMEs pin observable contracts** (landmines,
   regeneration). They are not a port diary.
4. **Crate rustdoc and example comments match the live API.**
   Historical "used to" notes stay only where they still explain a
   current invariant (for example a pinned bug).
5. **Tests may keep old plan citations.** Test sources are not
   rewritten as a documentation change.

## Consequences

- README, `linux/README.md`, `CONTRIBUTING.md`, and `docs/*` guides
  are the current surface.
- Agent notes (`.claude/CLAUDE.md`) must not point at deleted plan
  paths.
- New work that needs a standing decision adds an ADR first, then
  updates the current-state guides.
