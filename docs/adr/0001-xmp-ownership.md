# ADR 0001: Preservation-first XMP ownership

- Status: Accepted
- Date: 2026-09-09

## Context

`.xmp` sidecars next to photos are shared property. photo-tools, digiKam,
Lightroom, and this app all write the same file. Image bytes are the user's
archive; the sidecar is the portable tag/face/place record that travels
with the file across devices and tools.

A replace-the-roots write can claim or delete keywords another tool
authored. A half-written sidecar is indistinguishable from a corrupt one.

## Decision

1. **The core never rewrites image bytes.** Durable output is
   `IMG_1234.jpg.xmp` (suffix-preserving sidecar name).
2. **Read-modify-write preserves every element the core does not own.**
   Ownership is the agent's previous write, tracked under
   `photo-tools:Core*` sentinels — not "every `Objects/*` or `Scenes/*`
   path in the file."
3. **Tagging and faces use disjoint sentinel lists** so one pass cannot
   retract the other. Tagging owns machine `Objects/*` / `Scenes/*` it
   previously wrote. Faces own `People/*`, `iptcExt:PersonInImage`, and
   `mwg-rs:RegionInfo` this agent authored. Places writes `Places/*` and
   IPTC location fields through the same preserve-unowned rule.
4. **Human keywords, foreign hierarchies, and unrelated XML stay.**
   Regions merge with foreign boxes by IoU rather than wiping the bag.
5. **Writes are atomic** (`temp` + rename). Concurrent writers retry when
   size or mtime changed underfoot.
6. **The SQLite cache is not truth.** Embeddings, queues, and unlabeled
   clusters are recomputable and must not be synced as the library.

## Consequences

- Interop with photo-tools and other DAM tools is possible only if
  retraction is limited to sentinel-tracked claims.
- Operational docs must describe the live writer if it still uses a
  broader replace-set; that is a defect against this ADR, not a second
  policy.
- Tests that encode foreign-object preservation are the contract, not
  historical color.
