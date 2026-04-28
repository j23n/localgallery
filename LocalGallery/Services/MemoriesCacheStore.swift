import Foundation
import os

/// JSON-on-disk cache of the last `[Memory]` generation. Save runs on a
/// detached task, load is sync (called during init), clear is invoked from
/// `forceRegenerateMemories` so the next read sees an empty file.
enum MemoriesCacheStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memories_cache.json")
    }

    /// Encode and write atomically on a detached task. Fire-and-forget.
    static func save(_ memories: [Memory], to url: URL = Self.defaultURL) {
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(memories)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.cache.error("Failed to save memories cache: \(error.localizedDescription)")
            }
        }
    }

    /// Synchronous load. Returns nil on miss / decode error, evicting any
    /// stale file in the latter case.
    static func load(from url: URL = Self.defaultURL) -> [Memory]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let cached = try JSONDecoder().decode([Memory].self, from: data)
            Log.cache.info("Loaded \(cached.count) memories from cache")
            return cached
        } catch {
            Log.cache.warning("Failed to load memories cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Remove the cache file. Used by `forceRegenerateMemories` so the next
    /// generation starts from a clean slate.
    static func clear(at url: URL = Self.defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
