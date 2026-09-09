import Foundation

struct PhotoFolder: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    var subfolders: [PhotoFolder]
    var photos: [PhotoFile]
    var coverPhotoURL: URL?
    var totalPhotoCount: Int
    var dateModified: Date?
    var dateCreated: Date?

    /// Deterministic UUID derived from the folder URL path for stable identity across scans.
    static func stableID(for url: URL) -> UUID {
        StableUUID.derive(from: "folder:" + url.standardized.path)
    }

    /// Walk the live tree by identity. Pushed folder screens keep a snapshot
    /// from the NavigationLink; looking the id up here is how they pick up a
    /// rescan that dropped files or deleted this node.
    func folder(withID id: UUID) -> PhotoFolder? {
        if self.id == id { return self }
        for subfolder in subfolders {
            if let found = subfolder.folder(withID: id) { return found }
        }
        return nil
    }

    /// Directory URLs this node owns, including itself. A file watcher can
    /// subscribe to these and ignore photo file URLs, which would otherwise
    /// fire on every JPEG write.
    func directoryURLs() -> [URL] {
        [url] + subfolders.flatMap { $0.directoryURLs() }
    }

    /// Drop photos whose ids are in `ids` and recompute counts / cover.
    /// Empty folders stay — the user deleted files, not directories.
    func removingPhotos(_ ids: Set<UUID>) -> PhotoFolder {
        var folder = self
        folder.photos.removeAll { ids.contains($0.id) }
        folder.subfolders = folder.subfolders.map { $0.removingPhotos(ids) }
        folder.totalPhotoCount = folder.photos.count
            + folder.subfolders.reduce(0) { $0 + $1.totalPhotoCount }
        if let cover = folder.coverPhotoURL,
           !folder.photos.contains(where: { $0.url == cover }) {
            folder.coverPhotoURL = folder.photos.first?.url
                ?? folder.subfolders.first(where: { $0.coverPhotoURL != nil })?.coverPhotoURL
        }
        return folder
    }

    /// Append `photos` to the node with `id` and recompute counts / cover
    /// up the tree. No-op if that id is not in this subtree.
    func addingPhotos(_ photos: [PhotoFile], toFolderID id: UUID) -> PhotoFolder {
        var folder = self
        if folder.id == id {
            folder.photos.append(contentsOf: photos)
            if folder.coverPhotoURL == nil {
                folder.coverPhotoURL = photos.first?.url
            }
        } else {
            folder.subfolders = folder.subfolders.map { $0.addingPhotos(photos, toFolderID: id) }
        }
        folder.totalPhotoCount = folder.photos.count
            + folder.subfolders.reduce(0) { $0 + $1.totalPhotoCount }
        return folder
    }

    /// Replace the photo with a matching id, walking the whole tree.
    /// Used to keep folder rows in lockstep with `allPhotos` when only
    /// runtime fields (locality, sidecar cache) change.
    func replacingPhoto(_ photo: PhotoFile) -> PhotoFolder {
        replacingPhotos([photo.id: photo])
    }

    /// Replace any photo whose id is a key in `byID`. Counts and covers
    /// stay put — this is a field-level sync, not a membership change.
    func replacingPhotos(_ byID: [UUID: PhotoFile]) -> PhotoFolder {
        var folder = self
        for i in folder.photos.indices {
            if let updated = byID[folder.photos[i].id] {
                folder.photos[i] = updated
            }
        }
        folder.subfolders = folder.subfolders.map { $0.replacingPhotos(byID) }
        return folder
    }

    /// Insert `child` under the node with `parentID`.
    func inserting(_ child: PhotoFolder, inParent parentID: UUID) -> PhotoFolder {
        var folder = self
        if folder.id == parentID {
            if !folder.subfolders.contains(where: { $0.id == child.id }) {
                folder.subfolders.append(child)
            }
        } else {
            folder.subfolders = folder.subfolders.map { $0.inserting(child, inParent: parentID) }
        }
        return folder
    }
}
