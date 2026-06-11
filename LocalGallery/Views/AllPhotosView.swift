import SwiftUI

struct AllPhotosView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var seedTags: [TagSuggestion] = []

    var body: some View {
        Group {
            if store.allPhotos.isEmpty {
                if store.isScanning {
                    ProgressView("Scanning…")
                } else {
                    emptyState
                }
            } else {
                PhotoGridScreen(
                    title: "Photos",
                    photos: store.sortedPhotos,
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
            store.allTags.first { $0.fullPath == path }
        }
        seedTags = resolved
        router.pendingPhotosTagFilter = []
    }

    private var emptyState: some View {
        LibraryEmptyState(icon: "photo.stack", title: "No Photos")
    }
}
