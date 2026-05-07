import Foundation

/// Disk locations + UserDefaults key that `GalleryStore` reads/writes.
/// Wrapping these in a struct lets tests point a store at temp dirs and a
/// scoped UserDefaults suite so nothing leaks between runs. `bookmarkKey`
/// is a UserDefaults key (folder bookmarks are stored as data inside
/// defaults, not as a file) — kept here so the suite-scoped defaults a test
/// injects use the same key the production code reads.
struct GalleryPaths: Sendable {
    let libraryCacheURL: URL
    let memoriesCacheURL: URL
    let sidecarCacheURL: URL
    let thumbnailDir: URL
    let bookmarkKey: String

    static var production: GalleryPaths {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return GalleryPaths(
            libraryCacheURL: docs.appendingPathComponent("library_cache.json"),
            memoriesCacheURL: docs.appendingPathComponent("memories_cache.json"),
            sidecarCacheURL: docs.appendingPathComponent("sidecar_cache.json"),
            thumbnailDir: caches.appendingPathComponent("thumbnails", isDirectory: true),
            bookmarkKey: "rootFolderBookmark"
        )
    }
}
