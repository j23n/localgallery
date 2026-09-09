# ADR 0002: Scan freshness and provider I/O

- Status: Accepted
- Date: 2026-09-09

## Context

A cold walk of a 20k-photo iCloud tree spent almost all of its time in
per-file `resourceValues` XPC (seven keys, including three ubiquitous-item
probes). Light scans that never `stat` known paths cannot see in-place
edits. Persisting the sidecar manifest inside the library snapshot avoids
re-probing every `.xmp` on each launch without a schema bump that would
force a full rescan.

Linux reuses a snapshot whenever one exists, so a "trust cache forever"
rule can hide edits indefinitely.

## Decision

1. **The scanner reports the tree; hosts own policy.** Light / auto /
   full, the 48-hour promotion, request dedupe, and post-scan sidecar
   sync stay in the iOS store. Linux opens from the snapshot and
   watches the folder.
2. **Provider attributes are the only Swift VFS callback.** List, stat,
   and read are POSIX under an already-active security scope. The probe
   runs per directory, in batches, and only for files a pass will
   rebuild. A non-ubiquitous tree reads the cheap keys only.
3. **A light pass may reuse a cached row only after a live size+mtime
   check.** Size or mtime change rebuilds the row. Content-preserving
   rewrites that keep both are invisible; a full / explicit rescan is
   the backstop.
4. **`sidecarManifest` is an optional field on snapshot v20.** A file
   written without it decodes as `nil` and pays one re-probe. Do not
   bump the snapshot version to add a cache hint.
5. **Sidecar cache eviction requires a successful parent listing.** A
   directory that failed to list must not look like "those sidecars
   were deleted."
6. **The probe must not return on the light path** and must not widen
   the ubiquitous key set "for uniformity." That re-opens the 20k-file
   XPC cost.

## Consequences

- Launch stays fast on an unchanged library; edits need a stat (light)
  or an explicit full rescan.
- File-provider folders work without downloading every original: sidecar
  rows carry content versions; photos materialize on demand.
- Linux must not treat "snapshot exists" as "never look at disk again."
