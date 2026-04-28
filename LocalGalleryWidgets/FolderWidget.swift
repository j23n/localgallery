import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Configuration

struct FolderEntity: AppEntity {
    var id: String
    var displayName: String
    var pathDescription: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    static let defaultQuery = FolderQuery()

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
    static let title: LocalizedStringResource = "Choose Folder"
    static let description = IntentDescription("Pick a folder to feature on this widget.")

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
        let pickIndices = pickRotation(
            count: candidates.count,
            slots: slots,
            seed: "\(WidgetDayKey.string())|folder|\(folder.id)"
        )
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
            let hero = WidgetHeroView(
                image: entry.image,
                title: entry.folderName ?? "",
                subtitle: entry.ref?.date.map(WidgetDateFormat.shared.string(from:))
            )
            if let url = WidgetDeepLink.folder(id: id).url {
                Link(destination: url) { hero }
            } else {
                hero
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
}

