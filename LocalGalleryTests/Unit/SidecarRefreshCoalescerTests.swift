import Foundation
import XCTest
@testable import LocalGallery

/// The two rules `SidecarRefreshCoalescer` exists for, and the one instance
/// both core engines share.
///
/// Both services used to hold their own copy while their doc comments claimed
/// otherwise, which quietly doubled the rescan budget: a tagging run and a face
/// run each spent the 30 s window on their own.
@MainActor
final class SidecarRefreshCoalescerTests: XCTestCase {
    private func makeCoalescer(interval: TimeInterval = 30) -> SidecarRefreshCoalescer {
        SidecarRefreshCoalescer(interval: interval)
    }

    // MARK: - Rule 1: coalesce

    func testASecondNoteInsideTheIntervalIsSuppressed() async {
        let coalescer = makeCoalescer()
        var refreshes = 0
        coalescer.onRefresh = { refreshes += 1 }

        coalescer.note()
        await coalescer.task?.value
        XCTAssertEqual(refreshes, 1)

        coalescer.note()
        await coalescer.task?.value
        XCTAssertEqual(refreshes, 1, "a batch inside the window should coalesce away")
    }

    func testANoteAfterTheIntervalRefreshesAgain() async {
        let coalescer = makeCoalescer(interval: 0)
        var refreshes = 0
        coalescer.onRefresh = { refreshes += 1 }

        coalescer.note()
        await coalescer.task?.value
        coalescer.note()
        await coalescer.task?.value
        XCTAssertEqual(refreshes, 2)
    }

    /// `lastRefreshAt` records when a refresh *ran*. Advancing it on a
    /// suppressed batch let a steady drip of them push the window out forever,
    /// so partial results never appeared until the run ended.
    func testASuppressedNoteDoesNotPushTheWindowOut() async {
        let coalescer = makeCoalescer()
        coalescer.onRefresh = { }

        coalescer.note()
        await coalescer.task?.value
        let first = try? XCTUnwrap(coalescer.lastRefreshAt)

        coalescer.note()
        coalescer.note()
        await coalescer.task?.value
        XCTAssertEqual(coalescer.lastRefreshAt, first, "a suppressed batch moved the window")
    }

    func testScheduleIgnoresTheIntervalEntirely() async {
        let coalescer = makeCoalescer()
        var refreshes = 0
        coalescer.onRefresh = { refreshes += 1 }

        coalescer.schedule()
        await coalescer.task?.value
        coalescer.schedule()
        await coalescer.task?.value
        XCTAssertEqual(refreshes, 2, "the end-of-run refresh must never be suppressed")
    }

    // MARK: - Rule 2: drain, never drop

    /// A request that lands while a refresh is in flight has to run afterwards.
    /// The in-flight rescan may have walked the tree *before* the sidecars that
    /// prompted the new request existed, so its manifest cannot contain them.
    func testARequestArrivingMidRefreshIsRunAfterwards() async {
        let coalescer = makeCoalescer()
        var refreshes = 0
        let gate = AsyncGate()

        coalescer.onRefresh = { [weak coalescer] in
            refreshes += 1
            if refreshes == 1 {
                // Ask again from inside the first refresh: the drain loop has
                // to notice and go round once more.
                coalescer?.schedule()
                await gate.wait()
            }
        }

        coalescer.schedule()
        await gate.open()
        await coalescer.task?.value
        XCTAssertEqual(refreshes, 2, "the request made mid-refresh was dropped")
        XCTAssertNil(coalescer.task, "the drain loop did not settle")
    }

    // MARK: - One instance, two engines

    /// The Store hands the same coalescer to both services, so the window is a
    /// budget for the *app* rather than one each.
    func testOneInstanceSharedByBothServicesSpendsOneWindow() async throws {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        let shared = makeCoalescer()
        var refreshes = 0

        let tagging = TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true),
            refresh: shared
        )
        let faces = FaceService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            refresh: shared
        )
        XCTAssertNil(tagging.lastRefreshAt, "nothing has refreshed yet")

        // Either service's setter reaches the one instance.
        faces.onSidecarsWritten = { refreshes += 1 }

        faces.noteSidecarsWritten(4)
        await faces.refreshTask?.value
        XCTAssertEqual(refreshes, 1)
        // Both services see the same window close.
        XCTAssertNotNil(tagging.lastRefreshAt)
        XCTAssertEqual(tagging.lastRefreshAt, shared.lastRefreshAt)

        // A tagging batch inside that window is suppressed by the face batch
        // above — which is the entire point of sharing one instance.
        shared.note()
        await tagging.refreshTask?.value
        XCTAssertEqual(refreshes, 1, "the two engines each spent their own window")
    }
}

/// A one-shot gate a `@MainActor` closure can park on.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
