import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject var manager: GalleryManager

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
            if !manager.memories.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(manager.memories) { memory in
                                NavigationLink {
                                    MemoryDetailView(memory: memory)
                                } label: {
                                    MemoryCardView(memory: memory)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    Label("Memories", systemImage: "sparkles")
                }
            }

            let people = manager.topPeople
            if !people.isEmpty {
                Section("People") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                        ForEach(people) { person in
                            NavigationLink {
                                TagGridView(tag: person)
                            } label: {
                                PersonCard(tag: person)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !manager.eventFolders.isEmpty {
                Section("Events") {
                    ForEach(manager.eventFolders) { folder in
                        NavigationLink {
                            FolderGridView(title: folder.name, photos: folder.photos)
                        } label: {
                            eventRow(folder)
                        }
                    }
                }
            }

            if manager.peopleTags.isEmpty && manager.eventFolders.isEmpty {
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
    @State private var presentationID = UUID()
    @State private var scrollToTopTrigger = false

    private var photos: [PhotoFile] {
        manager.search(query: "", requiredTags: [tag])
    }

    private var grid: GridLayoutConfig { GridLayoutConfig(sizeTier: sizeTier) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let size = grid.cellSize(for: width)
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("__top__")
                    LazyVGrid(columns: grid.columns(for: width), spacing: 2) {
                        ForEach(photos) { photo in
                            ThumbnailView(url: photo.url, size: size, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
                                .frame(width: size, height: size)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    presentationID = UUID()
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
                .id(presentationID)
        }
    }
}

// MARK: - Person Card (2×2 thumbnail grid + name)

struct PersonCard: View {
    let tag: TagSuggestion
    @EnvironmentObject var manager: GalleryManager

    private var coverPhotos: [PhotoFile] {
        Array(manager.photos(forTag: tag).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let photos = coverPhotos
            GeometryReader { geo in
                let size = (geo.size.width - 2) / 2
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        if i < photos.count {
                            ThumbnailView(url: photos[i].url, size: size, cornerRadius: 0)
                                .frame(width: size, height: size)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(Color(.systemGray5))
                                .frame(width: size, height: size)
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(tag.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(tag.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Memory Card View

struct MemoryCardView: View {
    let memory: Memory
    @EnvironmentObject var manager: GalleryManager

    private var coverURL: URL? {
        manager.photo(byID: memory.coverPhotoID)?.url
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = coverURL {
                ThumbnailView(url: url, size: 240)
                    .frame(width: 240, height: 200)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray5))
                    .frame(width: 240, height: 200)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: 240, height: 200)

            VStack(alignment: .leading, spacing: 2) {
                Text(memory.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle = memory.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text("\(memory.photoIDs.count) photos")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
        }
        .frame(width: 240, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Memory Detail View

struct MemoryDetailView: View {
    let memory: Memory
    @EnvironmentObject var manager: GalleryManager

    var body: some View {
        FolderGridView(title: memory.title, photos: manager.photos(for: memory))
    }
}
