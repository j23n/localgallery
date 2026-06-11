import Foundation

/// Disk locations + UserDefaults key that `GalleryStore` reads/writes.
/// Wrapping these in a struct lets tests point a store at temp dirs and a
/// scoped UserDefaults suite so nothing leaks between runs. `bookmarkKey`
/// is a UserDefaults key (folder bookmarks are stored as data inside
/// defaults, not as a file) — kept here so the suite-scoped defaults a test
/// injects use the same key the production code reads.
///
/// The services this feeds deliberately have **no path defaults of their
/// own** — a missed injection should fail loudly at the call site rather
/// than silently writing to production paths from a test.
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

    /// Application Support, for the logging/crash singletons
    /// (`LogRedactor`, `CrashDiagnosticsService`, `LogPersistence`) that
    /// exist before any Store and therefore can't take an injected
    /// `GalleryPaths`. Centralised here so every disk location the app uses
    /// is discoverable from this one file.
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
