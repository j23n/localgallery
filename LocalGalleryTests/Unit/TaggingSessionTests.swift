import Foundation
import Synchronization
import XCTest
@testable import LocalGallery

/// End-to-end cover for the Phase 1 FFI: a real `TaggingSession`, the real
/// ONNX Runtime, the committed test model pack, and real `.xmp` sidecars
/// written to a temp directory.
///
/// The pack and the image fixtures are the *same files* `cargo test` uses
/// (`core/gallery-ml/tests/`, referenced as folder resources in project.yml),
/// so this suite is also the cross-target determinism check the plan asks
/// for — and so are the expectations: both suites read the tag sets out of
/// `fixtures/expected_tags.json` rather than each restating them, which is
/// what stops an arm64-simulator drift from being quietly fixed up in
/// whichever copy someone noticed first.
///
/// If these fail, suspect the build chain first:
/// `./scripts/build_core.sh && xcodegen`.
final class TaggingSessionTests: XCTestCase {
    private var temp: TempDir!

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

    /// The shared expectations file, decoded.
    private struct ExpectedTags: Decodable {
        var packVersion: String
        var tags: [String: [String]]

        enum CodingKeys: String, CodingKey {
            case packVersion = "pack_version"
            case tags
        }
    }

    /// Tags the committed pack produces for the committed fixtures, read from
    /// the file `core/gallery-ml/tests/engine_e2e.rs` reads. Sorted, because
    /// the sidecar's ordering is the writer's business, not this test's.
    private func expectedTags() throws -> [String: [String]] {
        let url = try resourceDirectory("fixtures").appendingPathComponent("expected_tags.json")
        let decoded = try JSONDecoder().decode(ExpectedTags.self, from: try Data(contentsOf: url))
        XCTAssertEqual(
            decoded.packVersion, "gallery-ml-testpack-1",
            "expected_tags.json describes a different pack than the committed one"
        )
        return decoded.tags.mapValues { $0.sorted() }
    }

    /// The image fixtures this suite stages. `meadow.png` is covered on the
    /// Rust side; two photos are enough to exercise batching here and keep the
    /// simulator run short.
    private static let stagedPhotos = ["gradient.jpg", "stripes.jpg"]

    private func resourceDirectory(_ name: String) throws -> URL {
        let bundle = Bundle(for: TaggingSessionTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: nil),
            "\(name)/ is missing from the test bundle — check the folder reference in project.yml"
        )
        return url
    }

    /// Copy the fixture images into the temp dir. Sidecars land next to the
    /// photo, so the library has to be writable.
    @discardableResult
    private func stageLibrary() throws -> [String] {
        let fixtures = try resourceDirectory("fixtures")
        let names = Self.stagedPhotos.sorted()
        for name in names {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name),
                to: temp.appending(name)
            )
        }
        return names
    }

    private func makeSession() throws -> TaggingSession {
        try TaggingSession(
            cacheDbPath: temp.appending("gallery-cache.sqlite").path,
            modelPackDir: try resourceDirectory("testpack").path
        )
    }

    private func tags(in sidecar: URL) throws -> [String] {
        let data = try Data(contentsOf: sidecar)
        return parseXmpBytes(bytes: data).rawTags.sorted()
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
    }

    // MARK: - Tests

    func testModelPackInspectionReportsTheCommittedPack() throws {
        let info = try inspectModelPack(modelPackDir: try resourceDirectory("testpack").path)
        XCTAssertEqual(info.version, "gallery-ml-testpack-1")
        XCTAssertEqual(info.labelCount, 6)
        XCTAssertEqual(info.embeddingDim, 64)
        XCTAssertEqual(info.inputSize, 64)
    }

    func testInspectingANonPackDirectoryThrowsATypedError() {
        XCTAssertThrowsError(try inspectModelPack(modelPackDir: temp.url.path)) { error in
            guard case TaggingError.PackFileMissing = error else {
                return XCTFail("expected PackFileMissing, got \(error)")
            }
        }
    }

    func testARunWritesSidecarsWithTheExpectedTags() async throws {
        let names = try stageLibrary()
        let expected = try expectedTags()
        let session = try makeSession()

        XCTAssertEqual(session.modelPackInfo().version, "gallery-ml-testpack-1")
        XCTAssertFalse(session.isRunning())

        let inserted = try session.enqueue(paths: names.map { temp.appending($0).path })
        XCTAssertEqual(inserted, UInt32(names.count))

        let recorder = TaggingRecorder()
        let summary = await recorder.run(session)

        XCTAssertNil(summary.failure)
        XCTAssertFalse(summary.cancelled)
        XCTAssertEqual(summary.processed, names.count)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.cacheHits, 0, "a cold cache cannot hit")
        XCTAssertEqual(summary.sidecarsWritten, names.count)
        XCTAssertFalse(session.isRunning())

        // Sidecars are suffix-preserved: `gradient.jpg.xmp`, never
        // `gradient.xmp` (xmp-schema.md §1.4).
        for name in names {
            let sidecar = temp.appending("\(name).xmp")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sidecar.path),
                "expected \(name).xmp"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: temp.appending("\((name as NSString).deletingPathExtension).xmp").path
                ),
                "sidecar name must preserve the photo's extension"
            )
            XCTAssertEqual(try tags(in: sidecar), expected[name])
        }

        // Progress callbacks: at least one, always against the same total,
        // finishing at 100%, and exactly one `onFinished`.
        let progress = recorder.progressReports
        XCTAssertFalse(progress.isEmpty, "no progress callbacks fired")
        XCTAssertTrue(progress.allSatisfy { $0.total == names.count })
        XCTAssertEqual(progress.last?.done, names.count)
        XCTAssertEqual(recorder.finishedCount, 1)
        XCTAssertEqual(recorder.taggedPathCount, names.count)
    }

    func testRerunningOverUnchangedPhotosWritesNothing() async throws {
        let names = try stageLibrary()
        let expected = try expectedTags()
        let session = try makeSession()
        _ = try session.enqueue(paths: names.map { temp.appending($0).path })
        _ = await TaggingRecorder().run(session)

        let sidecars = names.map { temp.appending("\($0).xmp") }
        let before = try sidecars.map { try modificationDate($0) }

        // A second `start` over a queue that is already `done` would process
        // nothing at all, which proves the queue works and nothing else.
        // Resetting the queue puts every photo back in play, so the run
        // exercises hash → embedding-cache hit → tagger → writer and still
        // has to conclude "no change, don't touch the file".
        try session.resetQueue()
        _ = try session.enqueue(paths: names.map { temp.appending($0).path })
        let recorder = TaggingRecorder()
        let summary = await recorder.run(session)

        XCTAssertEqual(summary.processed, names.count)
        XCTAssertEqual(summary.cacheHits, names.count, "embeddings should come from the cache")
        XCTAssertEqual(summary.sidecarsWritten, 0, "an unchanged sidecar must not be rewritten")
        XCTAssertEqual(recorder.taggedPathCount, 0)

        let after = try sidecars.map { try modificationDate($0) }
        XCTAssertEqual(before, after, "sidecar mtimes moved on a no-op run")

        for name in names {
            XCTAssertEqual(try tags(in: temp.appending("\(name).xmp")), expected[name])
        }
    }

    /// Deterministic, with no sleeps and no polling: the gate listener parks a
    /// core worker thread *inside* `onProgress` and only lets the test proceed
    /// once it is provably there.
    func testASecondStartWhileRunningIsRejected() throws {
        let names = try stageLibrary()
        let session = try makeSession()
        _ = try session.enqueue(paths: names.map { temp.appending($0).path })

        let gate = GatedListener()
        try session.start(progress: gate, rootPrefix: nil)

        XCTAssertEqual(
            gate.entered.wait(timeout: .now() + 30), .success,
            "the run never reached a progress callback"
        )
        XCTAssertTrue(session.isRunning(), "a parked worker means the run is in flight")

        XCTAssertThrowsError(try session.start(progress: GatedListener(), rootPrefix: nil)) { error in
            guard case TaggingError.AlreadyRunning = error else {
                return XCTFail("expected AlreadyRunning, got \(error)")
            }
        }
        // Resetting the queue is refused mid-run for the same reason and by
        // the same flag: workers would be finishing rows that no longer exist.
        XCTAssertThrowsError(try session.resetQueue())

        gate.release.signal()
        XCTAssertEqual(gate.finished.wait(timeout: .now() + 60), .success)
        XCTAssertFalse(session.isRunning())
    }

    /// A run confined to a root must not touch queue rows from another one.
    ///
    /// The core's cache DB is one file per app keyed by absolute path, so it
    /// outlives any library root the user picks; without the scope, switching
    /// folders leaves the old root's photos being tagged behind the user's
    /// back.
    func testARunScopedToARootLeavesOtherRootsAlone() async throws {
        let fixtures = try resourceDirectory("fixtures")
        let current = temp.appending("Current", isDirectory: true)
        let previous = temp.appending("Previous", isDirectory: true)
        for dir in [current, previous] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("gradient.jpg"),
            to: current.appendingPathComponent("gradient.jpg")
        )
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("stripes.jpg"),
            to: previous.appendingPathComponent("stripes.jpg")
        )

        let session = try makeSession()
        _ = try session.enqueue(paths: [
            current.appendingPathComponent("gradient.jpg").path,
            previous.appendingPathComponent("stripes.jpg").path,
        ])

        let recorder = TaggingRecorder()
        let summary = await recorder.run(session, rootPrefix: current.path)

        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("gradient.jpg.xmp").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: previous.appendingPathComponent("stripes.jpg.xmp").path
            ),
            "a run scoped to one root tagged a photo in another"
        )
        // Out of scope is not a failure: the row waits, retry budget intact,
        // for a run over that root.
        let stats = try session.stats()
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.failed, 0)
    }

    /// Tagging's eligibility rule is *not* the enrichment rule restated — the
    /// two agree on placeholders and disagree on videos. Asserted against what
    /// `EnrichmentService` actually does, so the day one of them changes this
    /// fails rather than quietly drifting.
    func testTaggingExcludesVideosThatEnrichmentStillProcesses() async throws {
        let fixtures = try resourceDirectory("fixtures")
        let photoURL = temp.appending("gradient.jpg")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("gradient.jpg"), to: photoURL
        )
        // Enrichment reads a video's date through AVAsset and falls back to
        // filesystem dates when that fails, so an unplayable file is enough to
        // observe that it went down the video path rather than being skipped.
        let videoURL = temp.appending("clip.mov")
        try Data("not really a movie".utf8).write(to: videoURL)
        let placeholderURL = temp.appending("cloud.jpg")

        let photo = PhotoFile.fixture(url: photoURL)
        let video = PhotoFile.fixture(url: videoURL, isVideo: true)
        var placeholder = PhotoFile.fixture(url: placeholderURL)
        placeholder.locality = .remote(downloaded: false)

        let enriched = await EnrichmentService.enrich(photos: [photo, video, placeholder])
        XCTAssertEqual(enriched.count, 3)

        // Ordinary local photo: both take it.
        XCTAssertTrue(TaggingService.isEligible(photo))
        XCTAssertNotNil(enriched[0].dateTaken, "enrichment skipped a local photo")

        // Video: enrichment processes it (it came back with a date), tagging
        // refuses it — the core has no frame sampler on iOS.
        XCTAssertNotNil(
            enriched[1].dateTaken,
            "enrichment no longer dates videos — the divergence this test documents has moved"
        )
        XCTAssertFalse(TaggingService.isEligible(video))

        // Placeholder: neither reads its (non-existent) bytes. Enrichment
        // marks it done-for-now without a date; tagging refuses it outright so
        // it cannot burn a retry.
        XCTAssertNil(enriched[2].dateTaken)
        XCTAssertNotNil(enriched[2].enrichedFileDate, "the placeholder must still be marked")
        XCTAssertFalse(TaggingService.isEligible(placeholder))

        // And a placeholder whose bytes have landed rejoins both.
        var downloaded = placeholder
        downloaded.locality = .remote(downloaded: true)
        XCTAssertTrue(TaggingService.isEligible(downloaded))
    }

    /// Pack directories are named for their version, and versions have
    /// multi-digit components. A plain string sort ranks `1.9` above `1.10`.
    ///
    /// The rule itself now spans two roots (bundled and imported) and lives in
    /// `PackResolverTests`; this checks that the imported root alone still
    /// answers the way it always did.
    func testPackSelectionOrdersVersionsNumerically() throws {
        let packs = temp.appending("ModelPacks", isDirectory: true)
        for name in ["mobileclip-1.9", "mobileclip-1.10", "mobileclip-1.2"] {
            let dir = packs.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        }
        // A directory with no manifest is not a pack, however it sorts.
        let decoy = packs.appendingPathComponent("mobileclip-9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        let resolved = PackResolver.resolve(
            bundled: [], imported: PackResolver.candidates(in: packs)
        )
        XCTAssertEqual(resolved?.directory.lastPathComponent, "mobileclip-1.10")
        XCTAssertEqual(resolved?.source, .imported)
    }
}

// MARK: - Recorder

/// A `TaggingProgressListener` that records what the core reported and
/// resumes a continuation when the run ends.
///
/// `Sendable` without `@unchecked`: every stored property is either a `let` of
/// a Sendable type or lives behind a `Mutex`. The core calls these methods
/// from its own worker threads, which is exactly the situation the app's
/// `ProgressBridge` is in.
private final class TaggingRecorder: TaggingProgressListener, Sendable {
    struct Report: Sendable, Equatable {
        var done: Int
        var total: Int
    }

    private struct State {
        var progress: [Report] = []
        var taggedPaths: [String] = []
        var finished = 0
        var continuation: CheckedContinuation<TaggingService.Summary, Never>?
    }

    private let state = Mutex(State())

    var progressReports: [Report] { state.withLock { $0.progress } }
    var taggedPathCount: Int { state.withLock { $0.taggedPaths.count } }
    var finishedCount: Int { state.withLock { $0.finished } }

    /// Start `session` and await its `onFinished`.
    func run(_ session: TaggingSession, rootPrefix: String? = nil) async -> TaggingService.Summary {
        await withCheckedContinuation { (continuation: CheckedContinuation<TaggingService.Summary, Never>) in
            state.withLock { $0.continuation = continuation }
            do {
                try session.start(progress: self, rootPrefix: rootPrefix)
            } catch {
                let pending = state.withLock { state -> CheckedContinuation<TaggingService.Summary, Never>? in
                    defer { state.continuation = nil }
                    return state.continuation
                }
                pending?.resume(returning: TaggingService.Summary(
                    failure: TaggingServiceError(error)
                ))
            }
        }
    }

    func onProgress(done: UInt32, total: UInt32) {
        state.withLock { $0.progress.append(Report(done: Int(done), total: Int(total))) }
    }

    func onPhotosTagged(paths: [String]) {
        state.withLock { $0.taggedPaths.append(contentsOf: paths) }
    }

    func onFinished(summary: TaggingRunSummary) {
        let converted = TaggingService.Summary(
            processed: Int(summary.processed),
            tagged: Int(summary.tagged),
            sidecarsWritten: Int(summary.sidecarsWritten),
            cacheHits: Int(summary.cacheHits),
            skipped: Int(summary.skipped),
            failed: Int(summary.failed),
            cancelled: summary.cancelled,
            failure: summary.failure.map(TaggingServiceError.init)
        )
        let continuation = state.withLock { state -> CheckedContinuation<TaggingService.Summary, Never>? in
            state.finished += 1
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: converted)
    }
}

/// Parks the first core worker that reaches `onProgress` until the test lets
/// it go.
///
/// This is what turns "is the run observably in flight?" into a fact rather
/// than a timing guess: `entered` is signalled from inside the callback, so
/// when the test wakes, a worker thread is demonstrably sitting in the middle
/// of the run. Blocking a core worker is legal here for the same reason it is
/// a bad idea in the app — the contract asks listeners to return promptly, and
/// the only cost of ignoring it is that the run pauses.
private final class GatedListener: TaggingProgressListener, Sendable {
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

    func onPhotosTagged(paths: [String]) {}

    func onFinished(summary: TaggingRunSummary) {
        finished.signal()
    }
}
