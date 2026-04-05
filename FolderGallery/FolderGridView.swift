import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridColumnCount") private var columnCount: Int = 3
    @State private var selectedPhoto: PhotoFile?

    private var sortedPhotos: [PhotoFile] {
        manager.sortPhotos(photos)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    var body: some View {
        GeometryReader { geo in
            let cellSize = max(1, (geo.size.width - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount))
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(sortedPhotos) { photo in
                        ThumbnailView(url: photo.url, size: cellSize)
                            .frame(width: cellSize, height: cellSize)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPhoto = photo
                            }
                    }
                }
                .padding(.horizontal, 0)
            }
        }
        .navigationTitle(title)
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
                    Image(systemName: gridIconName)
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(
                photos: sortedPhotos,
                initialPhoto: photo
            )
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
