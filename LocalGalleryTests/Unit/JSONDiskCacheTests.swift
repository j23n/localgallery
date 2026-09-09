import XCTest
@testable import LocalGallery

/// Persistence races: a save that is already past its cancel check must
/// not recreate a file `clear()` just removed, and a later save must
/// still be able to write a fresh snapshot.
@MainActor
final class JSONDiskCacheTests: XCTestCase {

    private func makeCache(
        debounce: Duration = .zero
    ) -> (JSONDiskCache<[String]>, URL, TempDir) {
        let tmp = TempDir.make()
        addTeardownBlock { tmp.teardown() }
        let url = tmp.appending("cache.json")
        let cache = JSONDiskCache<[String]>(
            url: url, version: 1, label: "test cache", debounce: debounce
        )
        return (cache, url, tmp)
    }

    func testClearRemovesAPersistedSnapshot() async {
        let (cache, url, _) = makeCache()
        cache.save(["keep"])
        await cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        cache.clear()
        await cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(cache.load())
    }

    func testClearInvalidatesAnInFlightSave() async {
        let (cache, url, _) = makeCache()
        cache.save(["stale"])
        cache.clear()
        await cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a late write must not resurrect a cleared cache")
        XCTAssertNil(cache.load())
    }

    func testClearInvalidatesADebouncedSave() async {
        let (cache, url, _) = makeCache(debounce: .milliseconds(80))
        cache.save(["stale"])
        cache.clear()
        await cache.flush()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(cache.load())
    }

    func testSaveAfterClearWritesAFreshSnapshot() async {
        let (cache, _, _) = makeCache()
        cache.save(["old"])
        await cache.flush()
        cache.clear()
        cache.save(["new"])
        await cache.flush()
        XCTAssertEqual(cache.load(), ["new"])
    }
}
