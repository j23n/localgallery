import SwiftUI

/// Cross-tab navigation state. Owns the tab selection plus per-tab path
/// bindings so widget deep links can land on the right screen.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case folders, collections, photos
    }

    @Published var selectedTab: Tab = .folders
    @Published var foldersPath: [FolderRoute] = []
    @Published var collectionsPath: [CollectionsRoute] = []
    /// Tag full-paths to apply when AllPhotosView next appears. Cleared after
    /// the view consumes it so subsequent visits don't re-apply the filter.
    @Published var pendingPhotosTagFilter: [String] = []

    func handle(_ url: URL, manager: GalleryManager) {
        guard let link = WidgetDeepLink.parse(url) else { return }
        switch link {
        case .memory(let id):
            selectedTab = .collections
            if let memory = manager.memories.first(where: { $0.id == id }) {
                collectionsPath = [.slideshow(memory)]
            } else {
                collectionsPath = []
            }
        case .folder(let id):
            selectedTab = .folders
            if let root = manager.rootFolder, let folder = Self.findFolder(in: root, id: id) {
                if folder.subfolders.isEmpty && !folder.photos.isEmpty {
                    foldersPath = [.grid(folder)]
                } else {
                    foldersPath = [.browser(folder)]
                }
            } else {
                foldersPath = []
            }
        case .tags(let paths):
            selectedTab = .photos
            pendingPhotosTagFilter = paths
        }
    }

    private static func findFolder(in folder: PhotoFolder, id: String) -> PhotoFolder? {
        if folder.id.uuidString == id { return folder }
        for sub in folder.subfolders {
            if let found = findFolder(in: sub, id: id) { return found }
        }
        return nil
    }
}

/// Typed navigation values for the Folders tab. Hosting the path at the tab
/// root lets widget deep-links push directly into a folder.
enum FolderRoute: Hashable {
    case browser(PhotoFolder)
    case grid(PhotoFolder)
}
