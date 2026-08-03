import XCTest
@testable import LocalGallery

/// Toolchain smoke tests for the Rust core (Phase 0).
///
/// If these fail, suspect the build chain before the logic:
/// `./scripts/build_core.sh && xcodegen` regenerates the XCFramework and the
/// UniFFI bindings that `LocalGallery` compiles.
final class GalleryCoreFFITests: XCTestCase {

    func testCoreVersionCrossesTheBoundary() {
        // Proves the static library is actually linked: `coreVersion` is the
        // cheapest possible round trip through the FFI.
        let version = coreVersion()
        XCTAssertFalse(version.isEmpty)
        XCTAssertEqual(version.split(separator: ".").count, 3, "expected semver, got \(version)")
    }

    func testBindingsMatchTheLinkedBinary() {
        // UniFFI's contract-version + per-function checksum handshake. It
        // `fatalError`s on a mismatch, so this is a crash canary for "someone
        // changed core/ and forgot to re-run ./scripts/build_core.sh".
        uniffiEnsureGalleryFfiInitialized()
    }

    func testStableUuidRoundTripsUnicode() {
        // Strings cross the FFI as UTF-8 RustBuffers; a mangled encoding would
        // show up as a wrong hash rather than a crash, so pin one non-ASCII
        // input independently of the vector file.
        XCTAssertEqual(
            stableUuid(input: "/Users/j/Pictures/\u{5199}\u{771F}/IMG_0001.jpg"),
            StableUUID.derive(from: "/Users/j/Pictures/\u{5199}\u{771F}/IMG_0001.jpg")
                .uuidString.lowercased()
        )
    }

    /// The FFI is called from background work throughout the app (scanning,
    /// enrichment), so it has to be usable off the main actor from several
    /// concurrent contexts. Under `SWIFT_STRICT_CONCURRENCY: complete` this
    /// test failing to *compile* is as meaningful as it failing to run.
    func testFFIIsCallableFromConcurrentDetachedTasks() async throws {
        let vectors = try StableUUIDVectors.load()
        let expected = vectors.map(\.uuid)

        let tasks = (0..<8).map { _ in
            Task.detached(priority: .userInitiated) {
                vectors.map { stableUuid(input: $0.input) }
            }
        }

        for task in tasks {
            let results = await task.value
            XCTAssertEqual(results, expected)
        }
    }

    func testConcurrentCallsInterleaveWithoutCorruption() async {
        // Hammers the RustBuffer alloc/free path from many tasks at once: a
        // shared-state bug in the generated glue shows up as a mismatched or
        // truncated string here rather than as a rare crash in production.
        let inputs = (0..<200).map { "/Users/j/Pictures/2024/IMG_\($0).jpg" }
        let expected = inputs.map { StableUUID.derive(from: $0).uuidString.lowercased() }

        let results = await withTaskGroup(of: (Int, String).self) { group -> [Int: String] in
            for (index, input) in inputs.enumerated() {
                group.addTask { (index, stableUuid(input: input)) }
            }
            var collected: [Int: String] = [:]
            for await (index, uuid) in group { collected[index] = uuid }
            return collected
        }

        XCTAssertEqual(results.count, inputs.count)
        for (index, uuid) in results {
            XCTAssertEqual(uuid, expected[index], "input \(inputs[index])")
        }
    }
}
