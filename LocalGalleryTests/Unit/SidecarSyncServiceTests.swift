import Foundation
import XCTest
@testable import LocalGallery

/// Plan-and-run completion, background hard limits, safe cache retraction,
/// and the coordinated-read timeout. Fetch I/O is exercised only with
/// tiny local files (or missing paths) so the suite stays off the network.
@MainActor
final class SidecarSyncServiceTests: XCTestCase {

    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    private func makeSync(_ temp: TempDir) -> (SidecarSyncService, SidecarCacheStore) {
        let cache = SidecarCacheStore(url: temp.appending("sidecar_cache.json"))
        return (SidecarSyncService(cache: cache), cache)
    }

    private func candidate(
        id: UUID = UUID(),
        url: URL = URL(fileURLWithPath: "/tmp/missing.jpg.xmp"),
        size: Int64? = 10
    ) -> SidecarCandidate {
        SidecarCandidate(
            photoID: id,
            sidecarURL: url,
            currentVersion: FileProviderDetector.ContentVersion(size: size),
            downloadStatus: .local
        )
    }

    private func cached(
        size: Int64 = 10,
        tags: [String] = ["People/Ada"],
        country: String? = "IT",
        faces: [FaceRegion] = [FaceRegion(name: "Ada", centerX: 0.4, centerY: 0.4, width: 0.1, height: 0.1)]
    ) -> SidecarCacheStore.CachedSidecar {
        SidecarCacheStore.CachedSidecar(
            version: FileProviderDetector.ContentVersion(size: size),
            hierarchicalTags: tags.map { HierarchicalTag(raw: $0) },
            countryCode: country,
            faceRegions: faces
        )
    }

    private static let emptyXMP = """
    <x:xmpmeta xmlns:x='adobe:ns:meta/'>
     <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
      <rdf:Description rdf:about=''/>
     </rdf:RDF>
    </x:xmpmeta>
    """

    private static let taggedXMP = """
    <x:xmpmeta xmlns:x='adobe:ns:meta/'>
     <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
      <rdf:Description rdf:about=''
       xmlns:digiKam='http://www.digikam.org/ns/1.0/'
       xmlns:phototools='https://github.com/j23n/photo-tools/ns/1.0/'>
       <digiKam:TagsList><rdf:Seq><rdf:li>People/Ada</rdf:li></rdf:Seq></digiKam:TagsList>
       <phototools:CountryCode>IT</phototools:CountryCode>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    // MARK: - Await / completion

    func testPlanAndRunReturnsIdleWhenNothingNeedsFetching() async {
        let temp = makeTemp()
        let (sync, cache) = makeSync(temp)
        let id = UUID()
        let row = candidate(id: id, size: 12)
        cache.put(id, cached(size: 12))

        await sync.planAndRun(
            manifest: [row],
            allPhotoIDs: [id],
            autoApprove: true,
            listing: .complete
        )
        XCTAssertEqual(sync.state, .idle)
    }

    func testPlanAndRunFinishesBeforeReturning() async {
        let temp = makeTemp()
        let (sync, _) = makeSync(temp)
        let url = temp.appending("photo.jpg.xmp")
        try? Self.taggedXMP.write(to: url, atomically: true, encoding: .utf8)
        let id = UUID()
        let row = candidate(id: id, url: url, size: Int64(Self.taggedXMP.utf8.count))

        await sync.planAndRun(
            manifest: [row],
            allPhotoIDs: [id],
            autoApprove: true,
            listing: .complete
        )
        guard case .finished(let succeeded, let failed) = sync.state else {
            return XCTFail("planAndRun returned while still \(sync.state)")
        }
        XCTAssertEqual(succeeded + failed, 1)
        XCTAssertEqual(succeeded, 1)
    }

    func testCancelCompletesAnInFlightPlanAndRun() async {
        let temp = makeTemp()
        let (sync, _) = makeSync(temp)
        // Missing paths fail the coordinated read quickly; cancel still has
        // to settle the TaskGroup rather than leave `.syncing` behind.
        let rows = (0..<8).map { i in
            candidate(id: UUID(), url: temp.appending("gone-\(i).xmp"), size: 8)
        }

        let work = Task { @MainActor in
            await sync.planAndRun(
                manifest: rows,
                allPhotoIDs: Set(rows.map(\.photoID)),
                autoApprove: true,
                policy: .background,
                listing: .complete
            )
        }
        sync.cancel()
        await work.value
        if case .syncing = sync.state {
            XCTFail("cancel left the service in \(sync.state)")
        }
    }

    // MARK: - Limits (even with auto-approval)

    func testBackgroundPolicyCapsCountAt200() {
        let rows = (0..<250).map { i in
            candidate(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(i).xmp"), size: 20)
        }
        let capped = SidecarSyncService.applyLimits(rows, policy: .background)
        XCTAssertEqual(capped.count, SidecarSyncService.backgroundMaxCount)
        XCTAssertEqual(
            SidecarSyncService.applyLimits(rows, policy: .foreground).count,
            250,
            "foreground must not inherit the BG count cap"
        )
    }

    func testBackgroundPolicySkipsOversizedFiles() {
        let huge = candidate(size: SidecarSyncService.backgroundMaxFileBytes + 1)
        XCTAssertTrue(SidecarSyncService.applyLimits([huge], policy: .background).isEmpty)
        XCTAssertEqual(SidecarSyncService.applyLimits([huge], policy: .foreground).count, 1)
    }

    func testBackgroundPolicyCapsTotalBytes() {
        // 20 × 1 MB = 20 MB, over the 10 MB BG budget.
        let rows = (0..<20).map { i in
            candidate(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(i).xmp"), size: 1_000_000)
        }
        let capped = SidecarSyncService.applyLimits(rows, policy: .background)
        let bytes = capped.reduce(Int64(0)) { $0 + ($1.currentVersion.size ?? 0) }
        XCTAssertLessThanOrEqual(bytes, SidecarSyncService.backgroundMaxTotalBytes)
        XCTAssertFalse(capped.isEmpty)
    }

    func testAutoApproveStillAppliesBackgroundLimits() async {
        let temp = makeTemp()
        let (sync, _) = makeSync(temp)
        let rows = (0..<250).map { i in
            candidate(id: UUID(), url: temp.appending("missing-\(i).xmp"), size: 16)
        }
        await sync.planAndRun(
            manifest: rows,
            allPhotoIDs: Set(rows.map(\.photoID)),
            autoApprove: true,
            policy: .background,
            listing: .complete
        )
        guard case .finished(let succeeded, let failed) = sync.state else {
            return XCTFail("expected a finished fetch, got \(sync.state)")
        }
        XCTAssertEqual(succeeded + failed, SidecarSyncService.backgroundMaxCount)
    }

    // MARK: - Deletion / orphan GC

    func testACompleteListingRemovesCacheForMissingSidecars() {
        let temp = makeTemp()
        let (sync, cache) = makeSync(temp)
        let keepID = UUID()
        let goneID = UUID()
        cache.put(keepID, cached(size: 12))
        cache.put(goneID, cached(size: 9))
        var finished = 0
        sync.onFinished = { finished += 1 }

        sync.plan(
            manifest: [candidate(id: keepID, size: 12)],
            allPhotoIDs: [keepID, goneID],
            autoApprove: true,
            listing: .complete
        )
        XCTAssertNotNil(cache.get(keepID))
        XCTAssertNil(cache.get(goneID), "a complete listing must retract a vanished sidecar")
        XCTAssertEqual(finished, 1, "a fetch-less GC must still re-merge live photos")
    }

    func testAnIncompleteListingPreservesCacheForMissingSidecars() {
        let temp = makeTemp()
        let (sync, cache) = makeSync(temp)
        let keepID = UUID()
        let hiddenID = UUID()
        cache.put(keepID, cached(size: 12))
        cache.put(hiddenID, cached(size: 9))
        var finished = 0
        sync.onFinished = { finished += 1 }

        sync.plan(
            manifest: [candidate(id: keepID, size: 12)],
            allPhotoIDs: [keepID, hiddenID],
            autoApprove: true,
            listing: .from(failedDirectoryPaths: ["/library/Locked"])
        )
        XCTAssertNotNil(cache.get(keepID))
        XCTAssertNotNil(cache.get(hiddenID), "a failed directory must not look like deletion")
        XCTAssertEqual(finished, 0, "preserving cache is not a retraction")
    }

    func testAnIncompleteListingStillDropsCacheForDeletedPhotos() {
        let temp = makeTemp()
        let (sync, cache) = makeSync(temp)
        let keepID = UUID()
        let deletedPhoto = UUID()
        cache.put(keepID, cached(size: 12))
        cache.put(deletedPhoto, cached(size: 9))

        sync.plan(
            manifest: [candidate(id: keepID, size: 12)],
            allPhotoIDs: [keepID],
            autoApprove: true,
            listing: .incomplete
        )
        XCTAssertNotNil(cache.get(keepID))
        XCTAssertNil(cache.get(deletedPhoto), "a photo that left the library is always an orphan")
    }

    func testConfirmedGoneIsRemovedEvenWhenTheListingIsPartial() {
        let temp = makeTemp()
        let (sync, cache) = makeSync(temp)
        let keepID = UUID()
        let goneID = UUID()
        cache.put(keepID, cached(size: 12))
        cache.put(goneID, cached(size: 9))

        sync.plan(
            manifest: [candidate(id: keepID, size: 12)],
            allPhotoIDs: [keepID, goneID],
            autoApprove: true,
            listing: SidecarSyncService.Listing(isComplete: false, confirmedGone: [goneID])
        )
        XCTAssertNotNil(cache.get(keepID))
        XCTAssertNil(cache.get(goneID), "a re-probe that saw the file gone may retract it")
    }

    // MARK: - Empty successful fetch retracts

    func testASuccessfulEmptySidecarReplacesCachedTags() async {
        let temp = makeTemp()
        let (sync, cache) = makeSync(temp)
        let url = temp.appending("cleared.jpg.xmp")
        try? Self.emptyXMP.write(to: url, atomically: true, encoding: .utf8)
        let id = UUID()
        cache.put(id, cached(size: 1))

        await sync.planAndRun(
            manifest: [candidate(id: id, url: url, size: Int64(Self.emptyXMP.utf8.count))],
            allPhotoIDs: [id],
            autoApprove: true,
            listing: .complete
        )
        let entry = cache.get(id)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.hierarchicalTags.isEmpty == true, "empty sidecar must retract tags")
        XCTAssertNil(entry?.countryCode)
        XCTAssertTrue(entry?.faceRegions.isEmpty == true)
    }

    // MARK: - Timeout

    func testWithTimeoutReturnsTheOperationValue() async throws {
        let value = try await SidecarSyncService.withTimeout(.seconds(1)) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testWithTimeoutFiresWithoutWaitingForTheLoser() async {
        let started = ContinuousClock.now
        do {
            _ = try await SidecarSyncService.withTimeout(.milliseconds(40)) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
            XCTFail("should have timed out")
        } catch SidecarSyncService.ReadError.timeout {
            let elapsed = ContinuousClock.now - started
            XCTAssertLessThan(elapsed, .seconds(2), "timeout waited for the sleeping operation")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
