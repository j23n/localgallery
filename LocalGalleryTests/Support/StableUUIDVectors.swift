import Foundation
import XCTest

/// The `StableUUID` conformance vectors, shared with the Rust core.
///
/// One file, two readers: this loader (bundled as a test resource) and
/// `core/gallery-model/tests/stable_uuid_vectors.rs` (read from the repo by
/// relative path). Regenerate with `swift scripts/gen_stable_uuid_vectors.swift`
/// — and expect to justify why, because changing a vector means every photo id
/// in every existing library changes too.
enum StableUUIDVectors {

    struct Vector: Decodable, Sendable {
        /// Stable, readable name — the inputs include NFC/NFD pairs that are
        /// indistinguishable in a failure message.
        let label: String
        let input: String
        /// Lowercase hyphenated; Swift's `UUID.uuidString` is uppercase, so
        /// compare with `.lowercased()`.
        let uuid: String
    }

    static func load(file: StaticString = #filePath, line: UInt = #line) throws -> [Vector] {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "stable_uuid_vectors", withExtension: "json") else {
            XCTFail("stable_uuid_vectors.json is missing from the test bundle", file: file, line: line)
            return []
        }
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    private final class BundleToken {}
}
