import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @State private var selectedPhoto: PhotoFile?
    @State private var presentationID = UUID()
    @State private var searchText: String = ""
    @State private var scrollToTopTrigger = false
    @State private var sortedPhotosCache: [PhotoFile]?

    private var sortedPhotos: [PhotoFile] {
        sortedPhotosCache ?? photos
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

    private var grid: GridLayoutConfig { GridLayoutConfig(sizeTier: sizeTier) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let size = grid.cellSize(for: width)
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("__top__")
                    LazyVGrid(columns: grid.columns(for: width), spacing: 2) {
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
                    Image(systemName: grid.gridIconName)
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(photos: filteredPhotos, initialPhoto: photo)
                .id(presentationID)
        }
        .task {
            sortedPhotosCache = manager.sortPhotos(photos)
        }
    }

    @ViewBuilder
    private func gridCell(photo: PhotoFile, cellSize: CGFloat) -> some View {
        ThumbnailView(url: photo.url, size: cellSize, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onTapGesture {
                presentationID = UUID()
                selectedPhoto = photo
            }
    }

    private func cycleSizeTier() {
        GridLayoutConfig.cycleSizeTier(&sizeTier)
    }
}
