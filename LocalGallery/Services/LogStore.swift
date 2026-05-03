import Foundation

/// In-memory ring buffer of recent log entries, surfaced by the in-app
/// LogsView. Mirrored from every `Log.<category>.<level>(...)` call via the
/// `TeeLogger` wrapper in `Logging.swift`.
///
/// Capped at 5,000 entries so memory stays bounded under high-frequency
/// scan/enrichment bursts. Adjacent identical messages collapse into a single
/// entry with a `repeatCount` suffix to avoid walls of duplicate lines.
@Observable
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    struct Entry: Identifiable {
        let id: UUID = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
        var repeatCount: Int = 1

        enum Level: String, CaseIterable, Sendable {
            case debug, info, warning, error

            var displayName: String { rawValue.uppercased() }
        }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 5_000

    private init() {}

    /// Thread-safe append. Bursts off the main thread coalesce naturally
    /// because the dispatch hop serializes inserts.
    nonisolated func append(level: Entry.Level, category: String, message: String) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        if Thread.isMainThread {
            insert(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.insert(entry) }
        }
    }

    private func insert(_ entry: Entry) {
        // Coalesce repeated identical (level, category, message) lines.
        if let last = entries.last,
           last.level == entry.level,
           last.category == entry.category,
           last.message == entry.message {
            entries[entries.count - 1].repeatCount += 1
            return
        }
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        if Thread.isMainThread {
            entries = []
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries = [] }
        }
    }

    /// Plain-text export for share / clipboard.
    var asText: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries.map { entry in
            let repeatSuffix = entry.repeatCount > 1 ? " ×\(entry.repeatCount)" : ""
            return "[\(fmt.string(from: entry.timestamp))] [\(entry.level.displayName)] [\(entry.category)] \(entry.message)\(repeatSuffix)"
        }.joined(separator: "\n")
    }
}
