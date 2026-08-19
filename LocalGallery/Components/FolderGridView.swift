import SwiftUI

struct FolderGridView: View {
    /// Fallback title when the live node is gone (deleted while this grid
    /// was on the stack). The live folder's name wins when the lookup hits.
    let title: String
    let folderID: UUID

    @Environment(GalleryStore.self) private var store

    private var liveFolder: PhotoFolder? {
        store.rootFolder?.folder(withID: folderID)
    }

    var body: some View {
        if store.libraryAvailability == .unavailable {
            LibraryEmptyState.unavailable(icon: "folder") {
                Task { await store.rescan(kind: .light, silent: false) }
            }
            .navigationTitle(title)
        } else if let liveFolder {
            let photos = liveFolder.photos
            PhotoGridScreen(
                title: liveFolder.name,
                subtitle: "\(photos.count) photos",
                photos: photos,
                showSearch: true
            )
        } else {
            ContentUnavailableView(
                "This folder is no longer available",
                systemImage: "folder"
            )
            .navigationTitle(title)
        }
    }
}
