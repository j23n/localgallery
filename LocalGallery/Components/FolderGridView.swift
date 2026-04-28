import SwiftUI

struct FolderGridView: View {
    let title: String
    let photos: [PhotoFile]

    var body: some View {
        PhotoGridScreen(
            title: title,
            subtitle: "\(photos.count) photos",
            photos: photos,
            showSearch: true
        )
    }
}
