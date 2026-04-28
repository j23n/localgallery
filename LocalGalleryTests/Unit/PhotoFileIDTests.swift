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
}
