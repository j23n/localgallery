import SwiftUI

struct AllPhotosView: View {
    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridColumnCount") private var columnCount: Int = 3
    @State private var searchText: String = ""
    @State private var selectedPhoto: PhotoFile?

    private var filteredPhotos: [PhotoFile] {
        manager.search(query: searchText)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    var body: some View {
        Group {
            if manager.allPhotos.isEmpty {
                if manager.isScanning {
                    ProgressView("Scanning…")
                } else {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.stack",
                        description: Text("Choose a folder in the Folders tab to get started.")
                    )
                }
            } else {
                photoGrid
            }
        }
        .navigationTitle("All Photos")
        .searchable(text: $searchText, prompt: "Search by filename")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $manager.currentSortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.label).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    cycleColumnCount()
                } label: {
                    Image(systemName: "square.grid.\(columnCount)x\(columnCount)")
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(
                photos: filteredPhotos,
                initialPhoto: photo
            )
        }
    }

    private var photoGrid: some View {
        GeometryReader { geo in
            let cellSize = max(1, (geo.size.width - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount))
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(filteredPhotos) { photo in
                        ThumbnailView(url: photo.url, size: cellSize)
                            .frame(width: cellSize, height: cellSize)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPhoto = photo
                            }
                    }
                }
            }
        }
    }

    private func cycleColumnCount() {
        switch columnCount {
        case 2: columnCount = 3
        case 3: columnCount = 4
        default: columnCount = 2
        }
    }
}
