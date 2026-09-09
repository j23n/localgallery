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
    /// chain behind it (write ordering). `clear()` does not join this task;
    /// the disk gate's epoch is what stops a late write from resurrecting
    /// the file.
    private var saveTask: Task<Void, Never>?
    /// Serialises the on-disk mutation itself. `clear()` bumps the epoch
    /// under this lock, so a save that already passed its cancel check
    /// still no-ops if a clear landed first.
    private let disk = DiskGate()

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
    /// behind any in-flight write. Errors are logged. A `clear()` that
    /// lands after this call is scheduled invalidates the epoch so the
    /// write is skipped rather than resurrecting the file.
    func save(_ value: Value) {
        saveTask?.cancel()
        let previous = saveTask
        let payload = Payload(version: version, value: value)
        let url = url
        let label = label
        let debounce = debounce
        let epoch = disk.epoch
        let disk = disk
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
                try disk.write(data, to: url, epoch: epoch)
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

    /// Remove the file and invalidate any pending or in-flight write.
    /// Cancel alone is not enough: a save that already passed its cancel
    /// check can still write after this returns. The disk gate bumps an
    /// epoch under the same lock as the write, so that late write no-ops
    /// and cannot resurrect the file.
    func clear() {
        saveTask?.cancel()
        saveTask = nil
        disk.clear(url)
    }

    /// Wait for the in-flight save (or clear-chained write) to finish.
    /// Tests use this instead of polling the file.
    func flush() async {
        await saveTask?.value
    }

    /// Lock + epoch so `save` and `clear` cannot interleave on disk.
    /// `@unchecked Sendable` because `NSLock` is: the lock is the isolation.
    private final class DiskGate: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0

        var epoch: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return generation
        }

        func write(_ data: Data, to url: URL, epoch: UInt64) throws {
            lock.lock()
            defer { lock.unlock() }
            guard epoch == generation else { return }
            try data.write(to: url, options: .atomic)
        }

        func clear(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            try? FileManager.default.removeItem(at: url)
        }
    }
}
