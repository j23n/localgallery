import Foundation
import XCTest
@testable import LocalGallery

/// Sidecar path spelling and the Store's delete path: the photo, both
/// `.xmp` conventions, and a Live Photo pair all have to leave disk, and
/// the in-memory library has to drop them without waiting for a rescan.
@MainActor
final class PhotoDeleteTests: XCTestCase {

    private func makeHarness() -> TestGalleryStore.Harness {
        let inner = TestGalleryStore.make()
        addTeardownBlock { @MainActor in inner.teardown() }
        return inner
    }

    private func write(_ url: URL, _ body: String = "x") {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data(body.utf8))
    }

    // MARK: - Sidecar paths

    func testCanonicalSidecarAppendsXmp() {
        let photo = PhotoFile.fixture(url: URL(fileURLWithPath: "/a/IMG_1234.jpg"))
        XCTAssertEqual(photo.sidecarURL.path, "/a/IMG_1234.jpg.xmp")
        let heic = PhotoFile.fixture(url: URL(fileURLWithPath: "/a/IMG_1234.heic"))
        XCTAssertEqual(heic.sidecarURL.path, "/a/IMG_1234.heic.xmp")
    }

    func testAltSidecarReplacesTheSuffix() {
        let photo = PhotoFile.fixture(url: URL(fileURLWithPath: "/a/IMG_1234.jpg"))
        XCTAssertEqual(photo.altSidecarURL?.path, "/a/IMG_1234.xmp")
    }

    func testAltSidecarIsNilWhenThereIsNothingToReplace() {
        XCTAssertNil(PhotoFile.fixture(url: URL(fileURLWithPath: "/a/IMG_1234")).altSidecarURL)
        XCTAssertNil(PhotoFile.fixture(url: URL(fileURLWithPath: "/a/IMG_1234.xmp")).altSidecarURL)
        XCTAssertNil(PhotoFile.fixture(url: URL(fileURLWithPath: "/a/.hidden")).altSidecarURL)
    }

    func testOnDiskURLsIncludeLivePhotoPairAndSidecars() {
        let jpg = URL(fileURLWithPath: "/lib/IMG.jpg")
        let mov = URL(fileURLWithPath: "/lib/IMG.mov")
        let photo = PhotoFile.fixture(url: jpg, livePhotoVideoURL: mov)
        let paths = Set(photo.onDiskURLs.map(\.path))
        XCTAssertEqual(paths, [
            "/lib/IMG.jpg",
            "/lib/IMG.jpg.xmp",
            "/lib/IMG.xmp",
            "/lib/IMG.mov",
            "/lib/IMG.mov.xmp",
        ])
    }

    // MARK: - Prompt

    func testPromptNamesASinglePhoto() {
        let photo = PhotoFile.fixture()
        XCTAssertEqual(PhotoDeletePrompt.title(for: [photo]), "Delete Photo?")
        XCTAssertTrue(PhotoDeletePrompt.message(for: [photo]).contains("sidecar"))
    }

    func testPromptNamesSeveralPhotos() {
        let photos = [
            PhotoFile.fixture(url: URL(fileURLWithPath: "/a/1.jpg")),
            PhotoFile.fixture(url: URL(fileURLWithPath: "/a/2.jpg")),
        ]
        XCTAssertEqual(PhotoDeletePrompt.title(for: photos), "Delete 2 Photos?")
    }

    func testPromptNamesAVideo() {
        let video = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/a/clip.mov"),
            isVideo: true
        )
        XCTAssertEqual(PhotoDeletePrompt.title(for: [video]), "Delete Video?")
    }

    // MARK: - Disk + library

    func testDeleteRemovesThePhotoAndBothSidecarSpellings() async {
        let h = makeHarness()
        let jpg = h.tempDir.appending("shot.jpg")
        write(jpg)
        write(URL(fileURLWithPath: jpg.path + ".xmp"))
        write(jpg.deletingPathExtension().appendingPathExtension("xmp"))
        let photo = PhotoFile.fixture(url: jpg)
        let folder = PhotoFolder.fixture(url: h.tempDir.url, photos: [photo])
        h.store.apply(.scanResult(photos: [photo], root: folder, persistCache: false))

        let result = await h.store.deletePhotos([photo])

        XCTAssertEqual(result.deletedIDs, [photo.id])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(h.store.allPhotos.isEmpty)
        XCTAssertEqual(h.store.libraryAvailability, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path + ".xmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.deletingPathExtension().appendingPathExtension("xmp").path))
    }

    func testAMissingSidecarIsNotAFailure() async {
        let h = makeHarness()
        let jpg = h.tempDir.appending("alone.jpg")
        write(jpg)
        let photo = PhotoFile.fixture(url: jpg)
        h.store.apply(.scanResult(
            photos: [photo],
            root: PhotoFolder.fixture(url: h.tempDir.url, photos: [photo]),
            persistCache: false
        ))

        let result = await h.store.deletePhotos([photo])

        XCTAssertEqual(result.deletedIDs, [photo.id])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path))
    }

    func testDeleteRemovesALivePhotoPair() async {
        let h = makeHarness()
        let jpg = h.tempDir.appending("live.jpg")
        let mov = h.tempDir.appending("live.mov")
        write(jpg)
        write(mov)
        write(URL(fileURLWithPath: jpg.path + ".xmp"))
        write(URL(fileURLWithPath: mov.path + ".xmp"))
        let photo = PhotoFile.fixture(url: jpg, livePhotoVideoURL: mov)
        h.store.apply(.scanResult(
            photos: [photo],
            root: PhotoFolder.fixture(url: h.tempDir.url, photos: [photo]),
            persistCache: false
        ))

        let result = await h.store.deletePhotos([photo])

        XCTAssertEqual(result.deletedIDs, [photo.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mov.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path + ".xmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mov.path + ".xmp"))
    }

    func testDeleteUpdatesTheFolderTreeAndLeavesTheSibling() async {
        let h = makeHarness()
        let keepURL = h.tempDir.appending("keep.jpg")
        let dropURL = h.tempDir.appending("drop.jpg")
        write(keepURL)
        write(dropURL)
        let keep = PhotoFile.fixture(url: keepURL)
        let drop = PhotoFile.fixture(url: dropURL)
        let folder = PhotoFolder.fixture(
            url: h.tempDir.url,
            photos: [keep, drop],
            coverPhotoURL: drop.url
        )
        h.store.apply(.scanResult(photos: [keep, drop], root: folder, persistCache: false))

        _ = await h.store.deletePhotos([drop])

        XCTAssertEqual(h.store.allPhotos.map(\.id), [keep.id])
        XCTAssertEqual(h.store.rootFolder?.photos.map(\.id), [keep.id])
        XCTAssertEqual(h.store.rootFolder?.totalPhotoCount, 1)
        XCTAssertEqual(h.store.rootFolder?.coverPhotoURL, keep.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepURL.path))
    }

    func testAnAlreadyGonePhotoIsDroppedFromTheLibrary() async {
        let h = makeHarness()
        let jpg = h.tempDir.appending("ghost.jpg")
        let photo = PhotoFile.fixture(url: jpg)
        h.store.apply(.scanResult(
            photos: [photo],
            root: PhotoFolder.fixture(url: h.tempDir.url, photos: [photo]),
            persistCache: false
        ))

        let result = await h.store.deletePhotos([photo])

        XCTAssertEqual(result.deletedIDs, [photo.id])
        XCTAssertTrue(h.store.allPhotos.isEmpty)
    }

    func testRemovingPhotosFromANestedFolderRecomputesCounts() {
        let leafPhoto = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/2024/a.jpg"))
        let other = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/2024/b.jpg"))
        let leaf = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/lib/2024"),
            photos: [leafPhoto, other]
        )
        let root = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/lib"),
            subfolders: [leaf]
        )

        let trimmed = root.removingPhotos([leafPhoto.id])
        XCTAssertEqual(trimmed.totalPhotoCount, 1)
        XCTAssertEqual(trimmed.subfolders.first?.photos.map(\.id), [other.id])
        XCTAssertEqual(trimmed.subfolders.first?.totalPhotoCount, 1)
    }
}
