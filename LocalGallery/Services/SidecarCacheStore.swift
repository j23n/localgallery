import Foundation
import os

/// JSON-on-disk cache of parsed `.xmp` sidecar contents, keyed by photo
/// stable UUID. Lets search/tag features work for cloud libraries even
/// after the source `.xmp` files are evicted by the provider.
///
/// Structure mirrors `LibraryCacheStore` — single JSON file at
/// `Documents/sidecar_cache.json`. Pass 5 plan calls out chunked-per-folder
/// or SQLite if file size becomes a problem; we start single-file and
/// revisit if telemetry warrants it.
@MainActor
final class SidecarCacheStore {
    /// Bumping invalidates every existing sidecar cache.
    nonisolated static let version = 1

    struct CachedSidecar: Codable, Hashable, Sendable {
        var version: FileProviderDetector.ContentVersion
        var hierarchicalTags: [HierarchicalTag]
        var countryCode: String?
        var dateTaken: Date?
        var gpsLatitude: Double?
        var gpsLongitude: Double?
        var faceRegions: [FaceRegion]
    }

    private struct Payload: Codable, Sendable {
        let version: Int
        let entries: [String: CachedSidecar]
    }

    private let url: URL
    private var entries: [UUID: CachedSidecar] = [:]

    init(url: URL) {
        self.url = url
        self.entries = Self.load(from: url)
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
    /// action.
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    var count: Int { entries.count }

    /// Snapshot of currently-cached photo IDs. Used by `SidecarSyncService`'s
    /// diff to decide which entries are orphans.
    var allPhotoIDs: Set<UUID> { Set(entries.keys) }

    // MARK: - Persistence

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Coalesce frequent puts during a sync run into a single write.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let target = url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            if Task.isCancelled { return }
            let stringKeyed = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.uuidString, $0.value) })
            let payload = Payload(version: SidecarCacheStore.version, entries: stringKeyed)
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: target, options: .atomic)
            } catch {
                Log.cache.error("Failed to save sidecar cache: \(error.localizedDescription)")
            }
        }
    }

    private static func load(from url: URL) -> [UUID: CachedSidecar] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == version else {
                Log.cache.warning("Sidecar cache version mismatch (\(payload.version) vs \(version)), discarding")
                try? FileManager.default.removeItem(at: url)
                return [:]
            }
            var out: [UUID: CachedSidecar] = [:]
            for (key, entry) in payload.entries {
                if let id = UUID(uuidString: key) {
                    out[id] = entry
                }
            }
            Log.cache.info("Loaded \(out.count) sidecar entries from cache v\(payload.version)")
            return out
        } catch {
            Log.cache.error("Failed to load sidecar cache: \(error.localizedDescription)")
            return [:]
        }
    }
}
