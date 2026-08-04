import Foundation
import os

/// Versioned JSON-file persistence shared by the disk caches (library scan,
/// memories, sidecars). One instance per file. Owns the three behaviours the
/// stores used to hand-roll separately — uniformly this time:
///
///   - **Ordered writes.** Every save chains behind the previous one, so two
///     quick saves can never land on disk out of order (the old
///     fire-and-forget detached tasks could let the older snapshot win).
///   - **Debounce.** An optional coalesce window for callers that save once
///     per item during a burst (the sidecar sync run).
///   - **Load policy.** The version field is probed *before* the full payload
///     decode, so an incompatible `Value` schema (which makes the full decode
///     throw) still reports as a version mismatch; mismatches and corrupt
///     files are both evicted so they aren't re-parsed every launch.
///
/// `@MainActor` because all owners are main-actor types; the encode + write
/// itself runs on a detached utility task.
@MainActor
final class JSONDiskCache<Value: Codable & Sendable> {
    private let url: URL
    private let version: Int
    /// Human-readable name used in log lines ("library cache", …).
    private let label: String
    private let debounce: Duration
    /// Latest scheduled write. New saves cancel it (debounce coalescing) and
    /// chain behind it (write ordering).
    private var saveTask: Task<Void, Never>?

    init(url: URL, version: Int, label: String, debounce: Duration = .zero) {
        self.url = url
        self.version = version
        self.label = label
        self.debounce = debounce
    }

    private struct Payload: Codable, Sendable {
        let version: Int
        let value: Value
    }

    /// Decoded first on load so a schema change in `Value` can't mask the
    /// version check (see type doc).
    private struct VersionProbe: Codable {
        let version: Int
    }

    /// Fire-and-forget save. Coalesced within the debounce window; ordered
    /// behind any in-flight write. Errors are logged.
    func save(_ value: Value) {
        saveTask?.cancel()
        let previous = saveTask
        let payload = Payload(version: version, value: value)
        let url = url
        let label = label
        let debounce = debounce
        saveTask = Task.detached(priority: .utility) {
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { return }
            }
            // Wait out an older write that already passed its debounce, so
            // its (stale) snapshot can never land after this one.
            await previous?.value
            if Task.isCancelled { return }
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                // Loud on purpose, and specific about the consequence. The
                // failure mode this line exists for is silent and permanent:
                // `JSONEncoder` throws on a non-finite `Double`, so a single
                // NaN GPS coordinate — a `0/0` EXIF rational, which cameras do
                // write — makes *every* subsequent save of the library
                // snapshot fail. Nothing else notices. The app keeps running
                // on in-memory state, the file on disk keeps aging, and every
                // launch pays a full rescan of the whole library forever.
                //
                // The value is sanitised where it enters (`read_gps` in
                // `gallery-meta` drops non-finite coordinates, and the
                // snapshot encoder writes them as absent), so reaching here
                // means something new started producing one.
                Log.cache.error("""
                    Failed to save \(label): \(Log.r.error(error)) — the on-disk copy is now \
                    stale and will stay stale until a save succeeds
                    """)
            }
        }
    }

    /// Synchronous load (callers run it during Store init, before the first
    /// SwiftUI render). Returns nil on miss, version mismatch, or decode
    /// failure — evicting the file in the latter two cases.
    func load() -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
            guard probe.version == version else {
                Log.cache.warning("\(self.label) version mismatch (\(probe.version) vs \(self.version)), discarding")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return try JSONDecoder().decode(Payload.self, from: data).value
        } catch {
            Log.cache.error("Failed to load \(self.label): \(Log.r.error(error)); discarding file")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Remove the file and cancel any pending write — without the cancel, a
    /// save scheduled just before `clear()` would resurrect the file with
    /// pre-clear contents.
    func clear() {
        saveTask?.cancel()
        saveTask = nil
        try? FileManager.default.removeItem(at: url)
    }
}
