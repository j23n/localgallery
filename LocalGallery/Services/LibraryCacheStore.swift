import Foundation
import os

/// JSON-on-disk cache of the last folder scan: root folder tree + flat photo
/// list. Save runs on a detached task, load is sync (called during init
/// before the first SwiftUI render). Version mismatches are evicted.
enum LibraryCacheStore {
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
    static let version = 20

    private struct Payload: Codable, Sendable {
        let version: Int
        let rootFolder: PhotoFolder
        let allPhotos: [PhotoFile]
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache.json")
    }

    /// Encode and write atomically on a detached task. Fire-and-forget; the
    /// caller doesn't await completion (errors are logged).
    static func save(rootFolder: PhotoFolder, allPhotos: [PhotoFile], to url: URL = Self.defaultURL) {
        let payload = Payload(version: version, rootFolder: rootFolder, allPhotos: allPhotos)
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.cache.error("Failed to save cache: \(error.localizedDescription)")
            }
        }
    }

    /// Synchronous load. Returns nil on miss / version mismatch / decode
    /// error, after evicting any stale file. On version mismatch the
    /// memories cache at `memoriesURL` is also wiped so stale photo IDs
    /// don't outlive the rescan that produces fresh SHA-256 IDs.
    static func load(
        from url: URL = Self.defaultURL,
        memoriesURL: URL = MemoriesCacheStore.defaultURL
    ) -> (rootFolder: PhotoFolder, allPhotos: [PhotoFile])? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == version else {
                Log.cache.warning("Version mismatch (\(payload.version) vs \(version)), discarding")
                try? FileManager.default.removeItem(at: url)
                MemoriesCacheStore.clear(at: memoriesURL)
                return nil
            }
            Log.cache.info("Loaded \(payload.allPhotos.count) photos from cache v\(payload.version)")
            return (payload.rootFolder, payload.allPhotos)
        } catch {
            Log.cache.error("Failed to load cache: \(error.localizedDescription)")
            return nil
        }
    }
}
