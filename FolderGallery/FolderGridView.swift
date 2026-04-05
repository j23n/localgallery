import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridColumnCount") private var columnCount: Int = 3
    @State private var selectedPhoto: PhotoFile?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    var body: some View {
        GeometryReader { geo in
            let cellSize = max(1, (geo.size.width - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount))
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
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
                Button {
                    cycleColumnCount()
                } label: {
                    Image(systemName: "square.grid.\(columnCount)x\(columnCount)")
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(
                photos: photos,
                initialPhoto: photo
            )
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
