import Foundation
import CoreGraphics
import CryptoKit

/// Where the photo's bytes live. `.local` covers any file fully readable
/// from disk, including provider-backed files that have already materialised.
/// `.remote(downloaded: false)` is the placeholder state — the file appears
/// in directory listings but its bytes haven't been fetched.
enum PhotoLocality: Codable, Hashable, Sendable {
    case local
    case remote(downloaded: Bool)
}

/// Whether we have a parsed copy of the photo's `.xmp` sidecar in
/// `SidecarCacheStore`. Search/tag features only consider `.cached(_)` photos.
enum SidecarStatus: Codable, Hashable, Sendable {
    case absent
    case cached(FileProviderDetector.ContentVersion)
    case pendingFetch
    case fetchFailed(reason: String)
}

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
    /// MWG `mwg-rs:RegionInfo` entries — one per detected face. Empty when the
    /// source XMP carries none. Used by the People rail to crop thumbnails to
    /// the matching face.
    var faceRegions: [FaceRegion] = []
    /// Where the photo bytes live. Default `.local`; populated by the scanner
    /// for file-provider URLs. Runtime/cache state — not part of the stable
    /// UUID derivation.
    var locality: PhotoLocality = .local
    /// Sidecar cache state. Default `.absent`; populated by `SidecarSyncService`
    /// once a `.xmp` for this photo has been parsed and persisted.
    var sidecarStatus: SidecarStatus = .absent

    // Not persisted — loaded lazily at runtime
    var dimensions: CGSize? = nil
    var exif: EXIFData? = nil

    /// Flat leaf names derived from `hierarchicalTags`. Used for substring search
    /// and the legacy "Tags" list in EXIFPanelView.
    var keywords: [String] { hierarchicalTags.map(\.displayName) }

    enum CodingKeys: String, CodingKey {
        case id, url, filename, fileSize, dateTaken, dateFromMetadata, isVideo, livePhotoVideoURL, hierarchicalTags, countryCode, enrichedFileDate, gpsLatitude, gpsLongitude, faceRegions
    }

    init(id: UUID, url: URL, filename: String, fileSize: Int64, dateTaken: Date?, dateFromMetadata: Bool = false, isVideo: Bool = false, livePhotoVideoURL: URL? = nil, hierarchicalTags: [HierarchicalTag] = [], countryCode: String? = nil, enrichedFileDate: Date? = nil, gpsLatitude: Double? = nil, gpsLongitude: Double? = nil, faceRegions: [FaceRegion] = [], locality: PhotoLocality = .local, sidecarStatus: SidecarStatus = .absent) {
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
        self.faceRegions = faceRegions
        self.locality = locality
        self.sidecarStatus = sidecarStatus
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
        faceRegions = try c.decodeIfPresent([FaceRegion].self, forKey: .faceRegions) ?? []
    }

    static func == (lhs: PhotoFile, rhs: PhotoFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Deterministic UUID derived from the file URL path for stable identity across scans.
    /// SHA-256 truncated to 16 bytes with RFC 4122 variant + version-5 marker — namespace-less; matches localmusic.
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
