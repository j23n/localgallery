import Foundation
import UIKit

/// Reads the JSON snapshots the main app publishes into the App Group.
/// Returns `nil` for any file that's missing or malformed — widgets fall
/// back to placeholder copy in that case.
enum WidgetSnapshotReader {

    static func loadIndex() -> WidgetIndex? { decode(from: SharedContainer.indexURL) }
    static func loadMemories() -> MemorySnapshot? { decode(from: SharedContainer.memoriesURL) }
    static func loadFolders() -> FolderCatalog? { decode(from: SharedContainer.foldersURL) }
    static func loadTags() -> TagCatalog? { decode(from: SharedContainer.tagsURL) }

    static func thumbnail(for ref: WidgetPhotoRef) -> UIImage? {
        guard let dir = SharedContainer.thumbsDir else { return nil }
        let path = dir.appendingPathComponent(ref.thumbnailFilename).path
        return UIImage(contentsOfFile: path)
    }

    private static func decode<T: Decodable>(from url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}

extension WidgetIndex {
    /// Photos that match all of the given hierarchical tag paths (AND-matched).
    /// `Places/*` tags match any photo whose tagPaths array starts with that
    /// prefix, mirroring `PhotoGridScreen`'s in-app tag filter behavior.
    func photos(matchingAllTags paths: [String]) -> [WidgetPhotoRef] {
        let needles = paths.map { $0.lowercased() }
        return photos.filter { ref in
            needles.allSatisfy { needle in
                ref.tagPaths.contains { haystack in
                    let hay = haystack.lowercased()
                    return hay == needle || hay.hasPrefix(needle + "/")
                }
            }
        }
    }

    func photos(inFolder folderId: String) -> [WidgetPhotoRef] {
        photos.filter { $0.folderId == folderId }
    }
}
