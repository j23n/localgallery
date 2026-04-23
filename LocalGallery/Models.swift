import Foundation
import CoreGraphics
import CryptoKit

// MARK: - Hierarchical Tag

struct HierarchicalTag: Hashable, Codable, Sendable {
    let fullPath: String      // "People/Johannes" or "Places/Italy/Lazio/Rome"
    let namespace: String?    // "People", nil for flat tags
    let displayName: String   // leaf segment, e.g. "Johannes" or "Rome"

    /// Create from a photo-tools `digiKam:TagsList` entry. Paths are `/`-separated
    /// and already Titlecased by the writer (see photo-tools xmp-schema.md §3).
    init(raw: String) {
        self.fullPath = raw
        let parts = raw.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count > 1 {
            self.namespace = parts.first
            self.displayName = parts.last ?? raw
        } else {
            self.namespace = nil
            self.displayName = raw
        }
    }

    init(fullPath: String, namespace: String?, displayName: String) {
        self.fullPath = fullPath
        self.namespace = namespace
        self.displayName = displayName
    }
}

// MARK: - Tag Namespace Icons

enum TagNamespace {
    /// SF Symbol for one of the four photo-tools taxonomy roots.
    /// See photo-tools xmp-schema.md §2.
    static func icon(for namespace: String?) -> String {
        switch namespace?.lowercased() {
        case "people":  return "person.fill"
        case "places":  return "mappin.and.ellipse"
        case "objects": return "cube.fill"
        case "scenes":  return "photo.fill"
        default:        return "tag.fill"
        }
    }
}

// MARK: - Tag Suggestion

struct TagSuggestion: Identifiable, Hashable, Sendable {
    let id: String          // fullPath lowercased
    let displayName: String // leaf value
    let fullPath: String    // original hierarchical path
    let namespace: String?  // first segment or nil
    let count: Int          // number of photos with this tag
    var icon: String { TagNamespace.icon(for: namespace) }
}

// MARK: - Photo File

struct PhotoFile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let url: URL
    var filename: String
    var fileSize: Int64
    var dateTaken: Date?
    var isVideo: Bool = false
    var livePhotoVideoURL: URL? = nil
    var hierarchicalTags: [HierarchicalTag] = []
    /// ISO 3166-1 alpha-2 from `photo-tools:CountryCode` (uppercase, e.g. "IT").
    var countryCode: String? = nil
    /// File modDate at the time metadata was last read; nil = never enriched
    var enrichedFileDate: Date? = nil
    var gpsLatitude: Double? = nil
    var gpsLongitude: Double? = nil

    // Not persisted — loaded lazily at runtime
    var dimensions: CGSize? = nil
    var exif: EXIFData? = nil

    /// Flat leaf names derived from `hierarchicalTags`. Used for substring search
    /// and the legacy "Tags" list in EXIFPanelView.
    var keywords: [String] { hierarchicalTags.map(\.displayName) }

    enum CodingKeys: String, CodingKey {
        case id, url, filename, fileSize, dateTaken, isVideo, livePhotoVideoURL, hierarchicalTags, countryCode, enrichedFileDate, gpsLatitude, gpsLongitude
    }

    init(id: UUID, url: URL, filename: String, fileSize: Int64, dateTaken: Date?, isVideo: Bool = false, livePhotoVideoURL: URL? = nil, hierarchicalTags: [HierarchicalTag] = [], countryCode: String? = nil, enrichedFileDate: Date? = nil, gpsLatitude: Double? = nil, gpsLongitude: Double? = nil) {
        self.id = id
        self.url = url
        self.filename = filename
        self.fileSize = fileSize
        self.dateTaken = dateTaken
        self.isVideo = isVideo
        self.livePhotoVideoURL = livePhotoVideoURL
        self.hierarchicalTags = hierarchicalTags
        self.countryCode = countryCode
        self.enrichedFileDate = enrichedFileDate
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        filename = try c.decode(String.self, forKey: .filename)
        fileSize = try c.decode(Int64.self, forKey: .fileSize)
        dateTaken = try c.decodeIfPresent(Date.self, forKey: .dateTaken)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        livePhotoVideoURL = try c.decodeIfPresent(URL.self, forKey: .livePhotoVideoURL)
        hierarchicalTags = try c.decodeIfPresent([HierarchicalTag].self, forKey: .hierarchicalTags) ?? []
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        enrichedFileDate = try c.decodeIfPresent(Date.self, forKey: .enrichedFileDate)
        gpsLatitude = try c.decodeIfPresent(Double.self, forKey: .gpsLatitude)
        gpsLongitude = try c.decodeIfPresent(Double.self, forKey: .gpsLongitude)
    }

    static func == (lhs: PhotoFile, rhs: PhotoFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Deterministic UUID derived from the file URL path for stable identity across scans
    static func stableID(for url: URL) -> UUID {
        let hash = Insecure.MD5.hash(data: Data(url.standardized.path.utf8))
        let bytes = Array(hash)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct EXIFData: Equatable, Sendable {
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

struct PhotoFolder: Identifiable, Codable, Sendable {
    let id: UUID
    let url: URL
    var name: String
    var subfolders: [PhotoFolder]
    var photos: [PhotoFile]
    var coverPhotoURL: URL?
    var totalPhotoCount: Int
    var dateModified: Date?
    var dateCreated: Date?

    static func stableID(for url: URL) -> UUID {
        let hash = Insecure.MD5.hash(data: Data(("folder:" + url.standardized.path).utf8))
        let bytes = Array(hash)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Memory

enum MemoryType: String, Codable, Sendable {
    case onThisDay
    case yearsAgo
    case personOverTime
    case folderEvent
    case photoDensity
    case trip
}

struct Memory: Identifiable, Hashable, Codable, Sendable {
    let id: String            // deterministic key, e.g. "onThisDay", "yearsAgo-5"
    let type: MemoryType
    let title: String
    let subtitle: String?
    let photoIDs: [UUID]
    let coverPhotoID: UUID
    let dateRange: ClosedRange<Date>?
    let score: Double
    let yearsAgo: Int?
    let personName: String?

    static func == (lhs: Memory, rhs: Memory) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension MemoryType: Hashable {}

// MARK: - Folder Sort

enum FolderSortOrder: String, CaseIterable, Sendable {
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

