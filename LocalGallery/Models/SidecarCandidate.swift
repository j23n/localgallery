import Foundation

/// One row of the sidecar manifest a scan emits: which `.xmp` belongs to which
/// photo, and what version of it the scan saw. `SidecarSyncService` diffs these
/// against `SidecarCacheStore` to decide what to fetch, without re-reading
/// anything.
///
/// Lived on `FolderScanner` until the scanner moved into the Rust core; it is a
/// value type the Store, the sync service and the persisted `LibrarySnapshot`
/// all share, so it belongs with the other models rather than inside whichever
/// service happens to produce it.
///
/// **`Codable` is load-bearing.** `_plans/06-performance-baseline.md` Finding 2:
/// the manifest used to live only in `GalleryStore.lastSidecarManifest`, so
/// every launch started with an empty one and re-probed ~17k sidecars — 259 s
/// before the first light scan could finish. It now rides along in
/// `LibrarySnapshot` as an optional field, and the fast path survives a
/// relaunch. The encoding has to match `gallery_model::snapshot::SidecarCandidate`
/// exactly, because the Rust core decodes the same file.
struct SidecarCandidate: Codable, Equatable, Sendable {
    let photoID: UUID
    let sidecarURL: URL
    let currentVersion: FileProviderDetector.ContentVersion
    let downloadStatus: FileProviderDetector.DownloadStatus
}
