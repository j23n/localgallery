import Foundation
import os

/// JSON-on-disk cache of the last `[Memory]` generation. Save runs on a
/// detached task, load is sync (called during init), clear is invoked from
/// `forceRegenerateMemories` so the next read sees an empty file.
///
/// Versioned independently of `LibraryCacheStore` so a `Memory`-schema change
/// doesn't force a full library rescan. The two caches are still coupled in
/// the photo-ID dimension — when `LibraryCacheStore` evicts on its own
/// version mismatch it also clears this file, since memories reference photo
/// IDs that may have changed with the library schema.
enum MemoriesCacheStore {
    /// Bumping invalidates every existing memories cache (but leaves the
    /// library cache alone). Bump when `Memory` / `MemoryType` fields change
    /// in an incompatible way.
    static let version = 1

    private struct Payload: Codable, Sendable {
        let version: Int
        let memories: [Memory]
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memories_cache.json")
    }

    /// Encode and write atomically on a detached task. Fire-and-forget.
    static func save(_ memories: [Memory], to url: URL = Self.defaultURL) {
        let payload = Payload(version: version, memories: memories)
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.cache.error("Failed to save memories cache: \(Log.r.error(error))")
            }
        }
    }

    /// Synchronous load. Returns nil on miss / version mismatch / decode
    /// error, evicting any stale file in the latter case.
    static func load(from url: URL = Self.defaultURL) -> [Memory]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == version else {
                Log.cache.warning("Memories cache version mismatch (\(payload.version) vs \(version)), discarding")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            Log.cache.info("Loaded \(payload.memories.count) memories from cache v\(payload.version)")
            return payload.memories
        } catch {
            Log.cache.warning("Failed to load memories cache: \(Log.r.error(error))")
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
