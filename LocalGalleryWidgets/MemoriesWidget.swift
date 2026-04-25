import SwiftUI
import WidgetKit

struct MemoriesWidget: Widget {
    let kind: String = "MemoriesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MemoriesProvider()) { entry in
            MemoriesWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Memories")
        .description("On this day, years ago, and birthdays from your library.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MemoriesEntry: TimelineEntry {
    let date: Date
    let item: MemorySnapshotItem?
    let image: UIImage?
}

struct MemoriesProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoriesEntry {
        MemoriesEntry(date: Date(), item: nil, image: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoriesEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoriesEntry>) -> Void) {
        let entry = makeEntry()
        // Memories rotate once per day — refresh after midnight.
        let nextMidnight = Calendar.current.nextDate(
            after: Date(), matching: DateComponents(hour: 0, minute: 5),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(60 * 60 * 24)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func makeEntry() -> MemoriesEntry {
        let now = Date()
        guard let snapshot = WidgetSnapshotReader.loadMemories() else {
            return MemoriesEntry(date: now, item: nil, image: nil)
        }
        // Highest-priority item whose validity window contains `now`.
        let validNow = snapshot.items
            .filter { $0.validFrom <= now && now < $0.validTo }
            .sorted { $0.priority > $1.priority }
        let pick = validNow.first ?? snapshot.items.first
        let image = pick?.photoRefs.first.flatMap(WidgetSnapshotReader.thumbnail)
        return MemoriesEntry(date: now, item: pick, image: image)
    }
}

struct MemoriesWidgetEntryView: View {
    let entry: MemoriesEntry

    var body: some View {
        if let item = entry.item {
            Link(destination: deepLink(for: item)) {
                WidgetHeroView(
                    image: entry.image,
                    title: item.title,
                    subtitle: item.subtitle,
                    glyph: item.kind == .birthday ? "gift.fill" : nil
                )
            }
        } else {
            WidgetEmptyView(
                symbol: "sparkles.rectangle.stack",
                title: "No memories yet",
                subtitle: "Open LocalGallery to scan your library"
            )
        }
    }

    private func deepLink(for item: MemorySnapshotItem) -> URL {
        WidgetDeepLink.memory(id: item.id).url
    }
}
