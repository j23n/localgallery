import Foundation
@testable import LocalGallery

/// Builds a `GalleryStore` pointed at temp paths and an isolated
/// `UserDefaults` suite. Returns the dependencies alongside the store so
/// tests can clean them up in `tearDown()`.
@MainActor
enum TestGalleryStore {
    struct Harness {
        let store: GalleryStore
        let tempDir: TempDir
        let defaults: UserDefaults

        func teardown() {
            TestUserDefaults.cleanup(defaults)
            tempDir.teardown()
        }
    }

    static func make(
        clock: any Clock = SystemClock(),
        contacts: [ContactInfo] = []
    ) -> Harness {
        let tempDir = TempDir.make()
        let paths = GalleryPaths(
            libraryCacheURL: tempDir.appending("library_cache.json"),
            memoriesCacheURL: tempDir.appending("memories_cache.json"),
            sidecarCacheURL: tempDir.appending("sidecar_cache.json"),
            thumbnailDir: tempDir.appending("thumbnails", isDirectory: true),
            bookmarkKey: "rootFolderBookmark"
        )
        let defaults = TestUserDefaults.make()
        let store = GalleryStore(
            paths: paths,
            defaults: defaults,
            clock: clock,
            contactsService: StubContactsService(contacts: contacts)
        )
        return Harness(store: store, tempDir: tempDir, defaults: defaults)
    }
}
