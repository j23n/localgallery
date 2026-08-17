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
    /// `gallery-cache.sqlite` — the Rust core's derived-data store (ML work
    /// queue + embeddings). Everything in it is recomputable, so it lives in
    /// Application Support rather than Documents: no reason to back it up,
    /// but it must survive the Caches eviction the system is free to do
    /// mid-run. Owned exclusively by the core; Swift only supplies the path.
    let mlCacheDatabaseURL: URL
    /// `ModelPacks/` — one subdirectory per imported model pack. Application
    /// Support because a pack is user-installed content the app cannot
    /// re-derive, and losing it mid-run would fail every photo.
    let modelPacksDirectoryURL: URL
    /// `LocalGallery.app/pack/` — the pack `scripts/prepare_pack.sh` staged and
    /// `project.yml` bundles, read **in place**. The core only reads and hashes
    /// a pack, so the read-only bundle is a valid location; copying 157 MB into
    /// Application Support on first launch would buy nothing.
    ///
    /// `nil` when the build carries no pack, which `prepare_pack.sh` exists to
    /// prevent — a build error, not a state the app is designed around.
    let bundledModelPackURL: URL?
    let bookmarkKey: String

    static var production: GalleryPaths {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = applicationSupport
        return GalleryPaths(
            libraryCacheURL: docs.appendingPathComponent("library_cache.json"),
            memoriesCacheURL: docs.appendingPathComponent("memories_cache.json"),
            sidecarCacheURL: docs.appendingPathComponent("sidecar_cache.json"),
            thumbnailDir: caches.appendingPathComponent("thumbnails", isDirectory: true),
            mlCacheDatabaseURL: support.appendingPathComponent("gallery-cache.sqlite"),
            modelPacksDirectoryURL: support.appendingPathComponent("ModelPacks", isDirectory: true),
            bundledModelPackURL: Bundle.main.url(forResource: "pack", withExtension: nil),
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
