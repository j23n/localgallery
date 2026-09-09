import Foundation
import XCTest
@testable import LocalGallery

/// On-disk move: the photo, both sidecar spellings, and a Live Photo pair
/// follow the file into the destination folder, and the library's stable
/// ids (derived from path) update without a rescan.
@MainActor
final class PhotoMoveTests: XCTestCase {

    private func makeHarness() -> TestGalleryStore.Harness {
        let inner = TestGalleryStore.make()
        addTeardownBlock { @MainActor in inner.teardown() }
        return inner
    }

    private func write(_ url: URL, _ body: String = "x") {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data(body.utf8))
    }

    func testMoveRelocatesThePhotoAndBothSidecarSpellings() async {
        let h = makeHarness()
        let src = h.tempDir.appending("inbox", isDirectory: true)
        let dest = h.tempDir.appending("italy", isDirectory: true)
        write(src.appendingPathComponent("shot.jpg"))
        write(URL(fileURLWithPath: src.appendingPathComponent("shot.jpg").path + ".xmp"))
        write(src.appendingPathComponent("shot.xmp"))
        let photo = PhotoFile.fixture(url: src.appendingPathComponent("shot.jpg"))
        let inbox = PhotoFolder.fixture(url: src, photos: [photo])
        let italy = PhotoFolder.fixture(url: dest)
        let root = PhotoFolder.fixture(url: h.tempDir.url, subfolders: [inbox, italy])
        h.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        let result = await h.store.movePhotos([photo], to: italy)

        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        let moved = result.moved[photo.id]
        XCTAssertEqual(moved?.url.path, dest.appendingPathComponent("shot.jpg").path)
        XCTAssertEqual(moved?.id, PhotoFile.stableID(for: dest.appendingPathComponent("shot.jpg")))
        XCTAssertNotEqual(moved?.id, photo.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("shot.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.jpg").path + ".xmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.xmp").path))
        XCTAssertEqual(h.store.allPhotos.map(\.id), [moved?.id])
        XCTAssertEqual(h.store.rootFolder?.folder(withID: italy.id)?.photos.map(\.id), [moved?.id])
        XCTAssertTrue(h.store.rootFolder?.folder(withID: inbox.id)?.photos.isEmpty ?? false)
    }

    func testMoveIsANoOpWhenThePhotoIsAlreadyThere() async {
        let h = makeHarness()
        let dest = h.tempDir.appending("here", isDirectory: true)
        write(dest.appendingPathComponent("shot.jpg"))
        let photo = PhotoFile.fixture(url: dest.appendingPathComponent("shot.jpg"))
        let folder = PhotoFolder.fixture(url: dest, photos: [photo])
        h.store.apply(.scanResult(photos: [photo], root: folder, persistCache: false))

        let result = await h.store.movePhotos([photo], to: folder)

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(h.store.allPhotos.map(\.id), [photo.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.jpg").path))
    }

    func testMoveRenamesOnCollision() async {
        let h = makeHarness()
        let src = h.tempDir.appending("inbox", isDirectory: true)
        let dest = h.tempDir.appending("italy", isDirectory: true)
        write(src.appendingPathComponent("shot.jpg"))
        write(dest.appendingPathComponent("shot.jpg"))
        let photo = PhotoFile.fixture(url: src.appendingPathComponent("shot.jpg"))
        let inbox = PhotoFolder.fixture(url: src, photos: [photo])
        let italy = PhotoFolder.fixture(
            url: dest,
            photos: [PhotoFile.fixture(url: dest.appendingPathComponent("shot.jpg"))]
        )
        let root = PhotoFolder.fixture(url: h.tempDir.url, subfolders: [inbox, italy])
        h.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        let result = await h.store.movePhotos([photo], to: italy)

        let moved = result.moved[photo.id]
        XCTAssertEqual(moved?.filename, "shot 2.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot 2.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.jpg").path))
    }

    func testMoveTakesTheLivePhotoPair() async {
        let h = makeHarness()
        let src = h.tempDir.appending("inbox", isDirectory: true)
        let dest = h.tempDir.appending("italy", isDirectory: true)
        write(src.appendingPathComponent("live.jpg"))
        write(src.appendingPathComponent("live.mov"))
        write(URL(fileURLWithPath: src.appendingPathComponent("live.jpg").path + ".xmp"))
        let photo = PhotoFile.fixture(
            url: src.appendingPathComponent("live.jpg"),
            livePhotoVideoURL: src.appendingPathComponent("live.mov")
        )
        let inbox = PhotoFolder.fixture(url: src, photos: [photo])
        let italy = PhotoFolder.fixture(url: dest)
        let root = PhotoFolder.fixture(url: h.tempDir.url, subfolders: [inbox, italy])
        h.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        let result = await h.store.movePhotos([photo], to: italy)

        let moved = result.moved[photo.id]
        XCTAssertEqual(moved?.livePhotoVideoURL?.lastPathComponent, "live.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("live.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("live.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("live.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("live.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("live.jpg").path + ".xmp"))
    }

    func testCreateFolderInsertsANodeAndMakesTheDirectory() {
        let h = makeHarness()
        let parent = PhotoFolder.fixture(url: h.tempDir.url)
        h.store.apply(.scanResult(photos: [], root: parent, persistCache: false))

        let created = h.store.createFolder(named: "2024", in: parent)

        XCTAssertEqual(created?.name, "2024")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.tempDir.appending("2024", isDirectory: true).path))
        XCTAssertEqual(h.store.rootFolder?.subfolders.map(\.name), ["2024"])
    }

    func testCreateFolderRejectsAnEmptyName() {
        let h = makeHarness()
        let parent = PhotoFolder.fixture(url: h.tempDir.url)
        h.store.apply(.scanResult(photos: [], root: parent, persistCache: false))
        XCTAssertNil(h.store.createFolder(named: "   ", in: parent))
        XCTAssertNil(h.store.createFolder(named: "a/b", in: parent))
    }

    func testMovePlanCoversSidecarsAndLivePair() {
        let photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/inbox/live.jpg"),
            livePhotoVideoURL: URL(fileURLWithPath: "/inbox/live.mov")
        )
        let dest = URL(fileURLWithPath: "/italy")
        let plan = PhotoDiskMove.plan(for: photo, directory: dest, names: ("live.jpg", "live.mov"))
        XCTAssertEqual(plan.map(\.role), [
            .primary, .sidecar, .altSidecar, .livePhoto, .liveSidecar, .liveAltSidecar
        ])
        XCTAssertEqual(plan.map(\.to.lastPathComponent), [
            "live.jpg", "live.jpg.xmp", "live.xmp", "live.mov", "live.mov.xmp", "live.xmp"
        ])
    }

    func testMoveVerdictIsNotSuccessWhenOnlyThePrimaryMoves() {
        let companions = [
            PhotoStepOutcome(
                role: .sidecar,
                url: URL(fileURLWithPath: "/a.jpg.xmp"),
                status: .failed
            )
        ]
        XCTAssertEqual(
            PhotoDiskMove.verdict(primary: .succeeded, companions: companions, rollback: nil),
            .partial
        )
        XCTAssertEqual(
            PhotoDiskMove.verdict(primary: .succeeded, companions: companions, rollback: .rolledBack),
            .rolledBack
        )
        XCTAssertEqual(
            PhotoDiskMove.verdict(primary: .succeeded, companions: companions, rollback: .needsReconciliation),
            .needsReconciliation
        )
    }

    func testCompanionFailureRollsThePrimaryBack() async {
        let h = makeHarness()
        addTeardownBlock {
            PhotoDiskMove.testFailRoles = []
            PhotoDiskMove.testFailRollback = false
        }
        let src = h.tempDir.appending("inbox", isDirectory: true)
        let dest = h.tempDir.appending("italy", isDirectory: true)
        write(src.appendingPathComponent("shot.jpg"))
        write(URL(fileURLWithPath: src.appendingPathComponent("shot.jpg").path + ".xmp"))
        let photo = PhotoFile.fixture(url: src.appendingPathComponent("shot.jpg"))
        let inbox = PhotoFolder.fixture(url: src, photos: [photo])
        let italy = PhotoFolder.fixture(url: dest)
        let root = PhotoFolder.fixture(url: h.tempDir.url, subfolders: [inbox, italy])
        h.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        PhotoDiskMove.testFailRoles = [.sidecar]
        let result = await h.store.movePhotos([photo], to: italy)

        XCTAssertTrue(result.moved.isEmpty, "rolled-back move must not report success")
        XCTAssertEqual(result.failed, [photo.id])
        XCTAssertTrue(result.partialIDs.isEmpty)
        XCTAssertFalse(result.needsReconciliation)
        XCTAssertEqual(h.store.allPhotos.map(\.id), [photo.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("shot.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("shot.jpg").path + ".xmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.jpg").path))
    }

    func testFailedRollbackForcesReconciliationAndDoesNotReportFullSuccess() async {
        let h = makeHarness()
        addTeardownBlock {
            PhotoDiskMove.testFailRoles = []
            PhotoDiskMove.testFailRollback = false
        }
        let src = h.tempDir.appending("inbox", isDirectory: true)
        let dest = h.tempDir.appending("italy", isDirectory: true)
        write(src.appendingPathComponent("shot.jpg"))
        write(URL(fileURLWithPath: src.appendingPathComponent("shot.jpg").path + ".xmp"))
        let photo = PhotoFile.fixture(url: src.appendingPathComponent("shot.jpg"))
        let inbox = PhotoFolder.fixture(url: src, photos: [photo])
        let italy = PhotoFolder.fixture(url: dest)
        let root = PhotoFolder.fixture(url: h.tempDir.url, subfolders: [inbox, italy])
        h.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        PhotoDiskMove.testFailRoles = [.sidecar]
        PhotoDiskMove.testFailRollback = true
        let result = await h.store.movePhotos([photo], to: italy)

        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.partialIDs, [photo.id])
        XCTAssertTrue(result.needsReconciliation)
        XCTAssertTrue(result.failed.isEmpty)
        let moved = result.moved[photo.id]
        XCTAssertEqual(moved?.url.path, dest.appendingPathComponent("shot.jpg").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("shot.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("shot.jpg").path + ".xmp"))
        XCTAssertEqual(h.store.allPhotos.map(\.id), [moved?.id])
    }

    func testPromptNamesTheDestination() {
        let photo = PhotoFile.fixture()
        let dest = PhotoFolder.fixture(url: URL(fileURLWithPath: "/lib/Italy"), name: "Italy")
        XCTAssertEqual(PhotoMovePrompt.title(for: [photo]), "Move Photo?")
        XCTAssertTrue(PhotoMovePrompt.message(for: [photo], destination: dest).contains("Italy"))
    }

    func testUniqueNamesSkipATakenFilename() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalGallery.move.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("shot.jpg").path, contents: Data("x".utf8))
        let photo = PhotoFile.fixture(url: URL(fileURLWithPath: "/inbox/shot.jpg"))
        let names = PhotoDiskMove.uniqueNames(for: photo, in: dir)
        XCTAssertEqual(names.photo, "shot 2.jpg")
    }
}
