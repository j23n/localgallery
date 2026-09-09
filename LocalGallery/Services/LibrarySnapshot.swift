import Foundation

/// The persisted result of the last folder scan: root folder tree + flat
/// photo list. Stored via `JSONDiskCache` (see `GalleryStore.libraryCache`);
/// this file owns the snapshot shape and its schema version.
struct LibrarySnapshot: Codable, Sendable {
    /// Current schema is 20. Bumping evicts every existing library cache
    /// and the memories cache (photo IDs may change). The Store does that
    /// in `loadCache()`.
    ///
    /// `sidecarManifest` is optional on this version and did **not** bump
    /// it: a v20 file written without the field decodes as `nil` and pays
    /// one re-probe. See docs/adr/0002.
    static let version = 20

    let rootFolder: PhotoFolder
    let allPhotos: [PhotoFile]
    /// The sidecar rows the same scan produced.
    ///
    /// Persisting these is what stops every launch re-probing every `.xmp`:
    /// the light scan's fast path needs a manifest hit per photo.
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
