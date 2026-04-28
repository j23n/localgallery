import XCTest
@testable import LocalGallery

/// Smoke test for the Phase 1 test infrastructure (`TestGalleryStore`,
/// `TempDir`, `TestUserDefaults`). If this test ever fails, every other
/// test in `Unit/` that uses the harness is going to fail in noisier ways.
@MainActor
final class HarnessSmokeTest: XCTestCase {

    func testHarnessBuildsStoreWithIsolatedDeps() {
        let harness = TestGalleryStore.make(
            clock: FixedClock(date: date(2024, 6, 1)),
            contacts: [.fixture(givenName: "Alice", familyName: "Anderson")]
        )
        defer { harness.teardown() }

        // The store is initialised with an empty library (no cache, no
        // bookmark) — the cleanest possible blank state for unit tests.
        XCTAssertTrue(harness.store.allPhotos.isEmpty)
        XCTAssertNil(harness.store.rootFolder)

        // The injected clock is reachable from inside the store (used by
        // the date-comparison codepaths).
        XCTAssertEqual(harness.store.clock.now(), date(2024, 6, 1))

        // The injected defaults round-trip a writable key. Writing to
        // `UserDefaults.standard` instead would leak between tests on shared
        // simulators — that's the whole point of the suite scope.
        harness.defaults.set(["A"], forKey: "hiddenPeople")
        XCTAssertEqual(harness.defaults.array(forKey: "hiddenPeople") as? [String], ["A"])
    }
}
