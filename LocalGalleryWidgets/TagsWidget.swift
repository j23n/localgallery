import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Configuration

struct TagEntity: AppEntity {
    var id: String              // tag full path (case-preserved)
    var displayName: String     // leaf segment

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static var defaultQuery = TagQuery()

    var displayRepresentation: DisplayRepresentation {
        let parts = id.split(separator: "/")
        let parent = parts.dropLast().joined(separator: " › ")
        return DisplayRepresentation(title: "\(displayName)", subtitle: parent.isEmpty ? nil : "\(parent)")
    }
}

struct TagQuery: EntityStringQuery {
    func entities(for identifiers: [TagEntity.ID]) async throws -> [TagEntity] {
        let all = currentEntities()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [TagEntity] {
        let q = string.lowercased()
        return currentEntities().filter { $0.id.lowercased().contains(q) }
    }

    func suggestedEntities() async throws -> [TagEntity] {
        Array(currentEntities().prefix(50))
    }

    private func currentEntities() -> [TagEntity] {
        guard let catalog = WidgetSnapshotReader.loadTags() else { return [] }
        return catalog.tagPaths.map { path in
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            return TagEntity(id: path, displayName: leaf)
        }
    }
}

struct TagsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Tags"
    static var description = IntentDescription("Pick one or more tags. Photos must match all of them (AND).")

    @Parameter(title: "Tags")
    var tags: [TagEntity]?

    init() {}
    init(tags: [TagEntity]?) { self.tags = tags }
}

// MARK: - Widget

struct TagsWidget: Widget {
    let kind: String = "TagsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TagsWidgetIntent.self, provider: TagsProvider()) { entry in
            TagsWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Tags")
        .description("Rotating photo from your library matching the chosen tags.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TagsEntry: TimelineEntry {
    let date: Date
    let tagPaths: [String]
    let label: String
    let ref: WidgetPhotoRef?
    let image: UIImage?
}

struct TagsProvider: AppIntentTimelineProvider {
    typealias Entry = TagsEntry
    typealias Intent = TagsWidgetIntent

    func placeholder(in context: Context) -> TagsEntry {
        TagsEntry(date: Date(), tagPaths: [], label: "Tags", ref: nil, image: nil)
    }

    func snapshot(for configuration: TagsWidgetIntent, in context: Context) async -> TagsEntry {
        buildEntries(for: configuration, slots: 1).first
            ?? TagsEntry(date: Date(), tagPaths: configuration.tags?.map(\.id) ?? [], label: label(for: configuration), ref: nil, image: nil)
    }

    func timeline(for configuration: TagsWidgetIntent, in context: Context) async -> Timeline<TagsEntry> {
        let entries = buildEntries(for: configuration, slots: 12)
        let next = entries.last.map { $0.date.addingTimeInterval(2 * 60 * 60) }
            ?? Date().addingTimeInterval(2 * 60 * 60)
        return Timeline(entries: entries, policy: .after(next))
    }

    private func buildEntries(for configuration: TagsWidgetIntent, slots: Int) -> [TagsEntry] {
        let now = Date()
        let paths = configuration.tags?.map(\.id) ?? []
        let label = label(for: configuration)
        guard !paths.isEmpty else {
            return [TagsEntry(date: now, tagPaths: paths, label: label, ref: nil, image: nil)]
        }
        guard let index = WidgetSnapshotReader.loadIndex() else {
            return [TagsEntry(date: now, tagPaths: paths, label: label, ref: nil, image: nil)]
        }
        let candidates = index.photos(matchingAllTags: paths)
        guard !candidates.isEmpty else {
            return [TagsEntry(date: now, tagPaths: paths, label: label, ref: nil, image: nil)]
        }
        let pickIndices = pickRotation(count: candidates.count, slots: slots, seed: paths.joined(separator: "|"))
        return pickIndices.enumerated().map { (slot, idx) in
            let date = now.addingTimeInterval(Double(slot) * 2 * 60 * 60)
            let ref = candidates[idx]
            let image = WidgetSnapshotReader.thumbnail(for: ref)
            return TagsEntry(date: date, tagPaths: paths, label: label, ref: ref, image: image)
        }
    }

    private func label(for configuration: TagsWidgetIntent) -> String {
        let names = configuration.tags?.map(\.displayName) ?? []
        if names.isEmpty { return "Tags" }
        if names.count == 1 { return names[0] }
        return names.joined(separator: " + ")
    }
}

struct TagsWidgetEntryView: View {
    let entry: TagsEntry

    var body: some View {
        if entry.tagPaths.isEmpty {
            WidgetEmptyView(
                symbol: "tag",
                title: "Pick tags",
                subtitle: "Long-press to configure"
            )
        } else if entry.ref == nil {
            WidgetEmptyView(
                symbol: "tag",
                title: entry.label,
                subtitle: "No photos match"
            )
        } else {
            Link(destination: WidgetDeepLink.tags(paths: entry.tagPaths).url) {
                WidgetHeroView(
                    image: entry.image,
                    title: entry.label,
                    subtitle: entry.ref?.date.map(formatted)
                )
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
