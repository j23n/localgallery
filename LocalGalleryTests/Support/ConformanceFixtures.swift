import Foundation
import XCTest
@testable import LocalGallery

/// Shared plumbing for the Phase-3 conformance fixtures.
///
/// The fixtures live in `core/fixtures/scan-conformance/` — one copy in the
/// repo, referenced into this test bundle as a folder resource (project.yml)
/// and read straight off disk by the Rust side
/// (`core/gallery-meta/tests/conformance_fixtures.rs`). Same arrangement as
/// `expected_tags.json`: duplicating the expectations per language would put
/// nothing on the line.
///
/// Regeneration is deliberately explicit:
///
///     TEST_RUNNER_CONFORMANCE_REGEN=1 xcodebuild test …
///
/// (`xcodebuild` forwards host variables to the test process only when they
/// carry the `TEST_RUNNER_` prefix, which it strips.) The harnesses then dump
/// what they observe into the repo, and always echo it to stdout between
/// `===BEGIN <name>===` / `===END <name>===` markers. A *mismatch* never
/// rewrites the fixture — see `assertMatches`. Full recipe in the fixture
/// README.
enum ConformanceFixtures {

    static let directoryName = "scan-conformance"

    /// Phase-4 memories/indexes fixtures. Same mechanism, second directory —
    /// every entry point below takes the directory so the two sets of
    /// harnesses share one regeneration story.
    static let memoriesDirectoryName = "memories-conformance"

    // MARK: - Locating the fixtures

    /// The named fixture folder inside the test bundle.
    static func root(
        _ directory: String = directoryName,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        return try XCTUnwrap(
            bundle.url(forResource: directory, withExtension: nil),
            "\(directory)/ is missing from the test bundle — check the folder reference in project.yml",
            file: file, line: line
        )
    }

    static func assets(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try root(file: file, line: line).appendingPathComponent("assets", isDirectory: true)
    }

    /// The repo-side copy of the fixture directory, derived from `#filePath`
    /// at compile time (`LocalGalleryTests/Support/…` → repo root). Only used
    /// for regeneration; reads always go through the bundle.
    static func repoDirectory(_ directory: String = directoryName) -> URL {
        URL(fileURLWithPath: #filePath)          // …/LocalGalleryTests/Support/ConformanceFixtures.swift
            .deletingLastPathComponent()          // …/LocalGalleryTests/Support
            .deletingLastPathComponent()          // …/LocalGalleryTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("core/fixtures/\(directory)", isDirectory: true)
    }

    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment["CONFORMANCE_REGEN"] == "1"
    }

    // MARK: - Canonical JSON

    /// Sorted keys + pretty printing + unescaped slashes: the committed files
    /// have to be diff-readable, and sorted keys keep the bytes stable across
    /// Swift releases (dictionary iteration order is not).
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)   // trailing newline, so the files are POSIX-clean
        return data
    }

    // MARK: - Assert / regenerate

    /// Compare `observed` against the committed fixture `name`.
    ///
    /// The comparison is on the *decoded* value, not the bytes, so a
    /// JSONEncoder formatting change can never fail the suite for the wrong
    /// reason. Byte drift is caught separately by
    /// `assertCommittedBytesAreCanonical`.
    static func assertMatches<T: Codable & Equatable>(
        _ observed: T,
        fixture name: String,
        in directory: String = directoryName,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try encode(observed)
        let url = try root(directory, file: file, line: line).appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: url.path) else {
            dump(data, name: name, writeToRepo: true, in: directory)
            XCTFail(
                "\(name) is not committed yet — the observed output was dumped "
                + "(see the ===BEGIN \(name)=== block above). "
                + "Copy it to core/fixtures/\(directory)/\(name).",
                file: file, line: line
            )
            return
        }

        if isRegenerating { dump(data, name: name, writeToRepo: true, in: directory) }

        let committed: T
        do {
            committed = try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            // The *shape* changed, not just a value — typically a new field on
            // the record type. Regenerating is the right move, and the run
            // above already did it if it was asked to.
            if !isRegenerating { dump(data, name: name, writeToRepo: false, in: directory) }
            XCTFail(
                "\(name) no longer decodes into the current fixture type (\(error)). "
                + "Rerun with TEST_RUNNER_CONFORMANCE_REGEN=1 to rewrite it.",
                file: file, line: line
            )
            return
        }
        if committed != observed {
            // Deliberately NOT written into the repo: a mismatch that silently
            // rewrote the fixture would go red once and green forever after,
            // which is the exact failure mode this suite exists to prevent.
            dump(data, name: name, writeToRepo: false, in: directory)
            XCTFail(
                "\(name) no longer matches the current implementation. Either the "
                + "behaviour changed (fix the code) or the change is intended "
                + "(rerun with CONFORMANCE_REGEN=1 and commit the new fixture, "
                + "explaining what moved). The observed output was dumped above.",
                file: file, line: line
            )
        }
    }

    /// Compare raw JSON against the committed fixture as a *JSON object*.
    ///
    /// Used for the `LibrarySnapshot` fixture, which is produced by the app's
    /// real save path. Deliberately not a byte comparison: `JSONEncoder` with
    /// default options emits a keyed container's members in an UNSPECIFIED
    /// order that varies between processes (Swift's per-process hash seed), so
    /// the wire format is "this JSON object", not "these bytes". Everything
    /// else about the encoding — value representations, which keys exist at
    /// all — is still pinned exactly.
    static func assertMatchesJSONObject(
        _ observed: Data,
        fixture name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try root(file: file, line: line).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            dump(observed, name: name, writeToRepo: true)
            XCTFail("\(name) is not committed yet — the observed bytes were dumped.",
                    file: file, line: line)
            return
        }
        if isRegenerating { dump(observed, name: name, writeToRepo: true) }

        let committed = try Data(contentsOf: url)
        let lhs = try JSONSerialization.jsonObject(with: committed) as? NSDictionary
        let rhs = try JSONSerialization.jsonObject(with: observed) as? NSDictionary
        if lhs != rhs {
            dump(observed, name: name, writeToRepo: false)
            XCTFail(
                "\(name) no longer matches what the current save path produces.\n"
                + "committed: \(sortedJSONString(committed))\n"
                + "observed : \(sortedJSONString(observed))\n"
                + "This file is the persisted-library wire format; a diff means every "
                + "installed library either migrates or rescans. Rerun with "
                + "TEST_RUNNER_CONFORMANCE_REGEN=1 once the change is deliberate.",
                file: file, line: line
            )
        }
    }

    /// Key-sorted rendering, for failure messages only.
    static func sortedJSONString(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "<unparseable>" }
        return String(decoding: sorted, as: UTF8.self)
    }

    /// The committed file must itself be canonical, so regeneration produces a
    /// one-line diff instead of reformatting the world.
    static func assertCommittedBytesAreCanonical<T: Codable>(
        _ type: T.Type,
        fixture name: String,
        in directory: String = directoryName,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try root(directory, file: file, line: line).appendingPathComponent(name)
        let raw = try Data(contentsOf: url)
        let reencoded = try encode(JSONDecoder().decode(T.self, from: raw))
        XCTAssertEqual(
            String(data: raw, encoding: .utf8), String(data: reencoded, encoding: .utf8),
            "\(name) is not in canonical form — regenerate it with CONFORMANCE_REGEN=1",
            file: file, line: line
        )
    }

    // MARK: - Dumping

    /// Emit `data` two ways: into the repo (best effort — the simulator
    /// sandbox may refuse) and onto stdout between markers, with a temp-dir
    /// copy as a third chance. Deliberately not an `XCTAttachment`:
    /// `XCTContext.runActivity` traps when called from an async test body.
    static func dump(_ data: Data, name: String, writeToRepo: Bool, in directory: String = directoryName) {
        let repo = repoDirectory(directory).appendingPathComponent(name)
        let wroteRepo = writeToRepo && (try? data.write(to: repo, options: .atomic)) != nil

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? data.write(to: temp, options: .atomic)

        print("===BEGIN \(name)===")
        print(String(data: data, encoding: .utf8) ?? "<not utf8>")
        print("===END \(name)===")
        let repoState = writeToRepo ? (wroteRepo ? repo.path : "REFUSED (sandbox)") : "not written (set CONFORMANCE_REGEN=1)"
        print("conformance dump: repo=\(repoState) temp=\(temp.path)")
    }

    private final class BundleToken {}
}

// MARK: - Record types shared by the metadata + scanner dumps

/// A date, recorded in the one representation that is invariant under the
/// machine's time zone.
///
/// `localWallClock` — EXIF has no zone, so the reader interprets it in the
/// *device* zone (`EXIFService.exifDateFormatter` did it with a `DateFormatter`
/// that had none; the core hands back a zone-less wall clock and
/// `EnrichmentService.resolve` does the same job explicitly). Parsing in zone Z and formatting back
/// in zone Z round-trips to the original wall clock whatever Z is, so the wall
/// clock is what the fixture pins. The absolute instant is not portable and is
/// deliberately not recorded.
///
/// `utc` — a QuickTime `©day` yields a real instant (it carries an offset, and
/// a zone-less one is read as UTC), so UTC is both exact and portable.
struct ConformanceDate: Codable, Equatable {
    let basis: String
    let value: String

    static let localWallClockBasis = "localWallClock"
    static let utcBasis = "utc"

    /// Mirrors `EXIFService.exifDateFormatter`: POSIX locale, Gregorian
    /// calendar, **no** explicit time zone.
    nonisolated(unsafe) private static let wallClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    nonisolated(unsafe) private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    static func localWallClock(_ date: Date?) -> ConformanceDate? {
        date.map { ConformanceDate(basis: localWallClockBasis, value: wallClock.string(from: $0)) }
    }

    static func utc(_ date: Date?) -> ConformanceDate? {
        date.map { ConformanceDate(basis: utcBasis, value: utc.string(from: $0)) }
    }
}

/// `HierarchicalTag` flattened with every key always present (the real type's
/// synthesized `Codable` omits a nil `namespace`, which makes the fixture
/// harder to read and to diff).
struct ConformanceTag: Codable, Equatable {
    let fullPath: String
    let namespace: String?
    let displayName: String

    init(_ tag: HierarchicalTag) {
        fullPath = tag.fullPath
        namespace = tag.namespace
        displayName = tag.displayName
    }

    enum CodingKeys: String, CodingKey { case fullPath, namespace, displayName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullPath = try c.decode(String.self, forKey: .fullPath)
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
        displayName = try c.decode(String.self, forKey: .displayName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fullPath, forKey: .fullPath)
        try c.encode(namespace, forKey: .namespace)   // writes null, not omitted
        try c.encode(displayName, forKey: .displayName)
    }
}

/// `FaceRegion` with an always-present `name` key, same reasoning as above.
struct ConformanceRegion: Codable, Equatable {
    let name: String?
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double

    init(_ region: FaceRegion) {
        name = region.name
        centerX = region.centerX
        centerY = region.centerY
        width = region.width
        height = region.height
    }

    enum CodingKeys: String, CodingKey { case name, centerX, centerY, width, height }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        centerX = try c.decode(Double.self, forKey: .centerX)
        centerY = try c.decode(Double.self, forKey: .centerY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}
