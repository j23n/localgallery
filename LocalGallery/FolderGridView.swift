import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    @EnvironmentObject var manager: GalleryManager
    @State private var sortedPhotosCache: [PhotoFile]?

    private var sortedPhotos: [PhotoFile] {
        sortedPhotosCache ?? photos
    }

    var body: some View {
        PhotoGridScreen(
            title: title,
            subtitle: "\(sortedPhotos.count) photos",
            photos: sortedPhotos,
            showSearch: true
        )
        .task(id: photos) {
            sortedPhotosCache = manager.sortPhotos(photos)
        }
    }
}
