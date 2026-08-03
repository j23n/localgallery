import XCTest
@testable import LocalGallery

/// Pins how Unicode filenames survive the round trip through Foundation, APFS
/// and `PhotoFile.stableID`.
///
/// This is Phase-3 groundwork, not trivia: the scanner's ids are SHA-256 over
/// `url.standardized.path`, so *which bytes that property hands back* is part
/// of the id contract the Rust port has to reproduce. Three of the four
/// properties tested here disagree with each other, and Swift's `String ==`
/// (canonical equivalence) hides all of it — every assertion below therefore
/// compares `unicodeScalars`, never strings.
///
/// Companion to `stable_uuid_vectors.json`, which pins that NFC and NFD derive
/// *different* ids. This file pins which of the two the app actually feeds in.
final class PathNormalizationTests: XCTestCase {

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

    private let nfc = "café.jpg".precomposedStringWithCanonicalMapping
    private let nfd = "café.jpg".decomposedStringWithCanonicalMapping

    private func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

    /// Create a file with the byte-exact name (no `fileSystemRepresentation`).
    @discardableResult
    private func createByteExact(_ name: String, in dir: URL, contents: String) throws -> String {
        let path = dir.path + "/" + name
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0, "open(\(path)) failed with errno \(errno)")
        let bytes = Array(contents.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        return path
    }

    /// The fixture inputs must actually differ, or everything below is vacuous.
    func testTheTwoSpellingsAreDistinctScalarSequences() {
        XCTAssertNotEqual(scalars(nfc), scalars(nfd))
        XCTAssertEqual(nfc, nfd, "…while Swift's String == calls them equal — that is the trap")
    }

    /// `URL.path` / `URL.standardized.path` preserve the on-disk bytes;
    /// `URL.standardizedFileURL.path` and `resolvingSymlinksInPath().path`
    /// DECOMPOSE them.
    func testURLPathAccessorsDisagreeOnNormalization() throws {
        try createByteExact(nfc, in: temp.url, contents: "x")
        let listed = try FileManager.default.contentsOfDirectory(
            at: temp.url, includingPropertiesForKeys: nil
        )
        let url = try XCTUnwrap(listed.first)

        XCTAssertEqual(scalars(url.lastPathComponent), scalars(nfc), "lastPathComponent preserves")
        XCTAssertEqual(scalars(url.path), scalars(temp.url.path + "/" + nfc), "path preserves")
        XCTAssertEqual(scalars(url.standardized.path), scalars(temp.url.path + "/" + nfc),
                       "standardized.path preserves — and this is the one stableID hashes")
        XCTAssertEqual(scalars(url.standardizedFileURL.lastPathComponent), scalars(nfd),
                       "standardizedFileURL DECOMPOSES")
        XCTAssertEqual(scalars(url.resolvingSymlinksInPath().lastPathComponent), scalars(nfd),
                       "resolvingSymlinksInPath DECOMPOSES")
    }

    /// Anything written through a Foundation path API lands on disk
    /// decomposed, whatever the caller spelled. A library created *by this
    /// app* is therefore all-NFD; NFC names only arrive from outside.
    func testFoundationWritesDecomposeTheName() throws {
        let dir = temp.appending("foundation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent(nfc))
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(scalars(try XCTUnwrap(listed.first)), scalars(nfd),
                       "the NFC name was decomposed on the way to the filesystem")
    }

    /// APFS is normalization-*insensitive*: both spellings resolve to one
    /// directory entry, so a single folder can never hold both. The NFC/NFD id
    /// divergence is a cross-filesystem concern, not a same-directory one.
    func testAPFSResolvesBothSpellingsToOneEntry() throws {
        let dir = temp.appending("collision", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try createByteExact(nfc, in: dir, contents: "first")
        try createByteExact(nfd, in: dir, contents: "second")
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(listed.count, 1, "APFS collapsed the two spellings")
        XCTAssertEqual(scalars(try XCTUnwrap(listed.first)), scalars(nfc),
                       "the entry keeps the spelling it was CREATED with")
        let path = dir.path + "/" + nfd
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "second",
                       "the second write reused the first entry, and the NFD spelling still opens it")
    }

    /// The consequence for Phase 3: `PhotoFile.stableID` hashes the on-disk
    /// bytes, so the id of an externally-created NFC file is the NFC id — not
    /// the NFD one you would get by round-tripping the name through
    /// `standardizedFileURL`.
    func testStableIDHashesTheOnDiskSpelling() throws {
        try createByteExact(nfc, in: temp.url, contents: "x")
        let url = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: temp.url, includingPropertiesForKeys: nil
        ).first)

        XCTAssertEqual(PhotoFile.stableID(for: url),
                       StableUUID.derive(from: temp.url.path + "/" + nfc))
        XCTAssertNotEqual(PhotoFile.stableID(for: url),
                          StableUUID.derive(from: temp.url.path + "/" + nfd),
                          "if these were equal the whole NFC/NFD distinction would be moot")
        XCTAssertNotEqual(PhotoFile.stableID(for: url),
                          StableUUID.derive(from: url.standardizedFileURL.path),
                          "standardizedFileURL would have produced a DIFFERENT id — do not use it for identity")
    }
}
