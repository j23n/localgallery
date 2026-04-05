import Foundation
import CoreGraphics

struct PhotoFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var filename: String
    var fileSize: Int64
    var dateTaken: Date?
    var dimensions: CGSize?
    var exif: EXIFData?

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

struct PhotoFolder: Identifiable {
    let id: UUID
    let url: URL
    var name: String
    var subfolders: [PhotoFolder]
    var photos: [PhotoFile]
    var coverPhotoURL: URL?
    var totalPhotoCount: Int
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
