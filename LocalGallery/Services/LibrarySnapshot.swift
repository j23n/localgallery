import Foundation

/// The persisted result of the last folder scan: root folder tree + flat
/// photo list. Stored via `JSONDiskCache` (see `GalleryStore.libraryCache`);
/// this file owns the snapshot shape and its schema version.
struct LibrarySnapshot: Codable, Sendable {
    /// Bumping invalidates every existing cache. v13: force rescan so video
    /// dates read AVAsset.creationDate (videos used to skip enrichment and
    /// fall back to the filesystem date, which often equals the download
    /// time on this device). v16: stable IDs migrated from MD5 to SHA-256 —
    /// old cached IDs are incompatible with new scan output. v17: PhotoFile
    /// gained `faceRegions` — re-enrich so MWG region data populates.
    /// v18: face region reader now also pulls from embedded XMP (not just
    /// .xmp sidecars), so re-enrich to pick up regions in JPEG/HEIC files
    /// that don't have a sidecar. v19: MWG region parser rewritten to target
    /// `<mwg-rs:Area>` directly instead of walking `<rdf:li>` boundaries —
    /// re-enrich so libraries that hit the boundary bug pick up regions now.
    /// v20: PhotoFile gained `fileModificationDate` so light scans can diff
    /// the live filesystem listing against the cache without re-probing every
    /// file — bump so the first scan after upgrade populates it for everyone.
    ///
    /// Note: a bump here also wipes the memories cache (memories reference
    /// photo IDs that may change with the library schema) — the Store
    /// orchestrates that in `loadCache()`.
    /// **`sidecarManifest` deliberately did not bump this.** It is optional, a
    /// v20 file written before it existed decodes with `nil`, pays one legacy
    /// re-probe and persists it from then on. A bump would have forced a full
    /// rescan on every install — minutes of provider round-trips — to save a
    /// single pass. See `_plans/06-performance-baseline.md` Finding 2.
    static let version = 20

    let rootFolder: PhotoFolder
    let allPhotos: [PhotoFile]
    /// The sidecar rows the same scan produced.
    ///
    /// Persisting these is what stops every launch re-probing ~17k `.xmp`
    /// files: the light scan's fast path needs a manifest hit per photo, and
    /// the manifest used to live only in `GalleryStore.lastSidecarManifest` —
    /// in memory, empty on launch, so the first `.auto` scan after every cold
    /// start paid 259 s on a 20k library with 20,000/20,000 photo cache hits.
    ///
    /// Staleness is already guarded three ways and none of them relies on this
    /// field being fresh: the fast path requires an unchanged photo size+mtime,
    /// `SidecarSyncService` still diffs content versions before fetching, and a
    /// *deleted* sidecar drops out through the directory listing rather than
    /// through the cache.
    ///
    /// `nil` means "written by a build that did not have this field", which is
    /// distinct from `[]` — a library with no sidecars at all.
    let sidecarManifest: [SidecarCandidate]?

    init(
        rootFolder: PhotoFolder,
        allPhotos: [PhotoFile],
        sidecarManifest: [SidecarCandidate]? = nil
    ) {
        self.rootFolder = rootFolder
        self.allPhotos = allPhotos
        self.sidecarManifest = sidecarManifest
    }
}

/// Schema version for the persisted `[Memory]` cache. Versioned
/// independently of `LibrarySnapshot.version` so a `Memory`-schema change
/// doesn't force a full library rescan. Bump when `Memory` / `MemoryType`
/// fields change incompatibly.
enum MemoriesCacheSchema {
    static let version = 1
}
