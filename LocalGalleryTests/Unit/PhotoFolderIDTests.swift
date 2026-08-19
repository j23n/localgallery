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

    func testFolderWithIDFindsNestedChildAndReturnsNilForUnknown() {
        let nested = PhotoFolder.fixture(url: URL(fileURLWithPath: "/library/2024/Italy"))
        let year = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/2024"),
            subfolders: [nested]
        )
        let root = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library"),
            subfolders: [year]
        )

        XCTAssertEqual(root.folder(withID: nested.id)?.url, nested.url)
        XCTAssertEqual(root.folder(withID: root.id)?.url, root.url)
        XCTAssertNil(root.folder(withID: UUID()))
    }

    func testFolderWithIDOnCopiedTreeSeesReplacedChildPhotos() {
        // Drill-in screens re-resolve by id against whatever root the Store
        // currently holds. A copied tree with a replaced child must surface
        // the new photos — otherwise a rescan that drops files would leave
        // the pushed screen looking at the NavigationLink snapshot.
        let original = PhotoFile.fixture(url: URL(fileURLWithPath: "/library/Trip/a.jpg"))
        let replacement = PhotoFile.fixture(url: URL(fileURLWithPath: "/library/Trip/b.jpg"))
        let leaf = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/Trip"),
            photos: [original]
        )
        let mid = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/2024"),
            subfolders: [leaf]
        )
        let root = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library"),
            subfolders: [mid]
        )

        var updatedLeaf = leaf
        updatedLeaf.photos = [replacement]
        var updatedMid = mid
        updatedMid.subfolders = [updatedLeaf]
        var updatedRoot = root
        updatedRoot.subfolders = [updatedMid]

        XCTAssertEqual(
            root.folder(withID: leaf.id)?.photos.map(\.url),
            [original.url]
        )
        XCTAssertEqual(
            updatedRoot.folder(withID: leaf.id)?.photos.map(\.url),
            [replacement.url]
        )
    }

    func testDirectoryURLsIncludesNestedFoldersNotPhotoFiles() {
        let photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/library/2024/Italy/duomo.jpg")
        )
        let italy = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/2024/Italy"),
            photos: [photo]
        )
        let year = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/2024"),
            subfolders: [italy]
        )
        let root = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library"),
            subfolders: [year]
        )

        let urls = Set(root.directoryURLs())
        XCTAssertEqual(urls, [root.url, year.url, italy.url])
        XCTAssertFalse(urls.contains(photo.url))
    }
}
