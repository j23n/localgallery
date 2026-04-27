import SwiftUI

struct AllPhotosView: View {
    @EnvironmentObject var manager: GalleryManager
    @EnvironmentObject var router: AppRouter
    @State private var seedTags: [TagSuggestion] = []

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
                    title: "Photos",
                    photos: manager.sortedPhotos,
                    isRoot: true,
                    showSearch: true,
                    showVisibleDateRange: true,
                    initialTags: seedTags
                )
                // Force fresh PhotoGridScreen state when a deep-link seeds new
                // tags so its internal @State activeTags actually adopts them.
                .id("photogrid-" + seedTags.map(\.id).joined(separator: "|"))
            }
        }
        .background(Design.bg)
        .onAppear { applyPendingTagFilter() }
        .onChange(of: router.pendingPhotosTagFilter) { _, _ in applyPendingTagFilter() }
    }

    private func applyPendingTagFilter() {
        guard !router.pendingPhotosTagFilter.isEmpty else { return }
        let resolved = router.pendingPhotosTagFilter.compactMap { path in
            manager.allTags.first { $0.fullPath == path }
        }
        seedTags = resolved
        router.pendingPhotosTagFilter = []
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
