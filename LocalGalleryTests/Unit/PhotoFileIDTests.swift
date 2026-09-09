import XCTest
@testable import LocalGallery

final class PhotoFileIDTests: XCTestCase {

    func testStableIDIsDeterministicForSameURL() {
        let url = URL(fileURLWithPath: "/Volumes/Library/2024/IMG_0001.jpg")
        XCTAssertEqual(PhotoFile.stableID(for: url), PhotoFile.stableID(for: url))
    }

    func testStableIDDiffersAcrossURLs() {
        let a = URL(fileURLWithPath: "/Volumes/Library/2024/IMG_0001.jpg")
        let b = URL(fileURLWithPath: "/Volumes/Library/2024/IMG_0002.jpg")
        XCTAssertNotEqual(PhotoFile.stableID(for: a), PhotoFile.stableID(for: b))
    }

    func testStableIDIsURLPathBased() {
        // file:// URL pointing at the same standardized path should yield the
        // same id regardless of how the URL was constructed.
        let direct = URL(fileURLWithPath: "/tmp/photos/a.jpg")
        let viaComponents = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("photos")
            .appendingPathComponent("a.jpg")
        XCTAssertEqual(PhotoFile.stableID(for: direct), PhotoFile.stableID(for: viaComponents))
    }

    func testTrailingSlashIsNormalized() {
        // `/tmp/photos/` and `/tmp/photos` standardize to the same path —
        // important so a folder/file mix-up between scans doesn't change ids.
        let withSlash = URL(fileURLWithPath: "/tmp/photos/file/")
        let withoutSlash = URL(fileURLWithPath: "/tmp/photos/file")
        XCTAssertEqual(PhotoFile.stableID(for: withSlash), PhotoFile.stableID(for: withoutSlash))
    }

    func testIDIsIdempotentAcrossRescans() {
        // Drives the production "grid doesn't flicker on rescan" guarantee:
        // two synthesized PhotoFiles for the same URL must compare equal.
        let url = URL(fileURLWithPath: "/library/A/IMG_0001.jpg")
        let a = PhotoFile.fixture(url: url, dateTaken: Date())
        let b = PhotoFile.fixture(url: url, dateTaken: Date(timeIntervalSinceNow: 100))
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a, b) // PhotoFile equality is id-based
    }

    func testStableIDIsAValidVersion5UUID() {
        // The implementation stamps RFC 4122 variant + version 5 onto the
        // SHA-256 prefix (matching localmusic). Lock the markers so a future
        // refactor doesn't silently change them.
        let id = PhotoFile.stableID(for: URL(fileURLWithPath: "/library/x.jpg"))
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] & 0xF0, 0x50, "version-5 nibble must be 5")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "RFC 4122 variant must be 10xx")
    }

    func testRelocatedCopiesEveryNonPathField() {
        let src = URL(fileURLWithPath: "/lib/inbox/shot.jpg")
        let dest = URL(fileURLWithPath: "/lib/italy/shot.jpg")
        let live = URL(fileURLWithPath: "/lib/italy/shot.mov")
        var photo = PhotoFile.fixture(
            url: src,
            fileSize: 4096,
            dateTaken: date(2019, 6, 11),
            dateFromMetadata: true,
            tags: ["People/Ada", "Places/Italy"],
            countryCode: "IT",
            gps: (41.9, 12.5)
        )
        photo.enrichedFileDate = date(2024, 1, 2)
        photo.fileModificationDate = date(2024, 1, 3)
        photo.faceRegions = [FaceRegion(name: "Ada", centerX: 0.4, centerY: 0.5, width: 0.2, height: 0.3)]
        photo.photoTools = PhotoToolsMetadata(facePack: "buffalo_sc-2026.1", faceTaggedAt: "2026-01-01T00:00:00Z")
        photo.faceDecisions = ["named-below-floor"]
        photo.sidecarOnDisk = true
        photo.locality = .remote(downloaded: true)
        photo.sidecarStatus = .cached(FileProviderDetector.ContentVersion(
            contentIdentifier: "cid", modificationDate: date(2024, 2, 1), size: 12
        ))
        photo.dimensions = CGSize(width: 4032, height: 3024)
        photo.exif = EXIFData(cameraMake: "Leica", cameraModel: "Q2", lens: nil, aperture: 1.7, shutterSpeed: 0.01, iso: 200, gpsLatitude: 41.9, gpsLongitude: 12.5, dateTimeOriginal: date(2019, 6, 11), pixelWidth: 4032, pixelHeight: 3024)

        let moved = photo.relocated(to: dest, livePhotoVideoURL: live)

        XCTAssertEqual(moved.id, PhotoFile.stableID(for: dest))
        XCTAssertNotEqual(moved.id, photo.id)
        XCTAssertEqual(moved.url, dest)
        XCTAssertEqual(moved.filename, "shot.jpg")
        XCTAssertEqual(moved.livePhotoVideoURL, live)
        XCTAssertEqual(moved.fileSize, photo.fileSize)
        XCTAssertEqual(moved.dateTaken, photo.dateTaken)
        XCTAssertEqual(moved.dateFromMetadata, photo.dateFromMetadata)
        XCTAssertEqual(moved.hierarchicalTags, photo.hierarchicalTags)
        XCTAssertEqual(moved.countryCode, photo.countryCode)
        XCTAssertEqual(moved.enrichedFileDate, photo.enrichedFileDate)
        XCTAssertEqual(moved.fileModificationDate, photo.fileModificationDate)
        XCTAssertEqual(moved.gpsLatitude, photo.gpsLatitude)
        XCTAssertEqual(moved.gpsLongitude, photo.gpsLongitude)
        XCTAssertEqual(moved.faceRegions, photo.faceRegions)
        XCTAssertEqual(moved.photoTools, photo.photoTools)
        XCTAssertEqual(moved.faceDecisions, photo.faceDecisions)
        XCTAssertEqual(moved.sidecarOnDisk, photo.sidecarOnDisk)
        XCTAssertEqual(moved.locality, photo.locality)
        XCTAssertEqual(moved.sidecarStatus, photo.sidecarStatus)
        XCTAssertEqual(moved.dimensions, photo.dimensions)
        XCTAssertEqual(moved.exif, photo.exif)
    }
}
