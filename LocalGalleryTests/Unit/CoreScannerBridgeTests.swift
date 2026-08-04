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

    /// Poll `condition` until it holds, or give up at `timeout`.
    ///
    /// The alternative — `Task.sleep(for: .milliseconds(500))` — is wrong in
    /// both directions at once: too short on a loaded CI machine, where the
    /// test fails for reasons that have nothing to do with the code, and too
    /// long everywhere else, where it is dead time in every run. Polling the
    /// thing actually being waited for is neither.
    @MainActor
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
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
                                    contentVersion: r.version.contentIdentifier,
                                    intendedSize: r.version.size)
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
                                                  contentVersion: nil, intendedSize: nil)])
    }

    /// The intended size is what the sidecar manifest's `ContentVersion.size`
    /// is built from, and for a placeholder it is *not* the size a `stat`
    /// reports. `FileProviderDetector` already computed `totalFileSize ??
    /// fileSize`; the probe now carries it across instead of letting the core
    /// fall back to the listing's stub size and churn the sidecar cache.
    func testTheProbeCarriesTheIntendedSizeAcrossTheBoundary() throws {
        let url = temp.appending("sized.xmp")
        try Data(repeating: 0x41, count: 1234).write(to: url)

        let answer = try XCTUnwrap(CoreProviderProbe().probe(paths: [url.path]).first)
        // Compared against the detector rather than against the literal: on a
        // local file `totalFileSize` counts metadata and resource forks too, so
        // it is `>= 1234` rather than exactly it. What must hold is that
        // whatever the detector computed is what the core receives.
        XCTAssertEqual(answer.intendedSize, FileProviderDetector.probe(url).version.size)
        XCTAssertNotNil(answer.intendedSize, "nil would send the core back to the stat size")
        XCTAssertGreaterThanOrEqual(answer.intendedSize ?? 0, 1234)
    }

    // MARK: - Which keys the probe reads

    /// The expensive keys are the only ones that can see an iCloud
    /// placeholder, so a read that *threw* must mean "read them anyway" — the
    /// old code folded a thrown read into `false`, the same answer it gives a
    /// genuinely local folder.
    ///
    /// The second half matters just as much and points the other way: on iOS
    /// `isUbiquitousItem` is simply **absent** for everything outside iCloud
    /// Drive. Measured on this simulator, `resourceValues` for a plain local
    /// directory — and for a path that does not exist at all — succeeds and
    /// answers `nil`, never `false`. If that absence were also treated as
    /// "unknown", every scan would take the seven-key path and the entire
    /// 406 s → 2.3 s win would be gone. Absent is a no; thrown is a yes.
    func testTheUbiquityRuleFailsClosedOnlyForAReadThatActuallyFailed() {
        XCTAssertTrue(CoreProviderProbe.treeIsUbiquitous(.unreadable),
                      "a thrown read must not be recorded as 'local'")
        XCTAssertTrue(CoreProviderProbe.treeIsUbiquitous(.answered(true)))
        XCTAssertFalse(CoreProviderProbe.treeIsUbiquitous(.answered(false)))
        XCTAssertFalse(CoreProviderProbe.treeIsUbiquitous(.answered(nil)),
                       "the key is absent for every non-iCloud URL on iOS; that is the fast path")
    }

    /// …and end to end: a plain local root takes the cheap path.
    func testALocalRootResolvesToTheCheapProbe() {
        let probe = CoreProviderProbe()
        XCTAssertNil(probe.resolvedTreeIsUbiquitous, "nothing resolved before a scan asks")
        probe.resolveTreeKind(root: temp.url)
        XCTAssertEqual(probe.resolvedTreeIsUbiquitous, false)
    }

    /// …and it is the *scan root* that is asked, not whichever directory the
    /// first probe batch happened to land in.
    ///
    /// An empty library is what separates the two: it produces no probe batch
    /// at all, so the old lazy resolution never ran and the tree kind stayed
    /// unresolved. Resolving up front means the answer exists whether or not a
    /// single file needed probing — and whose answer it is stops depending on
    /// traversal order.
    func testTheTreeKindIsResolvedFromTheScanRootEvenWhenNothingIsProbed() async throws {
        let root = temp.appending("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let scanner = CoreScanner()
        let outcome = await scanner.scan(at: root, reuseCached: false)
        XCTAssertTrue(outcome.flatPhotos.isEmpty, "nothing to probe, by construction")
        XCTAssertEqual(scanner.providerProbeForTesting.resolvedTreeIsUbiquitous, false,
                       "the root was never asked — the old code only asked once a batch arrived")
    }

    // MARK: - Cancellation

    /// A cancelled scan must produce *nothing*, and say so. An empty outcome
    /// and a library that really is empty have the same shape, and the Store
    /// publishes one of them straight into `allPhotos` + `saveCache()`.
    func testACancelledScanReportsThatItDidNotComplete() async throws {
        let root = temp.appending("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: root.appendingPathComponent("a.jpg"))

        let scanner = CoreScanner()
        let task = Task { () -> CoreScanner.Result in
            // Deterministic: the scan does not start until cancellation has
            // landed, so this tests the behaviour rather than the scheduler.
            while !Task.isCancelled { await Task.yield() }
            return await scanner.scan(at: root, reuseCached: false)
        }
        task.cancel()
        let cancelled = await task.value

        XCTAssertTrue(cancelled.didNotComplete)
        XCTAssertTrue(cancelled.flatPhotos.isEmpty)
        XCTAssertNil(cancelled.rootFolder)

        // …and the session is not wedged by it: the next scan runs normally.
        let after = await scanner.scan(at: root, reuseCached: false)
        XCTAssertFalse(after.didNotComplete)
        XCTAssertEqual(after.flatPhotos.count, 1)
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

    /// The core writes `URL.absoluteString` into the snapshot itself, so its
    /// percent-encoding table has to be Foundation's exactly. `:` is the entry
    /// that looks wrong and is not: Foundation leaves it literal, and escaping
    /// it would give every path containing one — `12:30 clip.mov` off a
    /// camcorder, anything copied off a Windows share — a snapshot key Swift
    /// never writes, so those photos would read as new on every launch.
    ///
    /// `file_url.rs` asserts the same strings from the other side.
    func testTheEncoderAgreesWithFoundationOnEveryReservedCharacter() {
        for path in ["/a/12:30 clip.mov", "/a/b@c.jpg", "/a/b:c.jpg",
                     "/a/spaces and (parens).jpg", "/a/hash#and?query.jpg",
                     "/a/100% real.jpg", "/a/plus+and,comma;semi=eq.jpg"] {
            XCTAssertEqual(
                CoreScanner.fileURL(path).absoluteString,
                URL(fileURLWithPath: path).absoluteString,
                "the bridge and Foundation disagree about \(path)"
            )
            XCTAssertEqual(Array(CoreScanner.fileURL(path).path.unicodeScalars),
                           Array(path.unicodeScalars))
        }
        XCTAssertTrue(CharacterSet.urlPathAllowed.contains(":"),
                      "if this ever changes, core/gallery-model/src/file_url.rs must change with it")
    }

    // MARK: - Snapshot agreement

    /// Why the core drops non-finite GPS coordinates at the source, stated as
    /// the failure it prevents.
    ///
    /// `JSONEncoder` throws on a non-finite `Double`. `JSONDiskCache.save`
    /// catches, logs and carries on — so one photo whose EXIF carries a `0/0`
    /// rational (NaN) or `1/0` (infinity), both of which real cameras write,
    /// means the library snapshot is never written again for the life of the
    /// install: no error surfaces, and every launch full-rescans.
    ///
    /// `gallery_meta`'s `read_gps` drops them where they enter and the core's
    /// snapshot encoder writes them as absent, so nothing the core produces can
    /// poison the cache. This pins the *reason*, which is the part that would
    /// otherwise be lost.
    func testANonFiniteCoordinateIsWhatWouldBreakTheLibraryCache() throws {
        let root = PhotoFolder.fixture(url: temp.url)
        let clean = PhotoFile.fixture(url: temp.appending("a.jpg"), gps: (lat: 48.8581, lon: 2.2945))
        XCTAssertNoThrow(try JSONEncoder().encode(
            LibrarySnapshot(rootFolder: root, allPhotos: [clean], sidecarManifest: [])
        ))

        for poison in [Double.nan, .infinity, -.infinity] {
            let bad = PhotoFile.fixture(url: temp.appending("b.jpg"), gps: (lat: poison, lon: 0))
            XCTAssertThrowsError(
                try JSONEncoder().encode(
                    LibrarySnapshot(rootFolder: root, allPhotos: [bad], sidecarManifest: [])
                ),
                "if this ever stops throwing, the guards in gallery-meta are only belt"
            )
        }
    }

    /// An empty manifest is persisted as an empty manifest.
    ///
    /// `nil` and `[]` mean different things to the load path: `nil` is "written
    /// by a build from before this field existed" and costs a legacy re-probe
    /// of every `.xmp`, `[]` is "scanned, and this library has no sidecars" —
    /// the normal state for anyone not using digiKam. Folding one into the
    /// other made those libraries re-probe on every launch, forever, to
    /// rediscover a fact they had already written down.
    @MainActor
    func testAnEmptyManifestIsPersistedAsEmptyRatherThanAbsent() async throws {
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

        let photo = PhotoFile.fixture(url: temp.appending("a.jpg"))
        store.lastSidecarManifest = []
        store.apply(.scanResult(photos: [photo], root: PhotoFolder.fixture(url: temp.url),
                                persistCache: true))

        await waitUntil("the library cache to reach disk") {
            FileManager.default.fileExists(atPath: paths.libraryCacheURL.path)
        }
        let loaded = try XCTUnwrap(
            JSONDiskCache<LibrarySnapshot>(url: paths.libraryCacheURL,
                                           version: LibrarySnapshot.version, label: "probe").load()
        )
        XCTAssertEqual(loaded.sidecarManifest, [],
                       "an empty manifest must not be persisted as 'this build is too old'")
    }

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
        await waitUntil("the app's snapshot to reach disk") {
            FileManager.default.fileExists(atPath: swiftWritten.path)
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
        // `JSONDiskCache.save` is fire-and-forget on a detached task, so wait
        // for the file to say what the relaunch is about to read rather than
        // for a fixed interval. `load()` is a no-op on a missing file and
        // never evicts one, so polling with it is safe.
        await waitUntil("the library cache to carry the manifest") {
            JSONDiskCache<LibrarySnapshot>(
                url: paths.libraryCacheURL, version: LibrarySnapshot.version, label: "probe"
            ).load()?.sidecarManifest?.count == 1
        }

        let reopened = GalleryStore(paths: paths, defaults: defaults, clock: SystemClock(),
                                    contactsService: StubContactsService(contacts: []))
        XCTAssertEqual(reopened.allPhotos.count, 1, "the library cache did not survive")
        XCTAssertEqual(reopened.lastSidecarManifest, scanned.sidecarManifest,
                       "the manifest must be seeded before the launch scan starts")
    }
}
