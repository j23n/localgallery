import Foundation
import CoreGraphics
@testable import LocalGallery

// MARK: - PhotoFile

extension PhotoFile {
    /// Build a `PhotoFile` for unit tests with sensible defaults. Pass only the
    /// fields the test cares about; everything else is filled in deterministically
    /// so calls read like assertions ("a photo dated March, tagged Rome").
    ///
    /// `id` is derived from `url` via `PhotoFile.stableID(for:)` so the fixture
    /// matches what the production code would produce for the same path.
    static func fixture(
        url: URL = URL(fileURLWithPath: "/tmp/p.jpg"),
        filename: String? = nil,
        fileSize: Int64 = 1024,
        dateTaken: Date? = nil,
        dateFromMetadata: Bool = false,
        isVideo: Bool = false,
        livePhotoVideoURL: URL? = nil,
        tags: [String] = [],
        countryCode: String? = nil,
        gps: (lat: Double, lon: Double)? = nil
    ) -> PhotoFile {
        PhotoFile(
            id: PhotoFile.stableID(for: url),
            url: url,
            filename: filename ?? url.deletingPathExtension().lastPathComponent,
            fileSize: fileSize,
            dateTaken: dateTaken,
            dateFromMetadata: dateFromMetadata,
            isVideo: isVideo,
            livePhotoVideoURL: livePhotoVideoURL,
            hierarchicalTags: tags.map { HierarchicalTag(raw: $0) },
            countryCode: countryCode,
            gpsLatitude: gps?.lat,
            gpsLongitude: gps?.lon
        )
    }
}

// MARK: - PhotoFolder

extension PhotoFolder {
    static func fixture(
        url: URL = URL(fileURLWithPath: "/tmp/Folder"),
        name: String? = nil,
        subfolders: [PhotoFolder] = [],
        photos: [PhotoFile] = [],
        coverPhotoURL: URL? = nil,
        totalPhotoCount: Int? = nil,
        dateModified: Date? = nil,
        dateCreated: Date? = nil
    ) -> PhotoFolder {
        let recursiveCount = totalPhotoCount ?? (photos.count + subfolders.reduce(0) { $0 + $1.totalPhotoCount })
        return PhotoFolder(
            id: PhotoFolder.stableID(for: url),
            url: url,
            name: name ?? url.lastPathComponent,
            subfolders: subfolders,
            photos: photos,
            coverPhotoURL: coverPhotoURL ?? photos.first?.url,
            totalPhotoCount: recursiveCount,
            dateModified: dateModified,
            dateCreated: dateCreated
        )
    }
}

// MARK: - ContactInfo

extension ContactInfo {
    static func fixture(
        id: String = "contact-1",
        givenName: String = "Alice",
        familyName: String = "Anderson",
        birthday: DateComponents? = nil
    ) -> ContactInfo {
        ContactInfo(id: id, givenName: givenName, familyName: familyName, birthday: birthday)
    }
}

// MARK: - Date helpers

/// A small DSL for building deterministic `Date` values in tests.
/// `date(2024, 3, 15)` reads better than spelling `DateComponents` out.
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    )) ?? Date()
}
