import XCTest
@testable import LocalGallery

/// Cross-language parity for the one piece of logic both the Swift app and the
/// Rust core implement: the path-derived photo/folder id.
///
/// The same fixture is asserted from Rust in
/// `core/gallery-model/tests/stable_uuid_vectors.rs`, so a divergence in either
/// implementation turns one of the two suites red.
final class StableUUIDVectorTests: XCTestCase {

    func testSwiftImplementationMatchesEveryVector() throws {
        let vectors = try StableUUIDVectors.load()
        XCTAssertGreaterThanOrEqual(vectors.count, 30, "expected the full vector set")

        for vector in vectors {
            XCTAssertEqual(
                StableUUID.derive(from: vector.input).uuidString.lowercased(),
                vector.uuid,
                "vector `\(vector.label)` diverged"
            )
        }
    }

    func testRustCoreMatchesEveryVector() throws {
        let vectors = try StableUUIDVectors.load()

        for vector in vectors {
            XCTAssertEqual(
                stableUuid(input: vector.input),
                vector.uuid,
                "vector `\(vector.label)` diverged across the FFI"
            )
        }
    }

    func testCompositionFormsStayDistinct() throws {
        // NFC and NFD spellings of the same visible name derive different ids,
        // because the hash is over UTF-8 bytes. APFS hands back decomposed
        // names, so this is not hypothetical — it is the behaviour to revisit
        // when the scanner moves into the core (Phase 3). Pinned here so nobody
        // "fixes" it by accident.
        //
        // Note the trap this test walked into first: Swift's `String ==` is
        // canonical-equivalence based, so `nfc.input == nfd.input` is *true*
        // while their ids differ. Any dedupe or lookup that compares Swift
        // Strings will therefore disagree with anything comparing StableUUIDs.
        // Compare `utf8` when the distinction matters.
        let vectors = try StableUUIDVectors.load()
        for stem in ["cafe", "zurich", "hangul"] {
            let nfc = try XCTUnwrap(vectors.first { $0.label == "nfc-\(stem)" })
            let nfd = try XCTUnwrap(vectors.first { $0.label == "nfd-\(stem)" })
            XCTAssertNotEqual(Array(nfc.input.utf8), Array(nfd.input.utf8),
                              "\(stem): fixture was normalized on disk")
            XCTAssertEqual(nfc.input, nfd.input,
                           "\(stem): Swift String equality is canonical — if this ever fails, "
                           + "the fixture no longer holds the same visible name")
            XCTAssertNotEqual(nfc.uuid, nfd.uuid, "\(stem): composed/decomposed must differ")
        }
    }

    func testProductionIDPathGoesThroughTheSameDerivation() throws {
        // `PhotoFile.stableID(for:)` standardizes then derives — proving the
        // vectors cover the real call site, not just the raw helper.
        let path = "/Users/j/Pictures/2024/IMG_0001.jpg"
        let expected = try XCTUnwrap(
            StableUUIDVectors.load().first { $0.label == "ascii-basic" }
        )
        XCTAssertEqual(expected.input, path)
        XCTAssertEqual(
            PhotoFile.stableID(for: URL(fileURLWithPath: path)).uuidString.lowercased(),
            expected.uuid
        )
    }
}
