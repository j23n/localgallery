import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @State private var selectedPhoto: PhotoFile?
    @State private var searchText: String = ""
    @State private var scrollToTopTrigger = false

    private var sortedPhotos: [PhotoFile] {
        manager.sortPhotos(photos)
    }

    private var filteredPhotos: [PhotoFile] {
        guard !searchText.isEmpty else { return sortedPhotos }
        let q = searchText.lowercased()
        return sortedPhotos.filter { photo in
            photo.filename.lowercased().contains(q) ||
            photo.keywords.contains { $0.lowercased().contains(q) } ||
            photo.hierarchicalTags.contains { $0.fullPath.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
        }
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
                        ForEach(filteredPhotos) { photo in
                            gridCell(photo: photo, cellSize: size)
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
        .refreshable {
            await manager.rescan()
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search by name or tag")
        .searchSuggestions {
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                // Build tag suggestions from this folder's photos
                let folderTags = Set(photos.flatMap(\.hierarchicalTags).map { $0.fullPath.lowercased() })
                let suggestions = manager.allTags.filter {
                    folderTags.contains($0.fullPath.lowercased()) &&
                    ($0.displayName.lowercased().contains(query) || $0.fullPath.lowercased().contains(query))
                }.prefix(8)
                ForEach(Array(suggestions)) { tag in
                    Label {
                        HStack {
                            Text(tag.displayName)
                            Spacer()
                            Text("\(tag.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Image(systemName: tag.icon)
                            .foregroundStyle(Design.accentColor)
                    }
                    .searchCompletion(tag.fullPath)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scrollToTopTrigger.toggle()
                } label: {
                    Image(systemName: "arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { cycleSizeTier() } label: {
                    Image(systemName: gridIconName)
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(photos: filteredPhotos, initialPhoto: photo)
        }
    }

    @ViewBuilder
    private func gridCell(photo: PhotoFile, cellSize: CGFloat) -> some View {
        ThumbnailView(url: photo.url, size: cellSize, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPhoto = photo
            }
    }

    private var gridIconName: String {
        switch sizeTier {
        case 0: return "square.grid.3x3"
        case 1: return "square.grid.3x3.fill"
        default: return "square.grid.4x3.fill"
        }
    }

    private func cycleSizeTier() {
        sizeTier = (sizeTier + 1) % 3
    }
}
