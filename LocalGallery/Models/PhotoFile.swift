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

    /// True for `.remote(downloaded: false)` — i.e., a provider-backed file
    /// whose bytes haven't been materialised. Maps to the QuickLook thumbnail
    /// path and the remote badge in the UI. Cheaper than calling
    /// `FileProviderDetector.probe(url)` per cell — that's a filesystem
    /// syscall and stutters scrolling on large grids.
    var isRemotePlaceholder: Bool {
        if case .remote(downloaded: false) = self { return true }
        return false
    }
}

/// Whether we have a parsed copy of the photo's `.xmp` sidecar in
/// `SidecarCacheStore`. Search/tag features only consider `.cached(_)` photos.
enum SidecarStatus: Codable, Hashable, Sendable {
    case absent
    case cached(FileProviderDetector.ContentVersion)
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
    /// File modDate as of the most recent scan. Light scan compares this +
    /// `fileSize` against the live filesystem listing to decide whether a
    /// cached entry can be reused without re-probing the file provider or
    /// re-reading EXIF. Distinct from `enrichedFileDate`, which only changes
    /// when the enrichment pass succeeds.
    var fileModificationDate: Date? = nil
    var gpsLatitude: Double? = nil
    var gpsLongitude: Double? = nil
    /// MWG `mwg-rs:RegionInfo` entries — one per detected face. Empty when the
    /// source XMP carries none. Used by the People rail to crop thumbnails to
    /// the matching face.
    var faceRegions: [FaceRegion] = []
    /// Pack / timestamps from the last sidecar apply.
    var photoTools: PhotoToolsMetadata = PhotoToolsMetadata()
    /// `CoreFaceDecisions` strings from the sidecar (named-below-floor, etc.).
    var faceDecisions: [String] = []
    /// A `.xmp` exists next to the image (appended or Lightroom alt).
    /// Distinct from `sidecarStatus`, which is the provider fetch cache.
    var sidecarOnDisk: Bool = false
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

    /// Flat leaf names derived from `hierarchicalTags`. Used for substring search.
    var keywords: [String] { hierarchicalTags.map(\.displayName) }

    /// `People/*` keywords on the file, whether or not a face was detected.
    var peopleTags: [HierarchicalTag] {
        hierarchicalTags.filter { $0.namespace?.lowercased() == "people" }
    }

    /// `Places/*` keywords on the file. After a library rescan these are
    /// the sidecar names already on the row — Scan uses them to skip
    /// photos that are already place-tagged, without another sidecar walk.
    var placeTags: [HierarchicalTag] {
        hierarchicalTags.filter { $0.namespace?.lowercased() == "places" }
    }

    /// People keywords that have no matching named MWG region — a name on
    /// the file that this pack never boxed.
    var peopleTagsWithoutFace: [HierarchicalTag] {
        let detected = Set(faceRegions.compactMap { $0.name?.lowercased() })
        return peopleTags.filter { !detected.contains($0.displayName.lowercased()) }
    }

    enum CodingKeys: String, CodingKey {
        case id, url, filename, fileSize, dateTaken, dateFromMetadata, isVideo, livePhotoVideoURL, hierarchicalTags, countryCode, enrichedFileDate, fileModificationDate, gpsLatitude, gpsLongitude, faceRegions, photoTools, faceDecisions, sidecarOnDisk
    }

    init(id: UUID, url: URL, filename: String, fileSize: Int64, dateTaken: Date?, dateFromMetadata: Bool = false, isVideo: Bool = false, livePhotoVideoURL: URL? = nil, hierarchicalTags: [HierarchicalTag] = [], countryCode: String? = nil, enrichedFileDate: Date? = nil, fileModificationDate: Date? = nil, gpsLatitude: Double? = nil, gpsLongitude: Double? = nil, faceRegions: [FaceRegion] = [], photoTools: PhotoToolsMetadata = PhotoToolsMetadata(), faceDecisions: [String] = [], sidecarOnDisk: Bool = false, locality: PhotoLocality = .local, sidecarStatus: SidecarStatus = .absent, dimensions: CGSize? = nil, exif: EXIFData? = nil) {
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
        self.fileModificationDate = fileModificationDate
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.faceRegions = faceRegions
        self.photoTools = photoTools
        self.faceDecisions = faceDecisions
        self.sidecarOnDisk = sidecarOnDisk
        self.locality = locality
        self.sidecarStatus = sidecarStatus
        self.dimensions = dimensions
        self.exif = exif
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
        fileModificationDate = try c.decodeIfPresent(Date.self, forKey: .fileModificationDate)
        gpsLatitude = try c.decodeIfPresent(Double.self, forKey: .gpsLatitude)
        gpsLongitude = try c.decodeIfPresent(Double.self, forKey: .gpsLongitude)
        faceRegions = try c.decodeIfPresent([FaceRegion].self, forKey: .faceRegions) ?? []
        photoTools = try c.decodeIfPresent(PhotoToolsMetadata.self, forKey: .photoTools) ?? PhotoToolsMetadata()
        faceDecisions = try c.decodeIfPresent([String].self, forKey: .faceDecisions) ?? []
        sidecarOnDisk = try c.decodeIfPresent(Bool.self, forKey: .sidecarOnDisk) ?? false
    }

    static func == (lhs: PhotoFile, rhs: PhotoFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Deterministic UUID derived from the file URL path for stable identity across scans.
    static func stableID(for url: URL) -> UUID {
        StableUUID.derive(from: url.standardized.path)
    }

    /// Canonical sidecar (`IMG.jpg.xmp`). Matches `gallery_meta::sidecar_path`.
    var sidecarURL: URL {
        Self.canonicalSidecarURL(for: url)
    }

    /// Lightroom-style sidecar (`IMG.xmp`). Matches `gallery_meta::alt_sidecar_path`.
    /// `nil` when there is no extension to replace (or the file already is `.xmp`).
    var altSidecarURL: URL? {
        Self.altSidecarURL(for: url)
    }

    /// Every on-disk file that belongs to this photo: the image/video, both
    /// sidecar spellings, and a Live Photo's paired movie (plus that movie's
    /// sidecars). Missing companions are skipped at delete time.
    var onDiskURLs: [URL] {
        var urls = [url, sidecarURL]
        if let alt = altSidecarURL { urls.append(alt) }
        if let live = livePhotoVideoURL {
            urls.append(live)
            urls.append(Self.canonicalSidecarURL(for: live))
            if let alt = Self.altSidecarURL(for: live) { urls.append(alt) }
        }
        return urls
    }

    static func canonicalSidecarURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".xmp")
    }

    /// Same photo after an on-disk move. Identity follows the new URL
    /// (`stableID`), which is what a later scan would derive. Every
    /// non-path field — persisted metadata and runtime-only state — is
    /// copied so a move cannot drop tags, tools, locality, or a lazy EXIF
    /// load the viewer already paid for.
    func relocated(to url: URL, livePhotoVideoURL: URL? = nil) -> PhotoFile {
        PhotoFile(
            id: PhotoFile.stableID(for: url),
            url: url,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            dateTaken: dateTaken,
            dateFromMetadata: dateFromMetadata,
            isVideo: isVideo,
            livePhotoVideoURL: livePhotoVideoURL,
            hierarchicalTags: hierarchicalTags,
            countryCode: countryCode,
            enrichedFileDate: enrichedFileDate,
            fileModificationDate: fileModificationDate,
            gpsLatitude: gpsLatitude,
            gpsLongitude: gpsLongitude,
            faceRegions: faceRegions,
            photoTools: photoTools,
            faceDecisions: faceDecisions,
            sidecarOnDisk: sidecarOnDisk,
            locality: locality,
            sidecarStatus: sidecarStatus,
            dimensions: dimensions,
            exif: exif
        )
    }

    static func altSidecarURL(for url: URL) -> URL? {
        let filename = url.lastPathComponent
        guard let dot = filename.lastIndex(of: ".") else { return nil }
        if dot == filename.startIndex { return nil }
        let ext = filename[dot...]
        if ext.lowercased() == ".xmp" { return nil }
        let stem = filename[..<dot]
        return url.deletingLastPathComponent()
            .appendingPathComponent(String(stem) + ".xmp")
    }
}

/// SHA-256-truncated deterministic UUID with RFC 4122 variant + version-5 marker.
/// Namespace-less; matches localmusic. Used by `PhotoFile` and `PhotoFolder` so
/// the grid doesn't flicker on rescan.
enum StableUUID {
    static func derive(from input: String) -> UUID {
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant RFC 4122
        return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                           bytes[4],  bytes[5],  bytes[6],  bytes[7],
                           bytes[8],  bytes[9],  bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
