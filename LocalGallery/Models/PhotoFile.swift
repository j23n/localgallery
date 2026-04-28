import Foundation
import CoreGraphics
import CryptoKit

struct PhotoFile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let url: URL
    var filename: String
    var fileSize: Int64
    var dateTaken: Date?
    /// True when `dateTaken` came from embedded metadata (EXIF for images,
    /// AVAsset creationDate for videos). False when it fell back to filesystem
    /// creation/modification dates — which tend to cluster on bulk-import days
    /// and pollute date-based memories.
    var dateFromMetadata: Bool = false
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
        case id, url, filename, fileSize, dateTaken, dateFromMetadata, isVideo, livePhotoVideoURL, hierarchicalTags, countryCode, enrichedFileDate, gpsLatitude, gpsLongitude
    }

    init(id: UUID, url: URL, filename: String, fileSize: Int64, dateTaken: Date?, dateFromMetadata: Bool = false, isVideo: Bool = false, livePhotoVideoURL: URL? = nil, hierarchicalTags: [HierarchicalTag] = [], countryCode: String? = nil, enrichedFileDate: Date? = nil, gpsLatitude: Double? = nil, gpsLongitude: Double? = nil) {
        self.id = id
        self.url = url
        self.filename = filename
        self.fileSize = fileSize
        self.dateTaken = dateTaken
        self.dateFromMetadata = dateFromMetadata
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
        dateFromMetadata = try c.decodeIfPresent(Bool.self, forKey: .dateFromMetadata) ?? false
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

    /// Deterministic UUID derived from the file URL path for stable identity across scans.
    /// Uses SHA-256 (prefix-16 bytes, RFC 4122 version 5 layout) — matches localmusic convention.
    static func stableID(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data(url.standardized.path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant RFC 4122
        return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                           bytes[4],  bytes[5],  bytes[6],  bytes[7],
                           bytes[8],  bytes[9],  bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
