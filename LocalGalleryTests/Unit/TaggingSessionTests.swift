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
/// for: the tag sets asserted here are the ones `engine_e2e.rs` asserts on
/// `aarch64-apple-darwin`.
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

    /// Tags the committed pack produces for the committed fixtures — pinned
    /// in `core/gallery-ml/tests/engine_e2e.rs` too. Sorted, because the
    /// sidecar's ordering is the writer's business, not this test's.
    private static let expectedTags: [String: [String]] = [
        "gradient.jpg": [
            "Objects/Animal/Dog",
            "Objects/Vehicle/Car",
            "Scenes/Nature/Forest",
        ],
        "stripes.jpg": ["Scenes/Urban/Street"],
    ]

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
        let names = Self.expectedTags.keys.sorted()
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
        return MetadataReader.parseXMPBytes(data).rawTags.sorted()
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
            XCTAssertEqual(try tags(in: sidecar), Self.expectedTags[name])
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
            XCTAssertEqual(try tags(in: temp.appending("\(name).xmp")), Self.expectedTags[name])
        }
    }

    func testASecondStartWhileRunningIsRejected() async throws {
        let names = try stageLibrary()
        let session = try makeSession()
        _ = try session.enqueue(paths: names.map { temp.appending($0).path })

        // Hold the run open from inside `onProgress` so the second `start`
        // provably lands mid-run rather than racing a two-photo pipeline.
        let gate = TaggingRecorder(holdFirstProgressFor: .milliseconds(400))
        async let summary = gate.run(session)

        var rejected = false
        for _ in 0..<40 where !rejected {
            if session.isRunning() {
                do {
                    try session.start(progress: TaggingRecorder())
                } catch TaggingError.AlreadyRunning {
                    rejected = true
                } catch {
                    XCTFail("expected AlreadyRunning, got \(error)")
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = await summary
        XCTAssertTrue(rejected, "a second start never saw a running session")
    }

    func testEligibilityMirrorsTheEnrichmentRule() {
        XCTAssertTrue(TaggingService.isEligible(.fixture(url: URL(fileURLWithPath: "/l/a.jpg"))))

        var video = PhotoFile.fixture(url: URL(fileURLWithPath: "/l/a.mov"), isVideo: true)
        XCTAssertFalse(TaggingService.isEligible(video))
        video.isVideo = false
        XCTAssertTrue(TaggingService.isEligible(video))

        var placeholder = PhotoFile.fixture(url: URL(fileURLWithPath: "/l/b.jpg"))
        placeholder.locality = .remote(downloaded: false)
        XCTAssertFalse(TaggingService.isEligible(placeholder), "a placeholder has no bytes")
        placeholder.locality = .remote(downloaded: true)
        XCTAssertTrue(TaggingService.isEligible(placeholder))
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
    /// Blocks the first `onProgress` callback for this long, to keep a run
    /// observably in flight. Zero by default.
    private let hold: Duration

    init(holdFirstProgressFor hold: Duration = .zero) {
        self.hold = hold
    }

    var progressReports: [Report] { state.withLock { $0.progress } }
    var taggedPathCount: Int { state.withLock { $0.taggedPaths.count } }
    var finishedCount: Int { state.withLock { $0.finished } }

    /// Start `session` and await its `onFinished`.
    func run(_ session: TaggingSession) async -> TaggingService.Summary {
        await withCheckedContinuation { (continuation: CheckedContinuation<TaggingService.Summary, Never>) in
            state.withLock { $0.continuation = continuation }
            do {
                try session.start(progress: self)
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
        let first = state.withLock { state -> Bool in
            state.progress.append(Report(done: Int(done), total: Int(total)))
            return state.progress.count == 1
        }
        if first, hold > .zero {
            // Deliberately blocking: this runs on a core worker thread, and
            // the point is to keep the run alive while the test pokes at it.
            Thread.sleep(forTimeInterval: Double(hold.components.seconds)
                + Double(hold.components.attoseconds) / 1e18)
        }
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
