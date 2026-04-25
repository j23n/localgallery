import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Configuration

struct FolderEntity: AppEntity {
    var id: String
    var displayName: String
    var pathDescription: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    static var defaultQuery = FolderQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(pathDescription)")
    }
}

struct FolderQuery: EntityQuery {
    func entities(for identifiers: [FolderEntity.ID]) async throws -> [FolderEntity] {
        let all = currentEntries()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [FolderEntity] {
        currentEntries()
    }

    func defaultResult() async -> FolderEntity? {
        currentEntries().first
    }

    private func currentEntries() -> [FolderEntity] {
        guard let catalog = WidgetSnapshotReader.loadFolders() else { return [] }
        return catalog.folders.map { FolderEntity(id: $0.id, displayName: $0.displayName, pathDescription: $0.pathDescription) }
    }
}

struct FolderWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Folder"
    static var description = IntentDescription("Pick a folder to feature on this widget.")

    @Parameter(title: "Folder")
    var folder: FolderEntity?

    init() {}
    init(folder: FolderEntity?) { self.folder = folder }
}

// MARK: - Widget

struct FolderWidget: Widget {
    let kind: String = "FolderWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: FolderWidgetIntent.self, provider: FolderProvider()) { entry in
            FolderWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Folder")
        .description("Rotating photo from a folder of your choice.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FolderEntry: TimelineEntry {
    let date: Date
    let folderName: String?
    let folderId: String?
    let ref: WidgetPhotoRef?
    let image: UIImage?
}

struct FolderProvider: AppIntentTimelineProvider {
    typealias Entry = FolderEntry
    typealias Intent = FolderWidgetIntent

    func placeholder(in context: Context) -> FolderEntry {
        FolderEntry(date: Date(), folderName: "Folder", folderId: nil, ref: nil, image: nil)
    }

    func snapshot(for configuration: FolderWidgetIntent, in context: Context) async -> FolderEntry {
        buildEntries(for: configuration, slots: 1).first
            ?? FolderEntry(date: Date(), folderName: configuration.folder?.displayName, folderId: configuration.folder?.id, ref: nil, image: nil)
    }

    func timeline(for configuration: FolderWidgetIntent, in context: Context) async -> Timeline<FolderEntry> {
        let entries = buildEntries(for: configuration, slots: 12)
        let next = entries.last.map { $0.date.addingTimeInterval(2 * 60 * 60) }
            ?? Date().addingTimeInterval(2 * 60 * 60)
        return Timeline(entries: entries, policy: .after(next))
    }

    /// Build up to `slots` entries spaced 2h apart, each picking a different
    /// photo from the folder's pool deterministically (hash of slot index).
    /// 12 slots = 24 hours of rotation per timeline refresh.
    private func buildEntries(for configuration: FolderWidgetIntent, slots: Int) -> [FolderEntry] {
        let now = Date()
        guard let folder = configuration.folder else {
            return [FolderEntry(date: now, folderName: nil, folderId: nil, ref: nil, image: nil)]
        }
        guard let index = WidgetSnapshotReader.loadIndex() else {
            return [FolderEntry(date: now, folderName: folder.displayName, folderId: folder.id, ref: nil, image: nil)]
        }
        let candidates = index.photos(inFolder: folder.id)
        guard !candidates.isEmpty else {
            return [FolderEntry(date: now, folderName: folder.displayName, folderId: folder.id, ref: nil, image: nil)]
        }
        let pickIndices = pickRotation(count: candidates.count, slots: slots, seed: folder.id)
        return pickIndices.enumerated().map { (slot, idx) in
            let date = now.addingTimeInterval(Double(slot) * 2 * 60 * 60)
            let ref = candidates[idx]
            let image = WidgetSnapshotReader.thumbnail(for: ref)
            return FolderEntry(date: date, folderName: folder.displayName, folderId: folder.id, ref: ref, image: image)
        }
    }
}

struct FolderWidgetEntryView: View {
    let entry: FolderEntry

    var body: some View {
        if let id = entry.folderId, entry.ref != nil {
            Link(destination: WidgetDeepLink.folder(id: id).url) {
                WidgetHeroView(
                    image: entry.image,
                    title: entry.folderName ?? "",
                    subtitle: entry.ref?.date.map(formatted)
                )
            }
        } else if entry.folderName == nil {
            WidgetEmptyView(
                symbol: "folder",
                title: "Pick a folder",
                subtitle: "Long-press to configure"
            )
        } else {
            WidgetEmptyView(
                symbol: "folder",
                title: entry.folderName ?? "Folder",
                subtitle: "No photos yet"
            )
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Rotation

/// Picks `slots` distinct (when possible) indices from `0..<count` deterministically
/// keyed by `seed`, so refreshes show different photos but the order is stable
/// for the configured surface.
func pickRotation(count: Int, slots: Int, seed: String) -> [Int] {
    guard count > 0 else { return [] }
    var rng = SeededRNG(seed: seed)
    var pool = Array(0..<count).shuffled(using: &rng)
    if pool.count >= slots { return Array(pool.prefix(slots)) }
    // Pool smaller than slots — repeat with re-shuffle so back-to-back slots
    // don't show the same photo when the pool barely fits.
    var out = pool
    while out.count < slots {
        pool.shuffle(using: &rng)
        out.append(contentsOf: pool)
    }
    return Array(out.prefix(slots))
}

/// Tiny SplitMix64-derived RNG seeded by hashing a string. Deterministic per
/// seed across processes; widget extensions and previews see the same order.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: String) {
        var hasher = Hasher()
        hasher.combine(seed)
        // Hasher.finalize is per-process random — fine, but we want determinism
        // across launches. Fall back to a stable hash of the bytes.
        let bytes = Array(seed.utf8)
        var s: UInt64 = 0xcbf29ce484222325
        for b in bytes { s = (s ^ UInt64(b)) &* 0x100000001b3 }
        self.state = s == 0 ? 0xdeadbeef : s
    }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
