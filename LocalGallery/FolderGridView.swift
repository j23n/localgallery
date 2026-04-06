import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridColumnCount") private var columnCount: Int = 3
    @State private var selectedPhoto: PhotoFile?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showShareSheet = false

    private var sortedPhotos: [PhotoFile] {
        manager.sortPhotos(photos)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    private var cellSize: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        return max(1, (screenWidth - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(sortedPhotos) { photo in
                    gridCell(photo: photo, cellSize: cellSize)
                }
            }
        }
        .refreshable {
            await manager.rescan()
        }
        .navigationTitle(title)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIDs.removeAll()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(selectedIDs.count) selected")
                        .font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedIDs.count == sortedPhotos.count ? "Deselect All" : "Select All") {
                        if selectedIDs.count == sortedPhotos.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(sortedPhotos.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { cycleColumnCount() } label: {
                        Image(systemName: gridIconName)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSelecting = true } label: {
                        Image(systemName: "checkmark.circle")
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(photos: sortedPhotos, initialPhoto: photo)
        }
        .sheet(isPresented: $showShareSheet) {
            let urls: [Any] = sortedPhotos.filter { selectedIDs.contains($0.id) }.map(\.url)
            ShareSheet(items: urls)
        }
    }

    @ViewBuilder
    private func gridCell(photo: PhotoFile, cellSize: CGFloat) -> some View {
        ThumbnailView(url: photo.url, size: cellSize, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
            .frame(width: cellSize, height: cellSize)
            .overlay {
                if isSelecting && selectedIDs.contains(photo.id) {
                    Color.black.opacity(0.2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    ZStack {
                        if selectedIDs.contains(photo.id) {
                            Circle()
                                .fill(Design.accentColor)
                                .frame(width: 26, height: 26)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Circle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                                .frame(width: 26, height: 26)
                                .shadow(color: .black.opacity(0.4), radius: 3)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedIDs.contains(photo.id))
                    .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    if selectedIDs.contains(photo.id) {
                        selectedIDs.remove(photo.id)
                    } else {
                        selectedIDs.insert(photo.id)
                    }
                } else {
                    selectedPhoto = photo
                }
            }
    }

    private var gridIconName: String {
        switch columnCount {
        case 3: return "square.grid.3x3"
        case 4: return "rectangle.grid.3x2"
        default: return "rectangle.grid.3x2"
        }
    }

    private func cycleColumnCount() {
        switch columnCount {
        case 3: columnCount = 4
        case 4: columnCount = 5
        default: columnCount = 3
        }
    }
}
