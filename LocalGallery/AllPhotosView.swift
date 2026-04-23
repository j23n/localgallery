import SwiftUI

struct AllPhotosView: View {
    @EnvironmentObject var manager: GalleryManager

    var body: some View {
        Group {
            if manager.allPhotos.isEmpty {
                if manager.isScanning {
                    ProgressView("Scanning…")
                } else {
                    emptyState
                }
            } else {
                PhotoGridScreen(
                    title: "All Photos",
                    subtitle: "\(manager.sortedPhotos.count) photos",
                    photos: manager.sortedPhotos,
                    isRoot: true,
                    showSearch: true
                )
            }
        }
        .background(Design.bg)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(Design.accentColor.opacity(0.7))
            VStack(spacing: 8) {
                Text("No Photos")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.ink)
                Text("Choose a folder in Settings to get started.")
                    .font(.subheadline)
                    .foregroundStyle(Design.ink2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}
