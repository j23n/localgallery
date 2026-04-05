import Foundation
import CoreGraphics

struct PhotoFile: Identifiable, Hashable, Codable {
    let id: UUID
    let url: URL
    var filename: String
    var fileSize: Int64
    var dateTaken: Date?

    // Not persisted — loaded lazily at runtime
    var dimensions: CGSize? = nil
    var exif: EXIFData? = nil

    enum CodingKeys: String, CodingKey {
        case id, url, filename, fileSize, dateTaken
    }

    static func == (lhs: PhotoFile, rhs: PhotoFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct EXIFData: Equatable {
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var aperture: Double?
    var shutterSpeed: Double?
    var iso: Int?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
    var dateTimeOriginal: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
}

struct PhotoFolder: Identifiable, Codable {
    let id: UUID
    let url: URL
    var name: String
    var subfolders: [PhotoFolder]
    var photos: [PhotoFile]
    var coverPhotoURL: URL?
    var totalPhotoCount: Int
    var dateModified: Date?
    var dateCreated: Date?
}

enum FolderSortOrder: String, CaseIterable {
    case nameAscending
    case nameDescending
    case dateModifiedNewest
    case dateModifiedOldest
    case dateCreatedNewest
    case dateCreatedOldest

    var label: String {
        switch self {
        case .nameAscending: return "Name ↑"
        case .nameDescending: return "Name ↓"
        case .dateModifiedNewest: return "Modified ↓"
        case .dateModifiedOldest: return "Modified ↑"
        case .dateCreatedNewest: return "Created ↓"
        case .dateCreatedOldest: return "Created ↑"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case nameAscending
    case nameDescending
    case dateAscending
    case dateDescending
    case sizeAscending
    case sizeDescending

    var label: String {
        switch self {
        case .nameAscending: return "Name ↑"
        case .nameDescending: return "Name ↓"
        case .dateAscending: return "Date ↑"
        case .dateDescending: return "Date ↓"
        case .sizeAscending: return "Size ↑"
        case .sizeDescending: return "Size ↓"
        }
    }
}
