import XCTest
@testable import LocalGallery

final class PhotoFolderIDTests: XCTestCase {

    func testFolderIDIsDeterministic() {
        let url = URL(fileURLWithPath: "/Volumes/Library/2024")
        XCTAssertEqual(PhotoFolder.stableID(for: url), PhotoFolder.stableID(for: url))
    }

    func testFolderIDDiffersAcrossURLs() {
        let a = URL(fileURLWithPath: "/Volumes/Library/2024")
        let b = URL(fileURLWithPath: "/Volumes/Library/2025")
        XCTAssertNotEqual(PhotoFolder.stableID(for: a), PhotoFolder.stableID(for: b))
    }

    func testFolderIDDoesNotCollideWithPhotoIDForSameURL() {
        // Both stableID functions hash the same URL but the folder side
        // prefixes with `folder:` so the hash spaces don't overlap.
        let url = URL(fileURLWithPath: "/library/Trip/2024")
        XCTAssertNotEqual(
            PhotoFolder.stableID(for: url),
            PhotoFile.stableID(for: url),
            "folder ids must not collide with photo ids — drives selection routing"
        )
    }
}
