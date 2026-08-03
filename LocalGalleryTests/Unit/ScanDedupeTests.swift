import Foundation
import XCTest
@testable import LocalGallery

/// `GalleryStore.scanFolder`'s dedupe rules.
///
/// Concurrent callers for the same root share one traversal — app launch,
/// `willEnterForeground` and pull-to-refresh routinely overlap — but sharing is
/// only correct when the in-flight pass can actually answer the new request.
/// Two ways it cannot: it is *weaker* (a light scan cannot satisfy "Reload
/// Library"), or it is *earlier* (it walked the tree before the files the new
/// request is about existed). The second is what silently dropped a tagging
/// run's freshly written sidecars.
@MainActor
final class ScanDedupeTests: XCTestCase {
    /// A fixed clock makes "did this pass start before the request?" an exact
    /// comparison instead of a race against wall time.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private struct Harness {
        let store: GalleryStore
        let root: URL
    }

    private func makeHarness() -> Harness {
        let inner = TestGalleryStore.make(clock: FixedClock(date: now))
        addTeardownBlock { @MainActor in inner.teardown() }

        let root = inner.tempDir.appending("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // One real file, so a scan that runs has something to publish and a
        // scan that was skipped is visibly different from one that ran.
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("photo.jpg").path,
            contents: Data(repeating: 0xFF, count: 32)
        )
        return Harness(store: inner.store, root: root)
    }

    /// Stand in for a scan already in flight, started at `startedAt`.
    private func stageInFlightScan(_ h: Harness, kind: ScanKind, startedAt: Date) {
        let task = Task<Void, Never> { @MainActor in }
        h.store.activeScanTask = (h.root, kind, startedAt, task)
    }

    /// The bug: a `.light` request coalesced onto a `.light` pass that began
    /// before it. A tagging run's sidecars are written *after* that pass listed
    /// the tree, so its manifest could not contain them — and nothing looked
    /// again.
    func testARequestIsNotSatisfiedByAPassThatBeganBeforeIt() async {
        let h = makeHarness()
        stageInFlightScan(h, kind: .light, startedAt: now.addingTimeInterval(-5))

        await h.store.scanFolder(at: h.root, kind: .light)

        XCTAssertEqual(
            h.store.allPhotos.count, 1,
            "the request was answered by a pass that could not have seen the new files"
        )
        XCTAssertNil(h.store.activeScanTask, "the finished scan was not cleared")
    }

    /// The coalescing that should still happen: a pass that started *after*
    /// the request necessarily saw everything the request is about.
    func testARequestIsSatisfiedByAPassThatBeganAfterIt() async {
        let h = makeHarness()
        stageInFlightScan(h, kind: .light, startedAt: now.addingTimeInterval(5))

        await h.store.scanFolder(at: h.root, kind: .light)

        XCTAssertTrue(
            h.store.allPhotos.isEmpty,
            "a request a newer in-flight pass already covers started a redundant scan"
        )
    }

    /// The pre-existing rule, still in force: a `.full` request must not be
    /// downgraded by an in-flight light scan, even a newer one.
    func testAFullRequestIsNotSatisfiedByANewerLightPass() async {
        let h = makeHarness()
        stageInFlightScan(h, kind: .light, startedAt: now.addingTimeInterval(5))

        await h.store.scanFolder(at: h.root, kind: .full)

        XCTAssertEqual(h.store.allPhotos.count, 1)
        XCTAssertEqual(
            h.store.lastFullScanAt, now,
            "the re-run did not actually perform a full pass"
        )
    }

    /// The re-run carries the *original* request time, so the recursion is one
    /// extra pass rather than a chase after a moving target. With a fixed
    /// clock, a re-run that re-stamped `requestedAt` would see its own
    /// freshly-started pass as "not newer than the request" and go round
    /// again — so this test returning at all is the assertion.
    func testTheReRunIsBoundedToASinglePass() async {
        let h = makeHarness()
        stageInFlightScan(h, kind: .light, startedAt: now.addingTimeInterval(-5))

        await h.store.scanFolder(at: h.root, kind: .light)

        XCTAssertEqual(h.store.allPhotos.count, 1)
    }
}
