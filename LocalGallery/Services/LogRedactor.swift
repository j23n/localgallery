import Foundation

/// Categories of identifying data we tokenize before logging. Each kind has
/// its own counter sequence so a folder named "Anna" and a person named
/// "Anna" mint different tokens (`folder#3` vs `person#5`). Adding a new
/// kind costs one line in the enum + one helper in `Log.r`.
enum RedactionKind: String, Sendable, CaseIterable {
    case folder
    case person
    case tag
    case title
    case path
    case memory
    case trip
    case contact
    case filename
    case other
}

/// Sequence-based, persisted token assignment used by `Log.r.*` to scrub
/// identifying strings from log output. Tokens look like `folder#7`,
/// `person#3`, `tag#42`, `title#11`. The reverse map lives in a single
/// JSON file in Application Support so a debug session can recover the
/// original strings locally; the file is **never** included in the crash
/// share bundle (`CrashDiagnosticsService` only ships the log tail).
///
/// Tokens are stable across launches — counters and mappings load on init,
/// new entries append and trigger a debounced rewrite. We don't rotate or
/// clear the file; it just gets overwritten in place as new values appear.
final class LogRedactor: @unchecked Sendable {
    static let shared = LogRedactor()

    /// `kind.rawValue` → `value` → counter. Encoded as nested JSON object.
    private var counters: [String: [String: Int]] = [:]
    private let lock = NSLock()
    private let fileURL: URL

    /// Debounced background write. Cancelled and replaced on each new
    /// mapping so a busy scan minting hundreds of tokens still writes once.
    private var saveTask: Task<Void, Never>?
    private static let saveDebounceNanoseconds: UInt64 = 500_000_000  // 500 ms

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = appSupport.appendingPathComponent("log-redaction-key.json")
        }
        loadFromDisk()
    }

    /// Path the Settings "Export Redaction Key" button shares. Stable across
    /// launches; the file is overwritten in place by `scheduleSave`.
    var keyFileURL: URL { fileURL }

    /// Mint or retrieve a token for `value` within `kind`. Empty strings
    /// short-circuit to a sentinel so the redactor never stores blanks.
    func token(_ value: String, kind: RedactionKind) -> String {
        guard !value.isEmpty else { return "<empty>" }
        let kindKey = kind.rawValue
        lock.lock()
        defer { lock.unlock() }
        if let existing = counters[kindKey]?[value] {
            return "\(kindKey)#\(existing)"
        }
        let next = counters[kindKey]?.count ?? 0
        counters[kindKey, default: [:]][value] = next
        scheduleSave()
        return "\(kindKey)#\(next)"
    }

    /// Convenience for URLs — tokenizes the standardized path string under
    /// `.path`. The token represents the whole path; we don't split on `/`
    /// because folder components are already tokenized via `Log.r.folder`
    /// at the call sites that care about that level of granularity.
    func token(_ url: URL, kind: RedactionKind = .path) -> String {
        token(url.standardized.path, kind: kind)
    }

    /// Synchronous read for tests / Settings UI. Locks briefly to snapshot
    /// the dict before serializing.
    func snapshot() -> [String: [String: Int]] {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else {
            return
        }
        counters = decoded
    }

    /// Always called under `lock`. Cancels any pending write and schedules
    /// a fresh one ~500 ms out. The encoded snapshot is captured by-value
    /// so the writer task doesn't need the lock.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = counters
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            if Task.isCancelled { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension Log {
    /// Compile-time `Log.r.<kind>(value)` namespace. Every helper is a thin
    /// wrapper around `LogRedactor.shared.token(_:kind:)` so call sites read
    /// naturally inside Swift string interpolation:
    ///
    ///     Log.scan.info("\(Log.r.folder(dirName)): \(count) files")
    ///
    /// Add a new helper here whenever a new `RedactionKind` enters the
    /// enum. Helpers return `String`, not a `Redacted` wrapper, so the
    /// existing `TeeLogger.<level>(_ message: String)` autoclosure shape
    /// keeps working unchanged.
    enum r {
        static func folder(_ s: String) -> String { LogRedactor.shared.token(s, kind: .folder) }
        static func person(_ s: String) -> String { LogRedactor.shared.token(s, kind: .person) }
        static func tag(_ s: String) -> String { LogRedactor.shared.token(s, kind: .tag) }
        static func title(_ s: String) -> String { LogRedactor.shared.token(s, kind: .title) }
        static func path(_ url: URL) -> String { LogRedactor.shared.token(url) }
        static func path(_ s: String) -> String { LogRedactor.shared.token(s, kind: .path) }
        static func memory(_ s: String) -> String { LogRedactor.shared.token(s, kind: .memory) }
        static func trip(_ s: String) -> String { LogRedactor.shared.token(s, kind: .trip) }
        static func contact(_ s: String) -> String { LogRedactor.shared.token(s, kind: .contact) }
        static func filename(_ s: String) -> String { LogRedactor.shared.token(s, kind: .filename) }
        static func other(_ s: String) -> String { LogRedactor.shared.token(s, kind: .other) }
        /// Errors: `localizedDescription` routinely embeds file names/paths
        /// (e.g. CocoaError "The file 'IMG_4032.jpg' couldn't be opened"), so
        /// the description is tokenized whole; the domain/code prefix carries
        /// no identifying data and stays readable for diagnosis.
        static func error(_ e: any Swift.Error) -> String {
            let ns = e as NSError
            return "\(ns.domain)#\(ns.code) \(LogRedactor.shared.token(ns.localizedDescription, kind: .other))"
        }
    }
}
