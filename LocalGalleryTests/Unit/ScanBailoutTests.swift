import Foundation
import XCTest
@testable import LocalGallery

/// What the Store does with a scan pass that produced no answer.
///
/// The scanner has exactly two ways to come back empty and they mean opposite
/// things:
///
/// * **"I walked the library and it is empty."** Publish it — the user really
///   did delete everything.
/// * **"I never finished."** Cancelled, or the core threw. Publishing that
///   assigns `[]` to `allPhotos`, `nil` to `rootFolder` and `[]` to
///   `lastSidecarManifest`, then `saveCache()` writes all three to disk. One
///   cancelled scan and the library is gone until a full pass rebuilds it from
///   the filesystem — without the tags, GPS, faces and enrichment that only
///   existed in the cache.
///
/// The two have identical shapes, which is why `CoreScanner.Result` carries a
/// flag instead of leaving the Store to guess.
@MainActor
final class ScanBailoutTests: XCTestCase {

    private var temp: TempDir!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        temp = TempDir.make()
        defaults = TestUserDefaults.make()
    }

    override func tearDown() {
        TestUserDefaults.cleanup(defaults)
        defaults = nil
        temp?.teardown()
        temp = nil
        super.tearDown()
    }

    private func makeStore() -> GalleryStore {
        GalleryStore(
            paths: GalleryPaths(
                libraryCacheURL: temp.appending("library_cache.json"),
                memoriesCacheURL: temp.appending("memories_cache.json"),
                sidecarCacheURL: temp.appending("sidecar_cache.json"),
                thumbnailDir: temp.appending("thumbnails", isDirectory: true),
                mlCacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
                modelPacksDirectoryURL: temp.appending("ModelPacks", isDirectory: true),
                bookmarkKey: "rootFolderBookmark"
            ),
            defaults: defaults,
            clock: SystemClock(),
            contactsService: StubContactsService(contacts: [])
        )
    }

    /// A library on disk, plus a warm cache holding a photo that is *not* in
    /// it. The phantom is what makes the assertion sharp: if the pass ran to
    /// completion the cache would be replaced by the real file, so a surviving
    /// phantom can only mean the pass bailed.
    private func makeLibrary() throws -> URL {
        let root = temp.appending("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: root.appendingPathComponent("real.jpg"))
        return root
    }

    private func warmCache(_ store: GalleryStore, under root: URL) {
        let phantomURL = root.appendingPathComponent("only-in-the-cache.jpg")
        var phantom = PhotoFile.fixture(url: phantomURL, tags: ["Scenes/Beach"])
        phantom.enrichedFileDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let folder = PhotoFolder.fixture(url: root, name: "Library", photos: [phantom])
        store.apply(.scanResult(photos: [phantom], root: folder, persistCache: false))
        store.lastSidecarManifest = [
            SidecarCandidate(
                photoID: phantom.id,
                sidecarURL: phantomURL.appendingPathExtension("xmp"),
                currentVersion: FileProviderDetector.ContentVersion(size: 12),
                downloadStatus: .local
            )
        ]
    }

    /// The regression. A cancelled pass leaves every piece of published state
    /// exactly as it found it — photos, tree and manifest.
    func testACancelledPassLeavesTheCachedLibraryAlone() async throws {
        let root = try makeLibrary()
        let store = makeStore()
        warmCache(store, under: root)

        let before = store.allPhotos
        let manifestBefore = store.lastSidecarManifest
        let rootBefore = store.rootFolder

        let pass = Task { @MainActor () -> CoreScanner.Result in
            // Wait for the cancel before starting, so the test pins the
            // behaviour rather than racing the scheduler.
            while !Task.isCancelled { await Task.yield() }
            return await store.runScanPass(at: root, light: false, silent: true)
        }
        pass.cancel()
        let result = await pass.value

        XCTAssertTrue(result.didNotComplete, "the pass has to admit it produced nothing")
        XCTAssertEqual(store.allPhotos.map(\.url), before.map(\.url),
                       "a cancelled pass published over the cache")
        XCTAssertEqual(store.allPhotos.first?.hierarchicalTags.map(\.fullPath),
                       ["Scenes/Beach"], "…and took the cached tags with it")
        XCTAssertEqual(store.rootFolder, rootBefore, "the folder tree was replaced by nothing")
        XCTAssertEqual(store.lastSidecarManifest, manifestBefore,
                       "an empty manifest tells the sidecar sync every .xmp vanished")
    }

    /// …and a pass that *does* complete still publishes, so the guard is a
    /// guard and not a disconnection.
    func testACompletedPassStillPublishes() async throws {
        let root = try makeLibrary()
        let store = makeStore()
        warmCache(store, under: root)

        let result = await store.runScanPass(at: root, light: false, silent: true)

        XCTAssertFalse(result.didNotComplete)
        XCTAssertEqual(store.allPhotos.map(\.url.lastPathComponent), ["real.jpg"],
                       "the phantom should be gone: it is genuinely not on disk")
        XCTAssertEqual(result.removedURLs.map(\.lastPathComponent), ["only-in-the-cache.jpg"])
    }

    /// An unreadable *directory* is the opposite case: it is data, it comes
    /// back with the rest of the tree intact, and the Store carries the cached
    /// photos under it forward rather than reporting them removed.
    func testAnUnreadableSubdirectoryCarriesItsCachedPhotosForward() async throws {
        let root = try makeLibrary()
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let hidden = locked.appendingPathComponent("inside.jpg")
        try Data(repeating: 0x42, count: 6).write(to: hidden)

        let store = makeStore()
        // Seed the cache with the photo that is about to become invisible.
        let cached = PhotoFile.fixture(url: hidden, fileSize: 6, tags: ["People/Alice"])
        store.apply(.scanResult(photos: [cached], root: nil, persistCache: false))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: locked.path)
        }
        // Running as root ignores the mode bits; there is nothing to test then.
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: locked.path))

        let result = await store.runScanPass(at: root, light: false, silent: true)

        XCTAssertFalse(result.didNotComplete, "an unreadable directory is data, not a failure")
        XCTAssertFalse(result.failedDirectoryPaths.isEmpty)
        XCTAssertFalse(result.removedURLs.contains { $0.lastPathComponent == "inside.jpg" },
                       "a transient I/O error must not look like a deletion")
        XCTAssertTrue(store.allPhotos.contains { $0.url.lastPathComponent == "inside.jpg" },
                      "the cached photo under the unreadable directory was dropped")
        XCTAssertTrue(store.allPhotos.contains { $0.url.lastPathComponent == "real.jpg" },
                      "…and the rest of the library was still scanned")
    }
}
