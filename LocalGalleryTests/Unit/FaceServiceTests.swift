import Foundation
import XCTest
@testable import LocalGallery

/// The app-side half of on-device faces: availability, the eligibility rule, a
/// full scan → name → refresh cycle, and the guards around a run.
///
/// The `FaceSession`/FFI half lives in `FaceSessionTests`.
@MainActor
final class FaceServiceTests: XCTestCase {
    /// A temp dir scoped to the running test. Built per test rather than in
    /// `setUp`, which XCTest calls from a nonisolated context.
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    private func bundleResource(_ name: String) throws -> URL {
        let bundle = Bundle(for: FaceServiceTests.self)
        return try XCTUnwrap(
            bundle.url(forResource: name, withExtension: nil),
            "\(name)/ is missing from the test bundle — check project.yml"
        )
    }

    /// A service pointed at a temp cache, told a face-capable pack is
    /// installed. `installedPack` is the seam `GalleryStore` wires to
    /// `TaggingService`, so a test can supply either kind of pack without
    /// staging one on disk.
    private func makeService(
        _ temp: TempDir, pack: TaggingService.PackStatus?
    ) -> FaceService {
        let service = FaceService(cacheDatabaseURL: temp.appending("gallery-cache.sqlite"))
        service.installedPack = { pack }
        return service
    }

    private func facePack() throws -> TaggingService.PackStatus {
        TaggingService.PackStatus(
            version: "gallery-ml-facepack-1",
            labelCount: 6,
            hasFaces: true,
            directory: try bundleResource("facepack")
        )
    }

    private func tagOnlyPack() throws -> TaggingService.PackStatus {
        TaggingService.PackStatus(
            version: "gallery-ml-testpack-1",
            labelCount: 6,
            hasFaces: false,
            directory: try bundleResource("testpack")
        )
    }

    /// Copy the three face fixtures into `temp` and return them as photos.
    @discardableResult
    private func stageLibrary(in temp: TempDir) throws -> [PhotoFile] {
        let fixtures = try bundleResource("fixtures")
        return try ["face_dark.png", "face_mid.png", "face_bright.png"].map { name in
            let url = temp.appending(name)
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name), to: url
            )
            return PhotoFile.fixture(url: url)
        }
    }

    /// Wait for an in-flight run to settle. `startScan` returns as soon as the
    /// core-owned thread is spawned; the finish arrives through `onFinished`.
    private func waitForRun(_ service: FaceService) async throws {
        var waited = 0
        while service.isRunning && waited < 6_000 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(service.isRunning, "the run never finished")
        await service.refreshTask?.value
    }

    // MARK: - Availability

    /// A tagging-only pack is a valid pack. Faces are simply not offered — the
    /// app must not report it as a broken install.
    func testATagOnlyPackLeavesFacesUnavailableWithoutAnError() async throws {
        let temp = makeTemp()
        let service = makeService(temp, pack: try tagOnlyPack())
        XCTAssertFalse(service.isAvailable)

        await service.startScan()
        XCTAssertEqual(service.lastError, .noFaceModels)
        XCTAssertFalse(service.isRunning)

        // And with no pack at all.
        let none = makeService(temp, pack: nil)
        XCTAssertFalse(none.isAvailable)
        await none.refreshClusters()
        XCTAssertTrue(none.allClusters.isEmpty)
    }

    func testAFaceCapablePackMakesFacesAvailable() throws {
        let temp = makeTemp()
        XCTAssertTrue(makeService(temp, pack: try facePack()).isAvailable)
    }

    // MARK: - Eligibility

    /// Faces run over exactly the photos tagging runs over — same bytes, same
    /// decoder, same sidecar. This is the test that fails the day one of them
    /// drifts.
    func testEligibilityMatchesTagging() throws {
        let temp = makeTemp()
        let photo = PhotoFile.fixture(url: temp.appending("a.jpg"))
        let video = PhotoFile.fixture(url: temp.appending("clip.mov"), isVideo: true)
        var placeholder = PhotoFile.fixture(url: temp.appending("cloud.jpg"))
        placeholder.locality = .remote(downloaded: false)
        var downloaded = placeholder
        downloaded.locality = .remote(downloaded: true)

        for candidate in [photo, video, placeholder, downloaded] {
            XCTAssertEqual(
                FaceService.isEligible(candidate),
                TaggingService.isEligible(candidate),
                "faces and tagging disagree about \(candidate.url.lastPathComponent)"
            )
        }
        XCTAssertTrue(FaceService.isEligible(photo))
        XCTAssertFalse(FaceService.isEligible(video))
        XCTAssertFalse(FaceService.isEligible(placeholder))
        XCTAssertTrue(FaceService.isEligible(downloaded))
    }

    /// A library of nothing eligible is not a failure — it is a run with
    /// nothing to do, and the summary has to say so rather than leaving the
    /// last one on screen.
    func testALibraryWithNothingEligibleFinishesWithAnEmptySummary() async throws {
        let temp = makeTemp()
        let service = makeService(temp, pack: try facePack())
        service.eligiblePhotos = { [PhotoFile.fixture(url: temp.appending("clip.mov"), isVideo: true)] }

        await service.startScan()
        XCTAssertEqual(service.lastSummary, FaceService.Summary())
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.lastError)
    }

    // MARK: - A full cycle

    /// Scan → clusters appear → name one → the sidecar refresh fires.
    ///
    /// The refresh is the load-bearing half on this side: naming writes `.xmp`
    /// files the last scan never saw, so without it `PeopleStore` would never
    /// learn about the person.
    func testScanningThenNamingPublishesTheClusterAndTriggersARefresh() async throws {
        let temp = makeTemp()
        let photos = try stageLibrary(in: temp)
        let service = makeService(temp, pack: try facePack())
        service.eligiblePhotos = { photos }
        service.libraryRoot = { temp.url }

        var refreshes = 0
        service.onSidecarsWritten = { refreshes += 1 }

        await service.startScan()
        try await waitForRun(service)

        let summary = try XCTUnwrap(service.lastSummary)
        XCTAssertNil(summary.failure)
        XCTAssertEqual(summary.processed, photos.count)
        XCTAssertGreaterThan(summary.facesFound, 0)
        XCTAssertFalse(service.allClusters.isEmpty, "the run published no clusters")
        // The run itself names nobody, so nothing reached disk.
        XCTAssertEqual(summary.sidecarsWritten, 0)
        let refreshesAfterScan = refreshes
        XCTAssertGreaterThan(refreshesAfterScan, 0, "the end-of-run refresh did not fire")

        let cluster = try XCTUnwrap(
            service.allClusters.filter { $0.state == .unlabeled }.max { $0.size < $1.size }
        )
        XCTAssertFalse(cluster.exemplars.isEmpty)
        // The exemplar is a `FaceRegion` the existing cover-crop renderer takes
        // unchanged — that equivalence is the reason no new crop path exists.
        let exemplar = try XCTUnwrap(cluster.exemplars.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exemplar.url.path))
        XCTAssertTrue((0...1).contains(exemplar.region.centerX))
        XCTAssertNil(exemplar.region.name, "an unlabeled face has no person")

        // Every face of the cluster, for the detail screen.
        let faces = await service.faces(inCluster: cluster.id)
        XCTAssertEqual(faces.count, cluster.size)

        let named = await service.name(cluster: cluster.id, as: "Ada Lovelace")
        XCTAssertTrue(named)
        XCTAssertNil(service.lastError)
        XCTAssertGreaterThan(refreshes, refreshesAfterScan, "naming did not trigger a refresh")

        // The cluster list was re-read, so the review queue drops it.
        let after = try XCTUnwrap(service.allClusters.first { $0.id == cluster.id })
        XCTAssertEqual(after.state, .named)
        XCTAssertEqual(after.name, "Ada Lovelace")
        XCTAssertFalse(service.reviewableClusters.contains { $0.id == cluster.id })
        XCTAssertTrue(service.namedClusters.contains { $0.id == cluster.id })

        // And a sidecar the app's own reader understands is on disk.
        let sidecar = exemplar.url.appendingPathExtension("xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let xmp = MetadataReader.parseXMPBytes(try Data(contentsOf: sidecar))
        XCTAssertTrue(xmp.rawTags.contains("People/Ada Lovelace"), "\(xmp.rawTags)")
        XCTAssertFalse(xmp.faceRegions.isEmpty)
    }

    /// The review threshold: a group of one or two faces is the tail of any
    /// clustering pass and would drown the screen.
    func testOnlyClustersOverTheThresholdAreOfferedForReview() async throws {
        let temp = makeTemp()
        let photos = try stageLibrary(in: temp)
        let service = makeService(temp, pack: try facePack())
        service.eligiblePhotos = { photos }
        await service.startScan()
        try await waitForRun(service)

        XCTAssertFalse(service.allClusters.isEmpty)
        for cluster in service.reviewableClusters {
            XCTAssertEqual(cluster.state, .unlabeled)
            XCTAssertGreaterThanOrEqual(cluster.size, FaceService.reviewMinimumFaces)
        }
        // Biggest first, so the most useful card is at the top.
        XCTAssertEqual(
            service.reviewableClusters.map(\.size),
            service.reviewableClusters.map(\.size).sorted(by: >)
        )
        // Nothing under the bar leaks in.
        let small = service.allClusters.filter {
            $0.state == .unlabeled && $0.size < FaceService.reviewMinimumFaces
        }
        for cluster in small {
            XCTAssertFalse(service.reviewableClusters.contains { $0.id == cluster.id })
        }
    }

    /// Naming is refused while a scan runs — the core will not re-derive a
    /// sidecar from a cluster table a run is mutating. The service has to
    /// report that rather than let a button silently do nothing.
    func testNamingIsRefusedWhileAScanIsRunning() async throws {
        let temp = makeTemp()
        let photos = try stageLibrary(in: temp)
        let service = makeService(temp, pack: try facePack())
        service.eligiblePhotos = { photos }

        // First run, so there is a cluster to aim at.
        await service.startScan()
        try await waitForRun(service)
        let cluster = try XCTUnwrap(service.allClusters.first)

        // Drive the guard directly: `isRunning` is what gates it, and staging a
        // second real run just to be inside it would be a timing race.
        let run = Task { await service.startScan() }
        var spins = 0
        while !service.isRunning && spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertTrue(service.isRunning, "startScan never reached its opening phase")

        let named = await service.name(cluster: cluster.id, as: "Ada")
        XCTAssertFalse(named)
        XCTAssertEqual(service.lastError, .alreadyRunning)

        service.cancel()
        await run.value
        try await waitForRun(service)
    }

    /// Cancel pressed while the session is opening has no run to reach — the
    /// request has to be honoured by *not starting*.
    func testCancellingWhileTheSessionOpensNeverStartsTheRun() async throws {
        let temp = makeTemp()
        let photos = try stageLibrary(in: temp)
        let service = makeService(temp, pack: try facePack())
        service.eligiblePhotos = { photos }

        let run = Task { await service.startScan() }
        var spins = 0
        while !service.isRunning && spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertTrue(service.isRunning, "startScan never reached its opening phase")

        service.cancel()
        await run.value

        XCTAssertFalse(service.isRunning, "cancelling left the service stuck in the running state")
        XCTAssertNil(service.progress)
        XCTAssertEqual(service.lastSummary?.cancelled, true)
        XCTAssertEqual(service.lastSummary?.processed, 0)

        // And the service is not wedged: a fresh start runs normally.
        await service.startScan()
        try await waitForRun(service)
        XCTAssertEqual(service.lastSummary?.cancelled, false)
        XCTAssertEqual(service.lastSummary?.processed, photos.count)
    }

    // MARK: - Refresh coalescing

    /// The coalescer is shared with tagging; this pins that faces actually use
    /// it rather than refreshing per batch.
    func testASuppressedBatchDoesNotPushTheRefreshWindowOut() async {
        let temp = makeTemp()
        let service = makeService(temp, pack: nil)
        var refreshes = 0
        service.onSidecarsWritten = { refreshes += 1 }

        service.noteSidecarsWritten(8)
        await service.refreshTask?.value
        XCTAssertEqual(refreshes, 1)

        service.noteSidecarsWritten(8)
        await service.refreshTask?.value
        XCTAssertEqual(refreshes, 1, "a batch inside the interval should coalesce away")
    }
}
