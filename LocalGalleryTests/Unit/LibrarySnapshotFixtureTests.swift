import XCTest
@testable import LocalGallery

/// Pins the on-disk `LibrarySnapshot` wire format.
///
/// `core/fixtures/scan-conformance/library_snapshot_v20.json` is produced by
/// the app's **real** save path — `JSONDiskCache<LibrarySnapshot>.save`, i.e.
/// a stock `JSONEncoder` over a `{version, value}` envelope — from a library
/// that came out of a real `FolderScanner.scan` (with the temp-dir paths
/// rebased onto a fixed root and a few photos decorated so every optional is
/// exercised at least once).
///
/// Phase 3 has to read this file with serde and re-emit something Swift
/// decodes identically, and a warm relaunch after the port must NOT trigger a
/// rescan. Date representation, URL escaping, which keys exist at all and the
/// omission of nil optionals are therefore pinned exactly.
///
/// Key *order* is not, and cannot be: `JSONEncoder`'s default output orders a
/// keyed container's members unpredictably (Swift's per-process hash seed), so
/// the same snapshot encodes to different bytes in different processes. The
/// contract is "this JSON object" — see `testKeyOrderIsNotPartOfTheContract`.
///
/// Regenerate with `TEST_RUNNER_CONFORMANCE_REGEN=1` — and expect to justify
/// it, because a diff here means every installed library either migrates or
/// rescans. The encoding contract is written up in the fixture README.
final class LibrarySnapshotFixtureTests: XCTestCase {

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

    /// The root every URL in the fixture is rebased onto. Absolute, fixed, and
    /// nowhere near a real device path — a snapshot fixture that carried the
    /// temp dir's random name would be unreviewable and unstable.
    private static let canonicalRoot = "/fixtures/PhotoLibrary"

    private static let fixtureName = "library_snapshot_v20.json"

    // MARK: - Generation

    /// Build the fixture library: scan a real tree, rebase, decorate.
    @MainActor
    private func makeSnapshot() async throws -> LibrarySnapshot {
        let root = temp.appending("PhotoLibrary", isDirectory: true)
        let files: [(String, Int)] = [
            ("cover.jpg", 4096),
            ("2021/IMG_0001.jpg", 5120),
            ("2021/IMG_0001.mov", 6144),          // live-photo partner
            ("2021/IMG_0002.jpg", 5121),
            ("2021/Trip/Ünicode café.jpg", 7168),
            ("Videos/Clip.mov", 8192),
        ]
        for (rel, size) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: size).write(to: url)
        }

        let result = await FolderScanner.scan(at: root, reuseCached: false)
        let scannedRoot = try XCTUnwrap(result.rootFolder)

        // Rebase onto the canonical root, then decorate. Decoration is keyed
        // on the rebased relative path so it reads like the table it is.
        let rebasedPhotos = result.flatPhotos.map { decorate(rebase($0, from: root)) }
        let byURL = Dictionary(rebasedPhotos.map { ($0.url, $0) }, uniquingKeysWith: { _, b in b })
        let rebasedRoot = rebase(scannedRoot, from: root, photos: byURL)

        // Same ordering the Store persists: `allPhotos` in scan order. Sorted
        // here so the fixture does not depend on the filesystem's listing
        // order (which is unspecified — see ScannerConformanceTests).
        return LibrarySnapshot(
            rootFolder: rebasedRoot,
            allPhotos: rebasedPhotos.sorted { $0.url.path < $1.url.path }
        )
    }

    private func canonicalURL(_ url: URL, from root: URL) -> URL {
        let rel = url.path.hasPrefix(root.path)
            ? String(url.path.dropFirst(root.path.count))
            : url.path
        return URL(fileURLWithPath: Self.canonicalRoot + rel)
    }

    private func rebase(_ photo: PhotoFile, from root: URL) -> PhotoFile {
        let url = canonicalURL(photo.url, from: root)
        var p = photo
        p = PhotoFile(
            id: PhotoFile.stableID(for: url),
            url: url,
            filename: photo.filename,
            fileSize: photo.fileSize,
            dateTaken: photo.dateTaken,
            dateFromMetadata: photo.dateFromMetadata,
            isVideo: photo.isVideo,
            livePhotoVideoURL: photo.livePhotoVideoURL.map { canonicalURL($0, from: root) },
            hierarchicalTags: photo.hierarchicalTags,
            countryCode: photo.countryCode,
            enrichedFileDate: photo.enrichedFileDate,
            fileModificationDate: photo.fileModificationDate,
            gpsLatitude: photo.gpsLatitude,
            gpsLongitude: photo.gpsLongitude,
            faceRegions: photo.faceRegions,
            locality: photo.locality,
            sidecarStatus: photo.sidecarStatus
        )
        return p
    }

    private func rebase(_ folder: PhotoFolder, from root: URL, photos: [URL: PhotoFile]) -> PhotoFolder {
        let url = canonicalURL(folder.url, from: root)
        let subfolders = folder.subfolders.map { rebase($0, from: root, photos: photos) }
        let ownPhotos = folder.photos.compactMap { photos[canonicalURL($0.url, from: root)] }
            .sorted { $0.url.path < $1.url.path }
        // The scanner picks `photos.first`, i.e. whatever the directory
        // listing happened to return first — unspecified, and it would make
        // this fixture non-reproducible. Re-derive it from the sorted list,
        // keeping the same *rule* (own photos first, else the first
        // subfolder that has a cover).
        let cover = ownPhotos.first?.url ?? subfolders.compactMap(\.coverPhotoURL).first
        return PhotoFolder(
            id: PhotoFolder.stableID(for: url),
            url: url,
            name: folder.name,
            subfolders: subfolders,
            photos: ownPhotos,
            coverPhotoURL: cover,
            totalPhotoCount: folder.totalPhotoCount,
            dateModified: Date(timeIntervalSinceReferenceDate: 700_000_000),
            dateCreated: Date(timeIntervalSinceReferenceDate: 690_000_000)
        )
    }

    /// Give the fixture at least one photo with every optional populated and
    /// at least one with every optional nil, so both encoder branches
    /// (`encodeIfPresent` writes / omits) appear in the committed bytes.
    private func decorate(_ photo: PhotoFile) -> PhotoFile {
        var p = photo
        // Filesystem dates on a freshly created tree are "now" — replace them
        // with fixed instants or the fixture would change every run.
        p.dateTaken = Date(timeIntervalSinceReferenceDate: 650_000_000)
        p.fileModificationDate = Date(timeIntervalSinceReferenceDate: 649_000_000)
        p.enrichedFileDate = nil
        p.dateFromMetadata = false

        switch p.url.lastPathComponent {
        case "IMG_0001.jpg":
            // Everything populated.
            p.dateFromMetadata = true
            p.dateTaken = Date(timeIntervalSinceReferenceDate: 651_234_567.25)
            p.enrichedFileDate = Date(timeIntervalSinceReferenceDate: 649_000_000)
            p.hierarchicalTags = [
                HierarchicalTag(raw: "People/Alice"),
                HierarchicalTag(raw: "Places/Italy/Lazio/Rome"),
                HierarchicalTag(raw: "flat-tag"),          // nil namespace
            ]
            p.countryCode = "IT"
            p.gpsLatitude = 41.9028
            p.gpsLongitude = -12.4964
            p.faceRegions = [
                FaceRegion(name: "Alice", centerX: 0.25, centerY: 0.3, width: 0.1, height: 0.12),
                FaceRegion(name: nil, centerX: 0.6, centerY: 0.4, width: 0.05, height: 0.05),
            ]
        case "IMG_0002.jpg":
            // Nothing but the required fields — every optional stays nil.
            p.dateTaken = nil
            p.fileModificationDate = nil
        case "Clip.mov":
            p.dateFromMetadata = true
            p.enrichedFileDate = Date(timeIntervalSinceReferenceDate: 649_000_000)
        default:
            break
        }
        // Neither of these is in CodingKeys; set them to non-defaults so the
        // test can prove they are dropped.
        p.locality = .remote(downloaded: false)
        p.sidecarStatus = .cached(FileProviderDetector.ContentVersion(
            contentIdentifier: 42, modificationDate: nil, size: 99
        ))
        return p
    }

    /// Encode through the app's real save path and hand back the bytes.
    @MainActor
    private func encodeViaRealSavePath(_ snapshot: LibrarySnapshot) async throws -> Data {
        let url = temp.appending("library_cache.json")
        let cache = JSONDiskCache<LibrarySnapshot>(
            url: url, version: LibrarySnapshot.version, label: "library cache"
        )
        cache.save(snapshot)
        // `save` is fire-and-forget on a detached task; poll rather than
        // reach into the cache's internals.
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("JSONDiskCache never wrote \(url.path)")
        return Data()
    }

    // MARK: - Tests

    @MainActor
    func testSnapshotFixtureMatchesTheRealSavePath() async throws {
        let snapshot = try await makeSnapshot()
        let data = try await encodeViaRealSavePath(snapshot)
        try ConformanceFixtures.assertMatchesJSONObject(data, fixture: Self.fixtureName)
    }

    /// The envelope: `{ "version": Int, "value": LibrarySnapshot }`, version
    /// probed before the payload so a `Value` schema change still reports as a
    /// version mismatch rather than a corrupt file.
    func testEnvelopeShape() throws {
        let object = try fixtureObject()
        XCTAssertEqual(Set(object.keys), ["version", "value"])
        XCTAssertEqual(object["version"] as? Int, 20)
        XCTAssertEqual(LibrarySnapshot.version, 20,
                       "the committed fixture is v20 — regenerate it in the same commit as a bump")
        let value = try XCTUnwrap(object["value"] as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["rootFolder", "allPhotos"],
                       "LibrarySnapshot grew or lost a field; regenerate the fixture and update the README "
                       + "(see _plans/06-performance-baseline.md Finding 2 for the planned sidecarManifest field)")
    }

    /// Dates are JSON **numbers**: `JSONEncoder`'s default `.deferredToDate`
    /// strategy, i.e. seconds since the 2001-01-01 reference date — NOT ISO
    /// 8601, NOT the Unix epoch. serde must use the same origin.
    func testDatesAreReferenceDateSeconds() throws {
        let photos = try fixturePhotos()
        let decorated = try XCTUnwrap(photos.first { ($0["filename"] as? String) == "IMG_0001" })
        let raw = try XCTUnwrap(decorated["dateTaken"] as? Double)
        XCTAssertEqual(raw, 651_234_567.25, accuracy: 0.000_001)
        XCTAssertEqual(
            Date(timeIntervalSinceReferenceDate: raw).timeIntervalSince1970,
            raw + 978_307_200,
            accuracy: 0.000_001,
            "reference-date origin is 2001-01-01T00:00:00Z = Unix 978307200"
        )
        XCTAssertFalse(decorated["dateTaken"] is String, "dates must not be ISO 8601 strings")
    }

    /// URLs are `absoluteString`: a `file://` URL with a percent-encoded path.
    func testURLsArePercentEncodedFileURLStrings() throws {
        let photos = try fixturePhotos()
        let urls = photos.compactMap { $0["url"] as? String }
        XCTAssertEqual(urls.count, photos.count)
        XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("file:///fixtures/PhotoLibrary/") })
        // LANDMINE: `URL(fileURLWithPath:)` decomposes, so the Ü that went in
        // as U+00DC comes out as "U" + U+0308 and percent-encodes as
        // "U%CC%88" — NOT "%C3%9C". Every URL this app writes is NFD.
        let unicode = try XCTUnwrap(urls.first { $0.contains("U%CC%88") })
        XCTAssertFalse(unicode.contains("%C3%9C"), "the precomposed Ü would mean URLs stopped decomposing")
        XCTAssertTrue(unicode.contains("%20"), "spaces are percent-encoded, not left raw or turned into +")
        XCTAssertEqual(URL(string: unicode)?.lastPathComponent.hasSuffix(".jpg"), true)
    }

    /// Nil optionals are omitted, not written as `null` — the synthesized
    /// encoder uses `encodeIfPresent`. That is the "legal loss" the port has
    /// to reproduce: emitting `null` would still decode, but the bytes would
    /// differ and this fixture would go red.
    func testNilOptionalsAreOmitted() throws {
        let photos = try fixturePhotos()
        let bare = try XCTUnwrap(photos.first { ($0["filename"] as? String) == "IMG_0002" })
        XCTAssertEqual(Set(bare.keys), ["id", "url", "filename", "fileSize", "dateFromMetadata",
                                        "isVideo", "hierarchicalTags", "faceRegions"],
                       "an all-nil photo carries only the non-optional keys plus the defaulted arrays/bools")
        let decorated = try XCTUnwrap(photos.first { ($0["filename"] as? String) == "IMG_0001" })
        XCTAssertEqual(Set(decorated.keys), ["id", "url", "filename", "fileSize", "dateTaken",
                                             "dateFromMetadata", "isVideo", "livePhotoVideoURL",
                                             "hierarchicalTags", "countryCode", "enrichedFileDate",
                                             "fileModificationDate", "gpsLatitude", "gpsLongitude",
                                             "faceRegions"],
                       "the fully populated photo is the complete PhotoFile key set")

        // Nested optionals behave the same way.
        let tags = try XCTUnwrap(decorated["hierarchicalTags"] as? [[String: Any]])
        let flat = try XCTUnwrap(tags.first { ($0["fullPath"] as? String) == "flat-tag" })
        XCTAssertNil(flat["namespace"], "a nil namespace is omitted")
        let regions = try XCTUnwrap(decorated["faceRegions"] as? [[String: Any]])
        XCTAssertEqual(regions.count, 2)
        XCTAssertNil(regions[1]["name"], "a nil region name is omitted")
    }

    /// `locality`, `sidecarStatus`, `dimensions` and `exif` are not in
    /// `CodingKeys`: they are dropped on save and come back at their defaults.
    /// The fixture was built with non-default values on purpose.
    func testRuntimeOnlyFieldsAreNotPersisted() throws {
        for photo in try fixturePhotos() {
            XCTAssertNil(photo["locality"])
            XCTAssertNil(photo["sidecarStatus"])
            XCTAssertNil(photo["dimensions"])
            XCTAssertNil(photo["exif"])
        }
        let decoded = try decodeFixture()
        XCTAssertTrue(decoded.allPhotos.allSatisfy { $0.locality == .local },
                      "locality resets to .local on reload")
        XCTAssertTrue(decoded.allPhotos.allSatisfy { $0.sidecarStatus == .absent },
                      "sidecarStatus resets to .absent on reload")
    }

    /// Decode → encode → decode reproduces the same JSON *object* (not the
    /// same bytes — see below) and the same values. Anything less and a Rust
    /// round trip could silently rewrite every user's cache.
    func testDecodeEncodeRoundTripPreservesTheObject() throws {
        let raw = try fixtureData()
        let decoded = try decodeFixture()
        let reencoded = try JSONEncoder().encode(Envelope(version: LibrarySnapshot.version, value: decoded))

        let lhs = try JSONSerialization.jsonObject(with: raw) as? NSDictionary
        let rhs = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        XCTAssertEqual(lhs, rhs, "re-encoding the decoded snapshot must reproduce the same JSON object.\n"
                       + "committed: \(ConformanceFixtures.sortedJSONString(raw))\n"
                       + "observed : \(ConformanceFixtures.sortedJSONString(reencoded))")

        let twice = try JSONDecoder().decode(Envelope.self, from: reencoded).value
        // PhotoFile's == is id-only, so compare the fields that matter here.
        XCTAssertEqual(twice.allPhotos.map(\.url), decoded.allPhotos.map(\.url))
        XCTAssertEqual(twice.allPhotos.map(\.dateTaken), decoded.allPhotos.map(\.dateTaken))
        XCTAssertEqual(twice.allPhotos.map(\.hierarchicalTags), decoded.allPhotos.map(\.hierarchicalTags))
        XCTAssertEqual(twice.allPhotos.map(\.faceRegions), decoded.allPhotos.map(\.faceRegions))
        XCTAssertEqual(twice.rootFolder, decoded.rootFolder)
    }

    /// The reason the two tests above compare objects rather than bytes:
    /// `JSONEncoder`'s default output puts a keyed container's members in an
    /// order that is not specified and is not stable between processes.
    /// Nothing in the app may depend on it, and neither may the Rust port —
    /// serde is free to emit its own order as long as the object matches.
    func testKeyOrderIsNotPartOfTheContract() throws {
        let decoded = try decodeFixture()
        let encodings = try (0..<8).map { _ in
            try JSONEncoder().encode(Envelope(version: LibrarySnapshot.version, value: decoded))
        }
        // Not even stable within one process, let alone across the process
        // that wrote the committed file — so byte identity is not asserted
        // anywhere. (Length is: the same object always produces the same
        // number of bytes, only the order moves.)
        XCTAssertEqual(Set(encodings.map(\.count)).count, 1)

        let expected = try JSONSerialization.jsonObject(with: try fixtureData()) as? NSDictionary
        for data in encodings {
            XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary, expected,
                           "every encoding must agree as an object however the keys are ordered")
        }
    }

    /// Structural expectations, so a fixture regenerated from a broken scan
    /// cannot quietly become the new spec.
    func testDecodedStructure() throws {
        let s = try decodeFixture()
        XCTAssertEqual(s.allPhotos.count, 5, "cover + 2 images + unicode image + standalone video")
        XCTAssertEqual(s.rootFolder.name, "PhotoLibrary")
        XCTAssertEqual(s.rootFolder.totalPhotoCount, 5)
        XCTAssertEqual(s.rootFolder.subfolders.map(\.name), ["2021", "Videos"])
        XCTAssertEqual(s.rootFolder.subfolders[0].subfolders.map(\.name), ["Trip"])

        // Ids are derived, not stored arbitrarily — the port has to compute
        // the same ones from the same paths.
        for photo in s.allPhotos {
            XCTAssertEqual(photo.id, PhotoFile.stableID(for: photo.url), "\(photo.url.path)")
        }
        XCTAssertEqual(s.rootFolder.id, PhotoFolder.stableID(for: s.rootFolder.url))

        let live = try XCTUnwrap(s.allPhotos.first { $0.filename == "IMG_0001" })
        XCTAssertEqual(live.livePhotoVideoURL?.lastPathComponent, "IMG_0001.mov")
        XCTAssertEqual(live.hierarchicalTags.count, 3)
        XCTAssertEqual(live.faceRegions.count, 2)
        XCTAssertEqual(live.countryCode, "IT")
        XCTAssertEqual(live.gpsLongitude, -12.4964)

        XCTAssertEqual(s.allPhotos.filter(\.isVideo).count, 1,
                       "the paired IMG_0001.mov is not its own photo")
    }

    /// The load path evicts on a version mismatch *before* trying to decode
    /// the payload — port the envelope semantics, not just the shape.
    @MainActor
    func testVersionProbeRejectsTheFixtureUnderADifferentVersion() throws {
        let url = temp.appending("mismatch.json")
        try fixtureData().write(to: url)
        let cache = JSONDiskCache<LibrarySnapshot>(
            url: url, version: LibrarySnapshot.version + 1, label: "test"
        )
        XCTAssertNil(cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a version mismatch evicts the file so it is not re-parsed every launch")
    }

    /// …and the same file loads cleanly at the matching version. This is the
    /// Phase-3 exit criterion in miniature: a snapshot written by the Swift
    /// build must restore warm, with no rescan.
    @MainActor
    func testFixtureLoadsWarmThroughTheRealLoadPath() throws {
        let url = temp.appending("warm.json")
        try fixtureData().write(to: url)
        let cache = JSONDiskCache<LibrarySnapshot>(
            url: url, version: LibrarySnapshot.version, label: "test"
        )
        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.allPhotos.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a good load must not evict")
    }

    // MARK: - Helpers

    /// Mirrors `JSONDiskCache.Payload`, which is private.
    private struct Envelope: Codable {
        let version: Int
        let value: LibrarySnapshot
    }

    private func fixtureData() throws -> Data {
        let url = try ConformanceFixtures.root().appendingPathComponent(Self.fixtureName)
        return try Data(contentsOf: url)
    }

    private func fixtureObject() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
    }

    private func fixturePhotos() throws -> [[String: Any]] {
        let value = try XCTUnwrap(fixtureObject()["value"] as? [String: Any])
        return try XCTUnwrap(value["allPhotos"] as? [[String: Any]])
    }

    private func decodeFixture() throws -> LibrarySnapshot {
        try JSONDecoder().decode(Envelope.self, from: fixtureData()).value
    }

}
