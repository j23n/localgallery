import Foundation
import XCTest
@testable import LocalGallery

/// The app-side half of on-device tagging: how a run's results are pulled back
/// into the library, and how the service behaves around the edges of a run.
///
/// The `TaggingSession`/FFI half lives in `TaggingSessionTests`.
@MainActor
final class TaggingServiceTests: XCTestCase {
    /// A temp dir scoped to the running test. Built per test rather than in
    /// `setUp`, which XCTest calls from a nonisolated context.
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    private func makeService(_ temp: TempDir) -> TaggingService {
        TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true)
        )
    }

    private func bundleResource(_ name: String) throws -> URL {
        let bundle = Bundle(for: TaggingServiceTests.self)
        return try XCTUnwrap(
            bundle.url(forResource: name, withExtension: nil),
            "\(name)/ is missing from the test bundle — check project.yml"
        )
    }

    /// Install the committed test pack where the service will find it.
    @discardableResult
    private func installTestPack(in temp: TempDir) throws -> URL {
        let packs = temp.appending("ModelPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        let installed = packs.appendingPathComponent("gallery-ml-testpack-1", isDirectory: true)
        try FileManager.default.copyItem(at: try bundleResource("testpack"), to: installed)
        return installed
    }

    /// Counts refreshes and can hold the first one open.
    @MainActor
    private final class RefreshProbe {
        private(set) var count = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var holdNext = false
        var onFirstStarted: (() -> Void)?

        func holdTheNextRefresh() { holdNext = true }

        func release() {
            let gate = self.gate
            self.gate = nil
            gate?.resume()
        }

        func run() async {
            count += 1
            guard holdNext else { return }
            holdNext = false
            onFirstStarted?()
            await withCheckedContinuation { self.gate = $0 }
        }
    }

    // MARK: - Refresh coalescing

    /// A refresh asked for while one is in flight must still happen.
    ///
    /// The rescan already walking the tree may have listed it *before* the
    /// sidecars that prompted the new request existed, so its manifest cannot
    /// contain them — dropping the request loses those tags until something
    /// else happens to trigger a scan.
    func testARefreshRequestedDuringAnInFlightOneIsDrainedNotDropped() async {
        let temp = makeTemp()
        let service = makeService(temp)
        let probe = RefreshProbe()
        service.onSidecarsWritten = { [probe] in await probe.run() }

        let started = expectation(description: "first refresh started")
        probe.onFirstStarted = { started.fulfill() }
        probe.holdTheNextRefresh()

        service.noteSidecarsWritten(32)
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(probe.count, 1)

        // A second request, provably inside the first refresh's window.
        service.scheduleRefresh()
        XCTAssertEqual(probe.count, 1, "the second refresh must wait, not run concurrently")

        probe.release()
        await service.refreshTask?.value

        XCTAssertEqual(
            probe.count, 2,
            "the request that arrived during the in-flight refresh was dropped"
        )
        XCTAssertNil(service.refreshTask, "the drain loop did not clear its own task")
    }

    /// A batch suppressed by `refreshInterval` must not push the window out.
    ///
    /// Advancing `lastRefreshAt` for a refresh that never ran let a steady drip
    /// of batches keep resetting the timer, so partial results never appeared
    /// until the run ended.
    func testASuppressedBatchDoesNotPushTheRefreshWindowOut() async {
        let temp = makeTemp()
        let service = makeService(temp)
        let probe = RefreshProbe()
        service.onSidecarsWritten = { [probe] in await probe.run() }

        service.noteSidecarsWritten(32)
        await service.refreshTask?.value
        XCTAssertEqual(probe.count, 1)
        let windowStart = service.lastRefreshAt
        XCTAssertNotNil(windowStart)

        // Well inside `refreshInterval`: suppressed, and the window keeps its
        // original start rather than restarting from now.
        service.noteSidecarsWritten(32)
        await service.refreshTask?.value
        XCTAssertEqual(probe.count, 1, "a batch inside the interval should coalesce away")
        XCTAssertEqual(
            service.lastRefreshAt, windowStart,
            "a suppressed batch moved the window, so the next refresh is deferred again"
        )
    }

    // MARK: - Cancellation

    /// Cancel pressed while the session is opening has no run to reach: the
    /// session does not exist yet, and the core clears its own cancel flag
    /// inside `start` anyway. The request has to be honoured by *not starting*.
    ///
    /// Deterministic by construction: the loop below returns the moment
    /// `startTagging` has suspended on `openSession`, which is a detached task
    /// loading ONNX weights — milliseconds of work against the microseconds
    /// this test needs to reach `cancel()`.
    func testCancellingWhileTheSessionOpensNeverStartsTheRun() async throws {
        let temp = makeTemp()
        try installTestPack(in: temp)
        let photoURL = temp.appending("gradient.jpg")
        try FileManager.default.copyItem(
            at: try bundleResource("fixtures").appendingPathComponent("gradient.jpg"),
            to: photoURL
        )
        let sidecarURL = temp.appending("gradient.jpg.xmp")
        let rootURL = temp.url

        let service = makeService(temp)
        await service.refreshAvailability()
        XCTAssertTrue(service.isAvailable, "the test pack did not install")

        service.eligiblePhotos = { [PhotoFile.fixture(url: photoURL)] }
        service.libraryRoot = { rootURL }

        let run = Task { await service.startTagging() }
        var spins = 0
        while !service.isRunning && spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertTrue(service.isRunning, "startTagging never reached its opening phase")

        service.cancel()
        await run.value

        XCTAssertFalse(service.isRunning, "cancelling left the service stuck in the running state")
        XCTAssertNil(service.progress)
        XCTAssertEqual(service.lastSummary?.cancelled, true)
        XCTAssertEqual(service.lastSummary?.processed, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "a run the user cancelled before it started wrote a sidecar"
        )

        // And the service is not wedged: a fresh start runs normally.
        // `startTagging` returns as soon as the core-owned run thread is
        // spawned, so the finish comes back through `onFinished` later.
        await service.startTagging()
        var waited = 0
        while service.isRunning && waited < 6_000 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(service.isRunning, "the second run never finished")
        XCTAssertEqual(service.lastSummary?.processed, 1)
        XCTAssertEqual(service.lastSummary?.cancelled, false)
        await service.refreshTask?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: - Errors

    /// `noModelPack` used to be unreachable — both entry points returned
    /// silently, so "nothing happened" was the whole user-facing behaviour.
    func testStartingWithoutAModelPackSurfacesATypedError() async {
        let temp = makeTemp()
        let service = makeService(temp)
        await service.refreshAvailability()
        XCTAssertFalse(service.isAvailable)

        await service.startTagging()
        XCTAssertEqual(service.lastError, .noModelPack)
        XCTAssertFalse(service.isRunning)
    }

    func testResettingWithoutAModelPackSurfacesATypedError() async {
        let temp = makeTemp()
        let service = makeService(temp)
        await service.refreshAvailability()

        await service.resetQueue()
        XCTAssertEqual(service.lastError, .noModelPack)
    }

    /// Reset opens a session if one isn't already open — the queue that needs
    /// resetting is precisely the one whose owner has not run tagging this
    /// launch, so requiring an open session made the button a no-op.
    func testResettingTheQueueWorksWithoutHavingRunFirst() async throws {
        let temp = makeTemp()
        try installTestPack(in: temp)
        let service = makeService(temp)
        await service.refreshAvailability()
        XCTAssertTrue(service.isAvailable)

        await service.resetQueue()
        XCTAssertNil(service.lastError)
        XCTAssertNil(service.lastSummary)
    }

    // MARK: - Model pack selection and verification

    /// Settings' `.task` fires on every appearance of the screen, and full
    /// verification SHA-256s the whole ONNX. An unchanged pack must not be
    /// re-hashed.
    func testRepeatedAvailabilityChecksDoNotReVerifyAnUnchangedPack() async throws {
        let temp = makeTemp()
        let installed = try installTestPack(in: temp)
        let service = makeService(temp)

        await service.refreshAvailability()
        let first = service.pack
        XCTAssertEqual(first?.version, "gallery-ml-testpack-1")

        // Break the pack behind the service's back, leaving the manifest's
        // size and mtime alone. A re-verification would notice (the ONNX no
        // longer hashes to what the manifest claims); the cached answer, by
        // design, does not.
        let encoder = installed.appendingPathComponent("encoder.onnx")
        var bytes = try Data(contentsOf: encoder)
        bytes[64] ^= 0xFF
        try bytes.write(to: encoder)

        await service.refreshAvailability()
        XCTAssertEqual(
            service.pack, first,
            "an unchanged manifest should not trigger a re-hash of the model"
        )

        // `force` is the escape hatch, and it does catch the tampering — which
        // is what proves the check above was skipped rather than merely
        // passing.
        await service.refreshAvailability(force: true)
        XCTAssertNil(service.pack)
        guard case .pack = service.lastError else {
            return XCTFail("expected a pack error, got \(String(describing: service.lastError))")
        }
    }
}
