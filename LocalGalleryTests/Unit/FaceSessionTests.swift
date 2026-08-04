import Foundation
import Synchronization
import XCTest
@testable import LocalGallery

/// End-to-end cover for the Phase 2 FFI: a real `FaceSession`, the real ONNX
/// Runtime, the committed face test pack, and real `.xmp` sidecars written to a
/// temp directory.
///
/// The pack and the image fixtures are the *same files* `cargo test` uses
/// (`core/gallery-ml/tests/`, referenced as folder resources in project.yml),
/// so this suite is also the cross-target determinism check — and the fixtures
/// are what make the expectations statable at all: the synthetic detector in
/// `tests/facepack` finds no faces in `face_dark.png`, one in `face_mid.png`
/// and several in `face_bright.png`, so "which photos should have gained a
/// sidecar" is a property of the inputs rather than of a model nobody can read.
///
/// If these fail, suspect the build chain first:
/// `./scripts/build_core.sh && xcodegen`.
final class FaceSessionTests: XCTestCase {
    private var temp: TempDir!

    /// The three face fixtures, in the order the Rust suite uses them.
    private static let stagedPhotos = ["face_dark.png", "face_mid.png", "face_bright.png"]

    override func setUp() {
        super.setUp()
        temp = TempDir.make()
    }

    override func tearDown() {
        temp.teardown()
        temp = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func resourceDirectory(_ name: String) throws -> URL {
        let bundle = Bundle(for: FaceSessionTests.self)
        return try XCTUnwrap(
            bundle.url(forResource: name, withExtension: nil),
            "\(name)/ is missing from the test bundle — check the folder reference in project.yml"
        )
    }

    @discardableResult
    private func stageLibrary() throws -> [String] {
        let fixtures = try resourceDirectory("fixtures")
        for name in Self.stagedPhotos {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name),
                to: temp.appending(name)
            )
        }
        return Self.stagedPhotos
    }

    private func makeSession() throws -> FaceSession {
        try FaceSession(
            cacheDbPath: temp.appending("gallery-cache.sqlite").path,
            modelPackDir: try resourceDirectory("facepack").path
        )
    }

    /// Enqueue the staged library and run it to completion.
    @discardableResult
    private func scan(_ session: FaceSession) async throws -> FaceService.Summary {
        let paths = Self.stagedPhotos.map { temp.appending($0).path }
        _ = try session.enqueue(paths: paths)
        return await FaceRecorder().run(session)
    }

    /// The cluster with the most faces — for these fixtures, the one reaching
    /// more than one photo.
    private func biggestCluster(_ session: FaceSession) throws -> ClusterSummary {
        let clusters = try session.clusters()
            .sorted { ($0.size, $1.id) > ($1.size, $0.id) }
        return try XCTUnwrap(clusters.first, "the run produced no clusters")
    }

    private func sidecar(_ name: String) -> URL {
        temp.appending("\(name).xmp")
    }

    private func parsed(_ name: String) throws -> (rawTags: [String], countryCode: String?, faceRegions: [FaceRegion]) {
        MetadataReader.parseXMPBytes(try Data(contentsOf: sidecar(name)))
    }

    // MARK: - Availability

    /// The Phase 1 pack has no face models. That is a *valid* pack, and the
    /// distinct error variant is what lets the app hide the faces UI instead of
    /// reporting a broken install.
    func testAPackWithoutFaceModelsIsRefusedWithItsOwnError() throws {
        XCTAssertThrowsError(
            try FaceSession(
                cacheDbPath: temp.appending("gallery-cache.sqlite").path,
                modelPackDir: try resourceDirectory("testpack").path
            )
        ) { error in
            guard case FaceError.ModelsUnavailable = error else {
                return XCTFail("expected ModelsUnavailable, got \(error)")
            }
        }
        // And the inspector reports the same fact without opening a session,
        // which is how Settings decides whether to show "Scan Faces".
        let tagOnly = try inspectModelPack(modelPackDir: try resourceDirectory("testpack").path)
        XCTAssertFalse(tagOnly.hasFaces)
        let withFaces = try inspectModelPack(modelPackDir: try resourceDirectory("facepack").path)
        XCTAssertTrue(withFaces.hasFaces)
        XCTAssertEqual(withFaces.version, "gallery-ml-facepack-1")
    }

    // MARK: - Running

    func testARunFindsFacesAndProducesClustersWithExemplars() async throws {
        try stageLibrary()
        let session = try makeSession()
        XCTAssertFalse(session.isRunning())

        let recorder = FaceRecorder()
        let paths = Self.stagedPhotos.map { temp.appending($0).path }
        XCTAssertEqual(try session.enqueue(paths: paths), UInt32(paths.count))
        let summary = await recorder.run(session)

        XCTAssertNil(summary.failure)
        XCTAssertFalse(summary.cancelled)
        XCTAssertEqual(summary.processed, Self.stagedPhotos.count)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertGreaterThan(summary.facesFound, 0, "the fixtures contain faces")
        XCTAssertGreaterThan(summary.clustersCreated, 0)
        XCTAssertEqual(summary.facesAutoTagged, 0, "nothing is named yet, so nothing is written")
        XCTAssertEqual(summary.sidecarsWritten, 0)
        XCTAssertFalse(session.isRunning())

        // Progress: at least one report, always the same total, ending at 100%,
        // and exactly one onFinished.
        XCTAssertFalse(recorder.progressReports.isEmpty, "no progress callbacks fired")
        XCTAssertTrue(recorder.progressReports.allSatisfy { $0.total == Self.stagedPhotos.count })
        XCTAssertEqual(recorder.progressReports.last?.done, Self.stagedPhotos.count)
        XCTAssertEqual(recorder.finishedCount, 1)
        // Detections went into the cache; nothing on disk changed, so the two
        // path callbacks disagree — which is the whole reason they are separate.
        XCTAssertGreaterThan(recorder.photosWithFaces.count, 0)
        XCTAssertEqual(recorder.sidecarsWritten.count, 0)
        for name in Self.stagedPhotos {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sidecar(name).path),
                "\(name) gained a sidecar from a run that named nobody"
            )
        }

        let cluster = try biggestCluster(session)
        XCTAssertEqual(cluster.state, .unlabeled)
        XCTAssertNil(cluster.name)
        XCTAssertGreaterThan(cluster.size, 0)

        // Exemplars: capped, one per photo where possible, and each a usable
        // normalized rectangle the app's cover-crop path can consume.
        XCTAssertFalse(cluster.exemplars.isEmpty)
        XCTAssertLessThanOrEqual(cluster.exemplars.count, 4)
        // One per photo until the photos run out: four crops of one burst
        // answer nothing about whether the cluster is coherent.
        let photosInCluster = Set(try session.clusterFaces(clusterId: cluster.id).map(\.path))
        XCTAssertEqual(
            Set(cluster.exemplars.map(\.path)).count,
            min(cluster.exemplars.count, photosInCluster.count),
            "exemplars repeated a photo while another was available"
        )
        for exemplar in cluster.exemplars {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: exemplar.path),
                "exemplar points at a file that isn't there"
            )
            XCTAssertTrue((0...1).contains(exemplar.centerX), "\(exemplar)")
            XCTAssertTrue((0...1).contains(exemplar.centerY), "\(exemplar)")
            XCTAssertGreaterThan(exemplar.width, 0)
            XCTAssertGreaterThan(exemplar.height, 0)
        }

        // Every face of the cluster, unpaged, and at least as many as the card
        // shows.
        let faces = try session.clusterFaces(clusterId: cluster.id)
        XCTAssertEqual(faces.count, Int(cluster.size))
        XCTAssertGreaterThanOrEqual(faces.count, cluster.exemplars.count)
        // Ranked best-first, which is what makes the first one the cover.
        XCTAssertEqual(faces.map(\.quality), faces.map(\.quality).sorted(by: >))

        let stats = try session.libraryStats()
        XCTAssertGreaterThan(stats.faces, 0)
        XCTAssertEqual(stats.namedClusters, 0)
    }

    /// The exit criterion of Phase 2, in one test: naming a cluster puts a
    /// person into files the app's *existing* reader understands.
    func testNamingAClusterWritesPeopleTagsAndRegionsTheReaderUnderstands() async throws {
        try stageLibrary()
        let session = try makeSession()
        try await scan(session)

        let cluster = try biggestCluster(session)
        let touched = Set(try session.clusterFaces(clusterId: cluster.id).map(\.path))
        XCTAssertFalse(touched.isEmpty)

        let report = try session.nameCluster(clusterId: cluster.id, name: "Ada Lovelace", rootPrefix: nil)
        XCTAssertEqual(Int(report.written), touched.count, "\(report)")
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.failedPaths.isEmpty)

        for path in touched {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let sidecarURL = sidecar(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sidecarURL.path),
                "expected \(name).xmp"
            )
            let xmp = try parsed(name)
            XCTAssertTrue(
                xmp.rawTags.contains("People/Ada Lovelace"),
                "\(name): tags were \(xmp.rawTags)"
            )
            XCTAssertFalse(xmp.faceRegions.isEmpty, "\(name): no MWG region written")
            XCTAssertTrue(xmp.faceRegions.allSatisfy { $0.name == "Ada Lovelace" })
            for region in xmp.faceRegions {
                XCTAssertTrue((0...1).contains(region.centerX), "\(region)")
                XCTAssertGreaterThan(region.width, 0)
            }
        }

        // The cluster row says so too, so the review UI can stop offering it.
        let named = try XCTUnwrap(try session.clusters().first { $0.id == cluster.id })
        XCTAssertEqual(named.state, .named)
        XCTAssertEqual(named.name, "Ada Lovelace")
        XCTAssertEqual(try session.libraryStats().namedClusters, 1)

        // Photos the cluster never reached are untouched — naming one person
        // must not create a sidecar next to every photo in the library.
        for name in Self.stagedPhotos where !touched.contains(temp.appending(name).path) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sidecar(name).path),
                "\(name) got a sidecar it should not have"
            )
        }
    }

    /// Un-naming takes back what the core wrote and leaves everything else
    /// alone — the preservation contract, seen from the app's own reader.
    func testUnNamingRemovesOnlyWhatTheCoreWrote() async throws {
        try stageLibrary()
        let session = try makeSession()
        try await scan(session)

        let cluster = try biggestCluster(session)
        let target = URL(
            fileURLWithPath: try XCTUnwrap(
                try session.clusterFaces(clusterId: cluster.id).first?.path
            )
        ).lastPathComponent

        // A hand-written sidecar carrying somebody else's work.
        try Data("""
        <?xpacket begin='' id='W5M0Mp'?>
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
        <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
         <rdf:Description rdf:about=''
          xmlns:digiKam='http://www.digikam.org/ns/1.0/'
          xmlns:phototools='https://github.com/j23n/photo-tools/ns/1.0/'>
          <digiKam:TagsList><rdf:Seq><rdf:li>People/Zoe</rdf:li>\
        <rdf:li>Places/Italy/Rome</rdf:li></rdf:Seq></digiKam:TagsList>
          <phototools:CountryCode>IT</phototools:CountryCode>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end='w'?>
        """.utf8).write(to: sidecar(target))

        _ = try session.nameCluster(clusterId: cluster.id, name: "Ada", rootPrefix: nil)
        let named = try parsed(target)
        XCTAssertTrue(named.rawTags.contains("People/Ada"))
        XCTAssertTrue(named.rawTags.contains("People/Zoe"))
        XCTAssertEqual(named.countryCode, "IT")

        let report = try session.unnameCluster(clusterId: cluster.id, rootPrefix: nil)
        XCTAssertGreaterThan(report.written, 0, "\(report)")

        let cleared = try parsed(target)
        XCTAssertFalse(cleared.rawTags.contains("People/Ada"), "our person survived un-naming")
        XCTAssertTrue(cleared.rawTags.contains("People/Zoe"), "somebody else's person was removed")
        XCTAssertTrue(
            cleared.rawTags.contains("Places/Italy/Rome"),
            "an unrelated keyword was removed"
        )
        XCTAssertEqual(cleared.countryCode, "IT", "a foreign photo-tools field was removed")
        XCTAssertTrue(
            cleared.faceRegions.filter { $0.name == "Ada" }.isEmpty,
            "our region survived un-naming"
        )

        let back = try XCTUnwrap(try session.clusters().first { $0.id == cluster.id })
        XCTAssertEqual(back.state, .unlabeled, "an un-named cluster rejoins the review queue")
    }

    func testIgnoringAClusterKeepsItOutOfTheReviewQueue() async throws {
        try stageLibrary()
        let session = try makeSession()
        try await scan(session)
        let cluster = try biggestCluster(session)

        _ = try session.ignoreCluster(clusterId: cluster.id, rootPrefix: nil)
        let dismissed = try XCTUnwrap(try session.clusters().first { $0.id == cluster.id })
        XCTAssertEqual(dismissed.state, .ignored)
        XCTAssertNil(dismissed.name)
        XCTAssertEqual(try session.libraryStats().ignoredClusters, 1)
    }

    /// A name a user can type but nobody can use has to come back as its own
    /// case, so the review screen can put it next to the field.
    func testAnUnusableNameIsRefusedAsInvalidNameNotAsAWriteFailure() async throws {
        try stageLibrary()
        let session = try makeSession()
        try await scan(session)
        let cluster = try biggestCluster(session)

        for bad in ["", "   ", "People/Ada"] {
            XCTAssertThrowsError(
                try session.nameCluster(clusterId: cluster.id, name: bad, rootPrefix: nil), bad
            ) { error in
                guard case FaceError.InvalidName = error else {
                    return XCTFail("expected InvalidName for \(bad.debugDescription), got \(error)")
                }
            }
        }
        let untouched = try XCTUnwrap(try session.clusters().first { $0.id == cluster.id })
        XCTAssertEqual(untouched.state, .unlabeled, "a rejected name changed the cluster")
    }

    func testNamingAClusterThatIsGoneIsATypedError() async throws {
        try stageLibrary()
        let session = try makeSession()
        try await scan(session)

        XCTAssertThrowsError(try session.nameCluster(clusterId: 9_999, name: "Ada", rootPrefix: nil)) { error in
            guard case FaceError.ClusterNotFound(let id) = error else {
                return XCTFail("expected ClusterNotFound, got \(error)")
            }
            XCTAssertEqual(id, 9_999)
        }
    }

    /// Deterministic, with no sleeps and no polling: the gate listener parks a
    /// core worker thread *inside* `onProgress` and only lets the test proceed
    /// once it is provably there.
    func testASecondStartWhileRunningIsRejectedAndNamingIsRefused() throws {
        try stageLibrary()
        let session = try makeSession()
        _ = try session.enqueue(paths: Self.stagedPhotos.map { temp.appending($0).path })

        let gate = GatedFaceListener()
        try session.start(progress: gate, rootPrefix: nil)

        XCTAssertEqual(
            gate.entered.wait(timeout: .now() + 30), .success,
            "the run never reached a progress callback"
        )
        XCTAssertTrue(session.isRunning(), "a parked worker means the run is in flight")

        XCTAssertThrowsError(try session.start(progress: GatedFaceListener(), rootPrefix: nil)) { error in
            guard case FaceError.AlreadyRunning = error else {
                return XCTFail("expected AlreadyRunning, got \(error)")
            }
        }

        // Everything that writes is refused for the duration rather than
        // racing the run's own auto-tag pass over the same cluster table.
        let refusals: [(String, () throws -> Void)] = [
            ("nameCluster", { _ = try session.nameCluster(clusterId: 1, name: "Ada", rootPrefix: nil) }),
            ("unnameCluster", { _ = try session.unnameCluster(clusterId: 1, rootPrefix: nil) }),
            ("ignoreCluster", { _ = try session.ignoreCluster(clusterId: 1, rootPrefix: nil) }),
            ("renamePerson", { _ = try session.renamePerson(old: "Ada", new: "Grace", rootPrefix: nil) }),
            ("recluster", { _ = try session.recluster() }),
            ("resetQueue", { try session.resetQueue() }),
        ]
        for (label, call) in refusals {
            XCTAssertThrowsError(try call(), label) { error in
                guard case FaceError.AlreadyRunning = error else {
                    return XCTFail("\(label): expected AlreadyRunning, got \(error)")
                }
            }
        }
        // Reads are still allowed — a review screen must not go blank for the
        // length of a scan.
        XCTAssertNoThrow(try session.clusters())

        gate.release.signal()
        XCTAssertEqual(gate.finished.wait(timeout: .now() + 60), .success)
        XCTAssertFalse(session.isRunning())
        // And the session is not wedged: what was refused now works.
        XCTAssertNoThrow(try session.recluster())
    }

    /// A run confined to a root must not touch queue rows from another one —
    /// the core's cache DB is one file per app keyed by absolute path, so it
    /// outlives any library root the user picks.
    func testARunScopedToARootLeavesOtherRootsAlone() async throws {
        let fixtures = try resourceDirectory("fixtures")
        let current = temp.appending("Current", isDirectory: true)
        let previous = temp.appending("Previous", isDirectory: true)
        for dir in [current, previous] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("face_bright.png"),
            to: current.appendingPathComponent("face_bright.png")
        )
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("face_mid.png"),
            to: previous.appendingPathComponent("face_mid.png")
        )

        let session = try makeSession()
        _ = try session.enqueue(paths: [
            current.appendingPathComponent("face_bright.png").path,
            previous.appendingPathComponent("face_mid.png").path,
        ])

        let summary = await FaceRecorder().run(session, rootPrefix: current.path)
        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(summary.failed, 0)

        // Out of scope is not a failure: the row waits, retry budget intact.
        let stats = try session.stats()
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.failed, 0)
        // And nothing in the other root can have been reached by a naming,
        // because its faces were never detected.
        for face in try session.clusters().flatMap(\.exemplars) {
            XCTAssertTrue(
                face.path.hasPrefix(current.path),
                "a run scoped to one root detected a face in another"
            )
        }
    }
}

// MARK: - Recorder

/// A `FaceProgressListener` that records what the core reported and resumes a
/// continuation when the run ends.
///
/// `Sendable` without `@unchecked`: every stored property is either a `let` of
/// a Sendable type or lives behind a `Mutex`. The core calls these methods from
/// its own worker threads, which is exactly the situation the app's
/// `FaceProgressBridge` is in.
private final class FaceRecorder: FaceProgressListener, Sendable {
    struct Report: Sendable, Equatable {
        var done: Int
        var total: Int
    }

    private struct State {
        var progress: [Report] = []
        var withFaces: [String] = []
        var sidecars: [String] = []
        var finished = 0
        var continuation: CheckedContinuation<FaceService.Summary, Never>?
    }

    private let state = Mutex(State())

    var progressReports: [Report] { state.withLock { $0.progress } }
    var photosWithFaces: [String] { state.withLock { $0.withFaces } }
    var sidecarsWritten: [String] { state.withLock { $0.sidecars } }
    var finishedCount: Int { state.withLock { $0.finished } }

    /// Start `session` and await its `onFinished`.
    func run(_ session: FaceSession, rootPrefix: String? = nil) async -> FaceService.Summary {
        await withCheckedContinuation { (continuation: CheckedContinuation<FaceService.Summary, Never>) in
            state.withLock { $0.continuation = continuation }
            do {
                try session.start(progress: self, rootPrefix: rootPrefix)
            } catch {
                let pending = state.withLock { state -> CheckedContinuation<FaceService.Summary, Never>? in
                    defer { state.continuation = nil }
                    return state.continuation
                }
                pending?.resume(returning: FaceService.Summary(
                    failure: FaceServiceError(error)
                ))
            }
        }
    }

    func onProgress(done: UInt32, total: UInt32) {
        state.withLock { $0.progress.append(Report(done: Int(done), total: Int(total))) }
    }

    func onPhotosWithFaces(paths: [String]) {
        state.withLock { $0.withFaces.append(contentsOf: paths) }
    }

    func onSidecarsWritten(paths: [String]) {
        state.withLock { $0.sidecars.append(contentsOf: paths) }
    }

    func onFinished(summary: FaceRunSummary) {
        let converted = FaceService.Summary(
            processed: Int(summary.processed),
            photosWithFaces: Int(summary.photosWithFaces),
            facesFound: Int(summary.facesFound),
            cacheHits: Int(summary.cacheHits),
            skipped: Int(summary.skipped),
            failed: Int(summary.failed),
            facesAssigned: Int(summary.facesAssigned),
            clustersCreated: Int(summary.clustersCreated),
            facesAutoTagged: Int(summary.facesAutoTagged),
            sidecarsWritten: Int(summary.sidecarsWritten),
            cancelled: summary.cancelled,
            failure: summary.failure.map(FaceServiceError.init)
        )
        let continuation = state.withLock { state -> CheckedContinuation<FaceService.Summary, Never>? in
            state.finished += 1
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: converted)
    }
}

/// Parks the first core worker that reaches `onProgress` until the test lets it
/// go, turning "is the run observably in flight?" into a fact rather than a
/// timing guess.
private final class GatedFaceListener: FaceProgressListener, Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let parked = Mutex(false)

    func onProgress(done: UInt32, total: UInt32) {
        let first = parked.withLock { parked -> Bool in
            defer { parked = true }
            return !parked
        }
        guard first else { return }
        entered.signal()
        release.wait()
    }

    func onPhotosWithFaces(paths: [String]) {}
    func onSidecarsWritten(paths: [String]) {}

    func onFinished(summary: FaceRunSummary) {
        finished.signal()
    }
}
