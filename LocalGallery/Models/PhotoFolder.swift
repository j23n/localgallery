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
}
