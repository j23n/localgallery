import Foundation
import XCTest
@testable import LocalGallery

/// The Swift half of the Phase-3 scanner: the provider probe's fan-out, the
/// path↔URL bridge, and the fact that Swift and Rust agree on the persisted
/// snapshot at *runtime* rather than only against a committed fixture.
///
/// `ScannerConformanceTests` covers what the scanner produces. This covers the
/// seams around it, which the conformance fixture cannot see because it runs on
/// a plain local volume where every provider answer is the default.
final class CoreScannerBridgeTests: XCTestCase {

    private var temp: TempDir!

    override func setUp() {
        super.setUp()
        temp = TempDir.make()
    }

    override func tearDown() {
        temp?.teardown()
        temp = nil
        super.tearDown()
    }

    // MARK: - The probe fan-out

    /// Parallel probes, serial emission. The batch is striped across threads
    /// and reassembled positionally, so the answer for `paths[i]` is at `[i]`
    /// however the stripes interleaved — which is the only reason the scan can
    /// be both fanned out and deterministic.
    func testProbeAnswersStayInInputOrderUnderConcurrency() throws {
        // Enough files to cross the fan-out threshold several times over, with
        // distinguishable contents so a mis-ordered answer is visible.
        let count = 200
        var paths: [String] = []
        for i in 0..<count {
            let url = temp.appending("f\(i).bin")
            try Data(repeating: 0x41, count: i + 1).write(to: url)
            paths.append(url.path)
        }

        let probe = CoreProviderProbe()
        let answers = probe.probe(paths: paths)
        XCTAssertEqual(answers.count, count, "one row per path, always")

        // Nothing here is provider-backed, so the *values* are uniform; what
        // the ordering claim needs is that repeated runs agree with each other
        // and with a serial baseline.
        let serial = paths.map { path -> VfsProviderAttrs in
            let r = FileProviderDetector.probe(URL(fileURLWithPath: path))
            return VfsProviderAttrs(isFileProvider: r.isFileProvider,
                                    isPlaceholder: r.status != .local,
                                    contentVersion: r.version.contentIdentifier)
        }
        XCTAssertEqual(answers, serial, "the fanned-out batch disagreed with a serial pass")

        // …and the content identifiers are per-file, so a shuffle would show.
        let identifiers = answers.compactMap(\.contentVersion)
        XCTAssertEqual(identifiers.count, count, "APFS should vend an identifier for every file")
        XCTAssertEqual(Set(identifiers).count, count, "identifiers must be distinct per file")
        for _ in 0..<3 {
            XCTAssertEqual(probe.probe(paths: paths), answers, "repeated batches disagreed")
        }
    }

    /// A batch below the fan-out threshold takes the serial path — most
    /// directories in a real library hold a handful of files and a thread hop
    /// would cost more than it saves. Both paths must answer identically.
    func testATinyBatchAnswersTheSameAsALargeOne() throws {
        let url = temp.appending("solo.jpg")
        try Data("x".utf8).write(to: url)
        let probe = CoreProviderProbe()
        let one = probe.probe(paths: [url.path])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(probe.probe(paths: Array(repeating: url.path, count: 64)).first, one.first)
    }

    func testAnEmptyBatchIsAnEmptyAnswer() {
        XCTAssertTrue(CoreProviderProbe().probe(paths: []).isEmpty)
    }

    /// A path that cannot be read is a plain local file, not a thrown batch.
    /// The baseline's `try?` did the same, and a probe failure must never make
    /// a photo disappear.
    func testAnUnreadablePathDegradesToLocal() {
        let answers = CoreProviderProbe().probe(paths: ["/definitely/not/here.jpg"])
        XCTAssertEqual(answers, [VfsProviderAttrs(isFileProvider: false, isPlaceholder: false,
                                                  contentVersion: nil)])
    }

    // MARK: - The path bridge

    /// `URL(fileURLWithPath:)` DECOMPOSES its input (`PathNormalizationTests`),
    /// so using it to rebuild a URL from the core's path string would give an
    /// externally-created NFC file a different `stableID` than the core just
    /// derived — a silent identity split. Compared on `unicodeScalars`, because
    /// `String ==` is canonical equivalence and could never see it.
    func testFileURLPreservesTheOnDiskSpelling() {
        let nfc = "/lib/café.jpg".precomposedStringWithCanonicalMapping
        let nfd = "/lib/café.jpg".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars), "vacuous otherwise")

        for path in [nfc, nfd, "/lib/spaces and (parens).jpg", "/lib/emoji 🌵 cactus.jpg",
                     "/lib/hash#and?query.jpg", "/lib/plain.jpg"] {
            let url = CoreScanner.fileURL(path)
            XCTAssertTrue(url.isFileURL, path)
            XCTAssertEqual(Array(url.path.unicodeScalars), Array(path.unicodeScalars),
                           "path round trip changed the scalars for \(path)")
            XCTAssertEqual(PhotoFile.stableID(for: url), StableUUID.derive(from: path))
        }

        XCTAssertNotEqual(
            Array(URL(fileURLWithPath: nfc).path.unicodeScalars), Array(nfc.unicodeScalars),
            "if this ever starts preserving, the fast constructor becomes usable again"
        )
    }

    // MARK: - Snapshot agreement

    /// The committed fixture pins the wire format statically. This pins it
    /// *dynamically*: what `JSONDiskCache` writes today, the core reads today,
    /// and vice versa. A serde change that the fixture happened not to cover
    /// would turn every warm relaunch into a full rescan, silently.
    @MainActor
    func testSwiftAndRustAgreeOnTheSnapshotAtRuntime() async throws {
        let root = temp.appending("Library", isDirectory: true)
        for (rel, size) in [("a.jpg", 10), ("Sub/b.jpg", 11), ("Sub/b.jpg.xmp", 12)] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: size).write(to: url)
        }
        let scanned = await CoreScanner().scan(at: root, reuseCached: false)
        let snapshot = LibrarySnapshot(
            rootFolder: try XCTUnwrap(scanned.rootFolder),
            allPhotos: scanned.flatPhotos,
            sidecarManifest: scanned.sidecarManifest
        )

        // Swift writes, Rust reads.
        let swiftWritten = temp.appending("swift.json")
        let cache = JSONDiskCache<LibrarySnapshot>(
            url: swiftWritten, version: LibrarySnapshot.version, label: "test"
        )
        cache.save(snapshot)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: swiftWritten.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try probeSnapshotVersion(path: swiftWritten.path),
                       Int64(LibrarySnapshot.version),
                       "the core and the app disagree about the schema version")
        let roundTripped = try loadSnapshot(path: swiftWritten.path)
        XCTAssertEqual(roundTripped.allPhotos.map(\.path).sorted(),
                       snapshot.allPhotos.map(\.url.path).sorted())
        XCTAssertEqual(roundTripped.sidecarManifest?.count, 1)
        XCTAssertEqual(roundTripped.sidecarManifest?.first?.sidecarPath,
                       snapshot.sidecarManifest?.first?.sidecarURL.path)

        // Rust writes, Swift reads.
        let rustWritten = temp.appending("rust.json")
        try saveSnapshot(path: rustWritten.path, snapshot: roundTripped)
        let reloaded = try XCTUnwrap(
            JSONDiskCache<LibrarySnapshot>(
                url: rustWritten, version: LibrarySnapshot.version, label: "test"
            ).load()
        )
        XCTAssertEqual(reloaded.allPhotos.map(\.url), snapshot.allPhotos.map(\.url))
        XCTAssertEqual(reloaded.allPhotos.map(\.dateTaken), snapshot.allPhotos.map(\.dateTaken))
        XCTAssertEqual(reloaded.rootFolder, snapshot.rootFolder)
        XCTAssertEqual(reloaded.sidecarManifest, snapshot.sidecarManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rustWritten.path),
                      "a core-written snapshot must not be evicted by the app's load path")
    }

    /// The manifest survives a save/load cycle through the Store's own cache,
    /// which is the whole of `_plans/06` Finding 2: without it the first light
    /// scan of every session re-probes every `.xmp` in the library.
    @MainActor
    func testTheStorePersistsAndRestoresTheSidecarManifest() async throws {
        // Two stores over one set of paths — the second is the "relaunch".
        let paths = GalleryPaths(
            libraryCacheURL: temp.appending("library_cache.json"),
            memoriesCacheURL: temp.appending("memories_cache.json"),
            sidecarCacheURL: temp.appending("sidecar_cache.json"),
            thumbnailDir: temp.appending("thumbnails", isDirectory: true),
            mlCacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectoryURL: temp.appending("ModelPacks", isDirectory: true),
            bookmarkKey: "rootFolderBookmark"
        )
        let defaults = TestUserDefaults.make()
        defer { TestUserDefaults.cleanup(defaults) }
        let store = GalleryStore(paths: paths, defaults: defaults, clock: SystemClock(),
                                 contactsService: StubContactsService(contacts: []))

        let root = temp.appending("Library", isDirectory: true)
        for (rel, size) in [("a.jpg", 10), ("a.jpg.xmp", 12)] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: size).write(to: url)
        }
        let scanned = await CoreScanner().scan(at: root, reuseCached: false)
        XCTAssertEqual(scanned.sidecarManifest.count, 1)

        store.lastSidecarManifest = scanned.sidecarManifest
        store.apply(.scanResult(photos: scanned.flatPhotos, root: scanned.rootFolder,
                                persistCache: true))
        // `JSONDiskCache.save` is fire-and-forget on a detached task.
        try await Task.sleep(for: .milliseconds(500))

        let reopened = GalleryStore(paths: paths, defaults: defaults, clock: SystemClock(),
                                    contactsService: StubContactsService(contacts: []))
        XCTAssertEqual(reopened.allPhotos.count, 1, "the library cache did not survive")
        XCTAssertEqual(reopened.lastSidecarManifest, scanned.sidecarManifest,
                       "the manifest must be seeded before the launch scan starts")
    }
}
