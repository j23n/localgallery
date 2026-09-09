import Foundation
import XCTest
@testable import LocalGallery

/// The BG sidecar refresh must re-probe versions and not return until the
/// awaited plan-and-run has settled (or been cancelled).
@MainActor
final class SidecarRefreshServiceTests: XCTestCase {

    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    private func candidate(
        id: UUID = UUID(),
        url: URL,
        size: Int64
    ) -> SidecarCandidate {
        SidecarCandidate(
            photoID: id,
            sidecarURL: url,
            currentVersion: FileProviderDetector.ContentVersion(size: size),
            downloadStatus: .local
        )
    }

    func testRefreshedManifestReplacesStaleVersions() {
        let url = URL(fileURLWithPath: "/library/a.jpg.xmp")
        let id = UUID()
        let stale = candidate(id: id, url: url, size: 1)
        let (fresh, gone) = SidecarRefreshService.refreshedManifest(
            [stale],
            versionOf: { _ in FileProviderDetector.ContentVersion(size: 99, modificationDate: Date()) },
            fileExists: { _ in true }
        )
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(fresh.first?.currentVersion.size, 99)
        XCTAssertNotEqual(fresh.first?.currentVersion, stale.currentVersion)
    }

    func testRefreshedManifestReportsGoneSidecars() {
        let url = URL(fileURLWithPath: "/library/deleted.jpg.xmp")
        let id = UUID()
        let (fresh, gone) = SidecarRefreshService.refreshedManifest(
            [candidate(id: id, url: url, size: 12)],
            versionOf: { _ in FileProviderDetector.ContentVersion() },
            fileExists: { _ in false }
        )
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(gone, [id])
    }

    func testRefreshedManifestKeepsThePriorVersionWhenTheProbeIsEmpty() {
        let url = URL(fileURLWithPath: "/library/a.jpg.xmp")
        let id = UUID()
        let prior = candidate(id: id, url: url, size: 44)
        let (fresh, gone) = SidecarRefreshService.refreshedManifest(
            [prior],
            versionOf: { _ in FileProviderDetector.ContentVersion() },
            fileExists: { _ in true }
        )
        XCTAssertTrue(gone.isEmpty)
        XCTAssertEqual(fresh.first?.currentVersion.size, 44)
    }

    func testRunRefreshNoOpsWithoutAStoreOrManifest() async {
        let service = SidecarRefreshService()
        await service.runRefresh()

        let harness = TestGalleryStore.make()
        addTeardownBlock { harness.teardown() }
        service.attach(harness.store)
        XCTAssertTrue(harness.store.lastSidecarManifest.isEmpty)
        await service.runRefresh()
        XCTAssertEqual(harness.store.sidecarSync.state, .idle)
    }

    func testRunRefreshAwaitsTheFetchAndUsesReprobedVersions() async {
        let harness = TestGalleryStore.make()
        addTeardownBlock { harness.teardown() }
        let temp = makeTemp()
        let xmp = temp.appending("photo.jpg.xmp")
        let body = "<x:xmpmeta xmlns:x='adobe:ns:meta/'></x:xmpmeta>"
        try? body.write(to: xmp, atomically: true, encoding: .utf8)
        let photo = PhotoFile.fixture(url: temp.appending("photo.jpg"))
        let stale = candidate(id: photo.id, url: xmp, size: 1)
        harness.store.apply(.scanResult(
            photos: [photo],
            root: .fixture(url: temp.url, photos: [photo]),
            persistCache: false
        ))
        harness.store.lastSidecarManifest = [stale]

        let service = SidecarRefreshService()
        service.attach(harness.store)
        await service.runRefresh()

        if case .syncing = harness.store.sidecarSync.state {
            XCTFail("runRefresh returned while the fetch was still \(harness.store.sidecarSync.state)")
        }
        XCTAssertEqual(harness.store.lastSidecarManifest.count, 1)
        XCTAssertNotEqual(
            harness.store.lastSidecarManifest.first?.currentVersion.size,
            1,
            "a stale prior size must not be left on the manifest after re-probe"
        )
    }

    func testRunRefreshCancelReturns() async {
        let harness = TestGalleryStore.make()
        addTeardownBlock { harness.teardown() }
        let rows = (0..<20).map { i in
            candidate(
                id: UUID(),
                url: URL(fileURLWithPath: "/tmp/bg-missing-\(i).xmp"),
                size: 8
            )
        }
        harness.store.lastSidecarManifest = rows
        let service = SidecarRefreshService()
        service.attach(harness.store)

        let work = Task { @MainActor in
            await service.runRefresh()
        }
        work.cancel()
        await work.value
    }
}
