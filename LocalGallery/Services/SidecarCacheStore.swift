import Foundation
import os

/// JSON-on-disk cache of parsed `.xmp` sidecar contents, keyed by photo
/// stable UUID. Lets search/tag features work for cloud libraries even
/// after the source `.xmp` files are evicted by the provider.
///
/// Single JSON file (via `JSONDiskCache`) at `Documents/sidecar_cache.json`.
/// Chunked-per-folder or SQLite is the known follow-up if file size becomes
/// a problem; we start single-file and revisit if telemetry warrants it.
@MainActor
final class SidecarCacheStore {
    /// Bumping invalidates every existing sidecar cache. Versioned
    /// independently of `LibrarySnapshot.version` — entries are keyed by
    /// stable photo UUID, which survives library-schema bumps.
    nonisolated static let version = 1

    /// What a sidecar actually carries: the photo-tools XMP schema has no
    /// per-photo date or GPS fields (those live in the image's EXIF), so
    /// this is tags + country + face regions only.
    struct CachedSidecar: Codable, Hashable, Sendable {
        var version: FileProviderDetector.ContentVersion
        var hierarchicalTags: [HierarchicalTag]
        var countryCode: String?
        var faceRegions: [FaceRegion]
    }

    /// String-keyed on disk (JSON object keys); UUID-keyed in memory.
    private let disk: JSONDiskCache<[String: CachedSidecar]>
    private var entries: [UUID: CachedSidecar] = [:]

    init(url: URL) {
        // 200ms debounce: a sync run calls `put` once per fetched sidecar;
        // coalesce the burst into one write.
        self.disk = JSONDiskCache(
            url: url,
            version: Self.version,
            label: "sidecar cache",
            debounce: .milliseconds(200)
        )
        if let loaded = disk.load() {
            entries = Dictionary(uniqueKeysWithValues: loaded.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
            Log.cache.info("Loaded \(self.entries.count) sidecar entries from cache")
        }
    }

    // MARK: - Public API

    func get(_ photoID: UUID) -> CachedSidecar? {
        entries[photoID]
    }

    func put(_ photoID: UUID, _ entry: CachedSidecar) {
        entries[photoID] = entry
        scheduleSave()
    }

    func remove(_ photoID: UUID) {
        guard entries.removeValue(forKey: photoID) != nil else { return }
        scheduleSave()
    }

    /// Drop entries for photo IDs not present in `keeping`. Called after a
    /// scan to garbage-collect orphans (deleted photos, renamed files).
    func gc(keeping: Set<UUID>) {
        let before = entries.count
        entries = entries.filter { keeping.contains($0.key) }
        if entries.count != before {
            Log.cache.info("Sidecar GC: \(before - self.entries.count) orphans removed (\(self.entries.count) remain)")
            scheduleSave()
        }
    }

    /// Wipe everything. Used by the "Re-download all sidecars" Settings
    /// action. `JSONDiskCache.clear()` cancels any debounced save in flight
    /// so a pre-clear `put` can't resurrect the file.
    func clear() {
        entries.removeAll()
        disk.clear()
    }

    var count: Int { entries.count }

    /// Snapshot of currently-cached photo IDs. Used by `SidecarSyncService`'s
    /// diff to decide which entries are orphans.
    var allPhotoIDs: Set<UUID> { Set(entries.keys) }

    // MARK: - Persistence

    private func scheduleSave() {
        disk.save(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }))
    }
}
