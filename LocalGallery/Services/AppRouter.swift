import SwiftUI

/// Cross-tab navigation state. Owns the tab selection plus per-tab path
/// bindings so widget deep links can land on the right screen.
///
/// Cold-launch resilience: when a deep link fires before the relevant data is
/// populated (folder tree from `restoreFolder()`, memories from generation),
/// the target id is queued in `pendingFolderId` / `pendingMemoryId` and the
/// view consumes it once the data appears. Same pattern as the existing
/// `pendingPhotosTagFilter` for the Photos tab.
@Observable
@MainActor
final class AppRouter {
    enum Tab: Hashable {
        case folders, collections, photos
    }

    var selectedTab: Tab = .folders
    var foldersPath: [FolderRoute] = []
    var collectionsPath: [CollectionsRoute] = []
    /// Tag full-paths to apply when AllPhotosView next appears. Cleared after
    /// the view consumes it so subsequent visits don't re-apply the filter.
    var pendingPhotosTagFilter: [String] = []
    /// Folder id to navigate to when the folder tree finishes loading.
    var pendingFolderId: String?
    /// Memory id to push as a slideshow when memories finish generating.
    var pendingMemoryId: String?

    func handle(_ url: URL, store: GalleryStore) {
        guard let link = WidgetDeepLink.parse(url) else { return }
        switch link {
        case .memory(let id):
            selectedTab = .collections
            applyMemory(id: id, store: store)
        case .folder(let id):
            selectedTab = .folders
            applyFolder(id: id, store: store)
        case .tags(let paths):
            selectedTab = .photos
            pendingPhotosTagFilter = paths
        }
    }

    /// Re-evaluate any queued deep link now that data may have loaded. Called
    /// by the views observing `store.rootFolder` / `store.memories`.
    func consumePendingIfReady(store: GalleryStore) {
        if let id = pendingFolderId {
            applyFolder(id: id, store: store)
        }
        if let id = pendingMemoryId {
            applyMemory(id: id, store: store)
        }
    }

    private func applyFolder(id: String, store: GalleryStore) {
        guard let root = store.rootFolder else {
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

    private func applyMemory(id: String, store: GalleryStore) {
        if let memory = store.memories.all.first(where: { $0.id == id }) {
            pendingMemoryId = nil
            collectionsPath = [.slideshow(memory)]
            return
        }
        // The id isn't resolvable yet. On a cold launch `memories` holds
        // *yesterday's* cached entries, so non-empty is no proof the memory
        // is gone — a widget tap on a pre-published scheduled memory (whose
        // id only exists once today's generation runs) must stay queued
        // until the daily regeneration has actually happened today.
        if store.memories.hasGeneratedToday {
            pendingMemoryId = nil
            collectionsPath = []
        } else {
            pendingMemoryId = id
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
