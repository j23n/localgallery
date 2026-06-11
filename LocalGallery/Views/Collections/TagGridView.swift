import SwiftUI

// MARK: - Tag Grid View

struct TagGridView: View {
    let tag: TagSuggestion
    @Environment(GalleryStore.self) private var store

    private var photos: [PhotoFile] {
        store.search(query: "", requiredTags: [tag])
    }

    private var isPersonTag: Bool {
        tag.namespace?.lowercased() == "people"
    }

    var body: some View {
        PhotoGridScreen(
            title: tag.displayName,
            subtitle: tag.fullPath.replacingOccurrences(of: "/", with: " › "),
            photos: photos,
            featureContextPerson: isPersonTag ? tag : nil
        )
    }
}

