import XCTest
@testable import LocalGallery

/// Locality / download / sidecar-cache mutations must land on `allPhotos`,
/// the index object table, and the folder tree together — a grid cell
/// reading `store.photo(byID:)` cannot keep showing a remote badge after
/// `ensureMaterialized` marked the row downloaded.
@MainActor
final class GalleryStoreRuntimeStateTests: XCTestCase {

    private func makeHarness() -> TestGalleryStore.Harness {
        let inner = TestGalleryStore.make()
        addTeardownBlock { @MainActor in inner.teardown() }
        return inner
    }

    private func seededRemotePhoto(_ h: TestGalleryStore.Harness) -> PhotoFile {
        var photo = PhotoFile.fixture(url: h.tempDir.appending("cloud.jpg"))
        photo.locality = .remote(downloaded: false)
        photo.sidecarStatus = .cached(FileProviderDetector.ContentVersion(
            contentIdentifier: "v1", modificationDate: nil, size: 8
        ))
        let folder = PhotoFolder.fixture(url: h.tempDir.url, photos: [photo])
        h.store.apply(.scanResult(photos: [photo], root: folder, persistCache: false))
        return photo
    }

    func testLocalityChangeUpdatesStoreIndexAndTree() {
        let h = makeHarness()
        let photo = seededRemotePhoto(h)

        h.store.apply(.photoLocalityChanged(id: photo.id, locality: .remote(downloaded: true)))

        XCTAssertEqual(h.store.allPhotos.first?.locality, .remote(downloaded: true))
        XCTAssertEqual(h.store.photo(byID: photo.id)?.locality, .remote(downloaded: true))
        XCTAssertEqual(h.store.rootFolder?.photos.first?.locality, .remote(downloaded: true))
    }

    func testClearingDownloadsResetsIndexAndTree() {
        let h = makeHarness()
        let photo = seededRemotePhoto(h)
        h.store.apply(.photoLocalityChanged(id: photo.id, locality: .remote(downloaded: true)))

        h.store.apply(.allDownloadsCleared)

        XCTAssertEqual(h.store.allPhotos.first?.locality, .remote(downloaded: false))
        XCTAssertEqual(h.store.photo(byID: photo.id)?.locality, .remote(downloaded: false))
        XCTAssertEqual(h.store.rootFolder?.photos.first?.locality, .remote(downloaded: false))
    }

    func testLocalityChangeUpdatesANestedFolderRow() {
        let h = makeHarness()
        var photo = PhotoFile.fixture(url: h.tempDir.appending("2024", isDirectory: true).appendingPathComponent("cloud.jpg"))
        photo.locality = .remote(downloaded: false)
        let leaf = PhotoFolder.fixture(url: h.tempDir.appending("2024", isDirectory: true), photos: [photo])
        let root = PhotoFolder.fixture(url: h.tempDir.url, subfolders: [leaf])
        h.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        h.store.apply(.photoLocalityChanged(id: photo.id, locality: .remote(downloaded: true)))

        XCTAssertEqual(h.store.rootFolder?.subfolders.first?.photos.first?.locality, .remote(downloaded: true))
        XCTAssertEqual(h.store.photo(byID: photo.id)?.locality, .remote(downloaded: true))
    }

    func testClearingSidecarCacheResetsIndexAndTree() {
        let h = makeHarness()
        let photo = seededRemotePhoto(h)
        XCTAssertEqual(h.store.photo(byID: photo.id)?.sidecarStatus, photo.sidecarStatus)

        h.store.apply(.sidecarCacheCleared)

        XCTAssertEqual(h.store.allPhotos.first?.sidecarStatus, .absent)
        XCTAssertEqual(h.store.photo(byID: photo.id)?.sidecarStatus, .absent)
        XCTAssertEqual(h.store.rootFolder?.photos.first?.sidecarStatus, .absent)
    }
}
