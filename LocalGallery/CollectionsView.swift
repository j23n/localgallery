import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject var manager: GalleryManager

    private var events: [PhotoFolder] {
        manager.leafFolders.sorted { a, b in
            let aDate = a.photos.compactMap(\.dateTaken).max() ?? .distantPast
            let bDate = b.photos.compactMap(\.dateTaken).max() ?? .distantPast
            return aDate > bDate
        }
    }

    var body: some View {
        Group {
            if manager.allPhotos.isEmpty {
                if manager.isScanning {
                    ProgressView("Scanning…")
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 64, weight: .thin))
                            .foregroundStyle(Design.accentColor.opacity(0.7))
                        VStack(spacing: 8) {
                            Text("No Collections")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("Choose a folder in Settings to get started.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(32)
                }
            } else {
                collectionsList
            }
        }
        .navigationTitle("Collections")
    }

    private var collectionsList: some View {
        List {
            let people = manager.peopleTags
            if !people.isEmpty {
                Section("People") {
                    ForEach(people) { person in
                        NavigationLink {
                            TagGridView(tag: person)
                        } label: {
                            Label {
                                HStack {
                                    Text(person.displayName)
                                    Spacer()
                                    Text("\(person.count)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(Design.accentColor)
                            }
                        }
                    }
                }
            }

            let eventFolders = events
            if !eventFolders.isEmpty {
                Section("Events") {
                    ForEach(eventFolders) { folder in
                        NavigationLink {
                            FolderGridView(title: folder.name, photos: folder.photos)
                        } label: {
                            eventRow(folder)
                        }
                    }
                }
            }

            if manager.peopleTags.isEmpty && events.isEmpty {
                ContentUnavailableView(
                    "No Collections Yet",
                    systemImage: "rectangle.stack",
                    description: Text("People tags and photo folders will appear here.")
                )
            }
        }
    }

    private func eventRow(_ folder: PhotoFolder) -> some View {
        HStack(spacing: 14) {
            if let coverURL = folder.coverPhotoURL {
                ThumbnailView(url: coverURL, size: 72, cornerRadius: 8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(folder.photos.count) photos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let dateRange = eventDateRange(folder) {
                        Text(dateRange)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func eventDateRange(_ folder: PhotoFolder) -> String? {
        let dates = folder.photos.compactMap(\.dateTaken).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return fmt.string(from: first)
        }
        return "\(fmt.string(from: first)) – \(fmt.string(from: last))"
    }
}

// MARK: - Tag Grid View (photos for a specific tag)

struct TagGridView: View {
    let tag: TagSuggestion
    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @State private var selectedPhoto: PhotoFile?
    @State private var scrollToTopTrigger = false

    private var photos: [PhotoFile] {
        manager.search(query: "", requiredTags: [tag])
    }

    private var targetCellSize: CGFloat {
        switch sizeTier {
        case 0: return 130
        case 1: return 100
        default: return 78
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        max(2, Int((width + 2) / (targetCellSize + 2)))
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount(for: width))
    }

    private func cellSize(for width: CGFloat) -> CGFloat {
        let cols = columnCount(for: width)
        return max(1, (width - CGFloat(cols - 1) * 2) / CGFloat(cols))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let size = cellSize(for: width)
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("__top__")
                    LazyVGrid(columns: columns(for: width), spacing: 2) {
                        ForEach(photos) { photo in
                            ThumbnailView(url: photo.url, size: size, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
                                .frame(width: size, height: size)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedPhoto = photo
                                }
                        }
                    }
                }
                .onChange(of: scrollToTopTrigger) {
                    withAnimation {
                        proxy.scrollTo("__top__", anchor: .top)
                    }
                }
            }
        }
        .navigationTitle(tag.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scrollToTopTrigger.toggle()
                } label: {
                    Image(systemName: "arrow.up")
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(photos: photos, initialPhoto: photo)
        }
    }
}
