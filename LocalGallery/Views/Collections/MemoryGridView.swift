import SwiftUI

// MARK: - Memory grid mode (reachable via "See all" from slideshow)

struct MemoryGridView: View {
    let memory: Memory
    @Environment(GalleryStore.self) private var store

    var body: some View {
        PhotoGridScreen(
            title: memory.title,
            subtitle: memory.subtitle,
            photos: store.photos(for: memory),
            playableMemory: memory
        )
    }
}

