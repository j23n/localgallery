import SwiftUI

/// Cross-tab navigation state. Owns the tab selection plus per-tab path
/// bindings so widget deep links can land on the right screen.
///
/// Cold-launch resilience: when a deep link fires before the relevant data is
/// populated (folder tree from `restoreFolder()`, memories from generation),
/// the target id is queued in `pendingFolderId` / `pendingMemoryId` and the
/// view consumes it once the data appears. Same pattern as the existing
/// `pendingPhotosTagFilter` for the Photos tab.
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
    /// Folder id to navigate to when the folder tree finishes loading.
    @Published var pendingFolderId: String?
    /// Memory id to push as a slideshow when memories finish generating.
    @Published var pendingMemoryId: String?

    func handle(_ url: URL, manager: GalleryManager) {
        guard let link = WidgetDeepLink.parse(url) else { return }
        switch link {
        case .memory(let id):
            selectedTab = .collections
            applyMemory(id: id, manager: manager)
        case .folder(let id):
            selectedTab = .folders
            applyFolder(id: id, manager: manager)
        case .tags(let paths):
            selectedTab = .photos
            pendingPhotosTagFilter = paths
        }
    }

    /// Re-evaluate any queued deep link now that data may have loaded. Called
    /// by the views observing `manager.rootFolder` / `manager.memories`.
    func consumePendingIfReady(manager: GalleryManager) {
        if let id = pendingFolderId {
            applyFolder(id: id, manager: manager)
        }
        if let id = pendingMemoryId {
            applyMemory(id: id, manager: manager)
        }
    }

    private func applyFolder(id: String, manager: GalleryManager) {
        guard let root = manager.rootFolder else {
            pendingFolderId = id
            return
        }
        guard let folder = Self.findFolder(in: root, id: id) else {
            // Tree loaded but the folder is gone — drop the pending state so
            // we don't keep re-evaluating it.
            pendingFolderId = nil
            foldersPath = []
            return
        }
        pendingFolderId = nil
        if folder.subfolders.isEmpty && !folder.photos.isEmpty {
            foldersPath = [.grid(folder)]
        } else {
            foldersPath = [.browser(folder)]
        }
    }

    private func applyMemory(id: String, manager: GalleryManager) {
        if let memory = manager.memories.first(where: { $0.id == id }) {
            pendingMemoryId = nil
            collectionsPath = [.slideshow(memory)]
            return
        }
        // Memories haven't been generated yet OR this id no longer exists.
        // Queue the id only when memories are still empty (cold launch); if
        // they're populated and the id isn't there, the memory is gone.
        if manager.memories.isEmpty {
            pendingMemoryId = id
        } else {
            pendingMemoryId = nil
            collectionsPath = []
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
