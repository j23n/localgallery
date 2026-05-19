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
}
