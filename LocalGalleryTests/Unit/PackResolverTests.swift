import Foundation
import XCTest
@testable import LocalGallery

/// Which model pack the app uses, given the bundled one and whatever the user
/// imported.
///
/// Directories only — no model bytes. That is the reason resolution is a
/// separate type: the rule has to be testable without a 157 MB pack.
@MainActor
final class PackResolverTests: XCTestCase {
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    /// A pack directory: a folder with a `manifest.json` in it. Nothing reads
    /// the manifest here — resolution is name order plus existence.
    @discardableResult
    private func makePack(_ name: String, in root: URL, manifest: Bool = true) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if manifest {
            try Data("{}".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        }
        return dir
    }

    private func roots(_ temp: TempDir) throws -> (bundled: URL, imported: URL) {
        let bundled = temp.appending("bundle", isDirectory: true)
        let imported = temp.appending("ModelPacks", isDirectory: true)
        for dir in [bundled, imported] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (bundled, imported)
    }

    private func resolve(_ temp: TempDir, _ roots: (bundled: URL, imported: URL))
        -> PackResolver.Resolution?
    {
        PackResolver.resolve(
            bundled: PackResolver.candidates(in: roots.bundled),
            imported: PackResolver.candidates(in: roots.imported)
        )
    }

    // MARK: - Which pack wins

    func testNoPacksAnywhereResolvesToNothing() throws {
        let temp = makeTemp()
        XCTAssertNil(resolve(temp, try roots(temp)))
    }

    func testTheBundledPackIsUsedWhenNothingWasImported() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        let bundled = try makePack("mobileclip-s2-v1", in: roots.bundled)

        let resolved = resolve(temp, roots)
        XCTAssertEqual(resolved?.directory, bundled)
        XCTAssertEqual(resolved?.source, .bundled)
    }

    func testAnImportedPackIsUsedWhenTheBuildBundlesNone() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        let imported = try makePack("mobileclip-s2-v1", in: roots.imported)

        let resolved = resolve(temp, roots)
        XCTAssertEqual(resolved?.directory, imported)
        XCTAssertEqual(resolved?.source, .imported)
    }

    func testANewerImportedPackBeatsTheBundledOne() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        try makePack("mobileclip-s2-v1", in: roots.bundled)
        let imported = try makePack("mobileclip-s2-v2", in: roots.imported)

        let resolved = resolve(temp, roots)
        XCTAssertEqual(resolved?.directory, imported)
        XCTAssertEqual(resolved?.source, .imported)
    }

    /// The reason precedence is not "imported always wins": an app update ships
    /// a newer pack, and a pack imported once must not shadow it forever with
    /// nothing to tell the user why tagging never improved.
    func testANewerBundledPackBeatsAStaleImportedOne() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        let bundled = try makePack("mobileclip-s2-v2", in: roots.bundled)
        try makePack("mobileclip-s2-v1", in: roots.imported)

        let resolved = resolve(temp, roots)
        XCTAssertEqual(resolved?.directory, bundled)
        XCTAssertEqual(resolved?.source, .bundled)
    }

    /// Equal versions go to the imported copy: installing it was deliberate,
    /// and it is also how a user substitutes a licence-clean face pack of their
    /// own for the bundled one.
    func testEqualVersionsGoToTheImportedCopy() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        try makePack("mobileclip-s2-v1", in: roots.bundled)
        let imported = try makePack("mobileclip-s2-v1", in: roots.imported)

        let resolved = resolve(temp, roots)
        XCTAssertEqual(resolved?.directory, imported)
        XCTAssertEqual(resolved?.source, .imported)
    }

    /// Plain lexicographic order ranks `-v1.9` above `-v1.10`, which would pin
    /// the app to the ninth pack forever. This is why the comparison is
    /// `.numeric`.
    func testVersionOrderIsNumericNotLexicographic() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        try makePack("mobileclip-s2-v1.9", in: roots.imported)
        let newest = try makePack("mobileclip-s2-v1.10", in: roots.imported)

        XCTAssertEqual(resolve(temp, roots)?.directory, newest)
    }

    // MARK: - What counts as a pack

    /// An empty `build/pack` (the resource exists, `prepare_pack.sh` never
    /// ran) or a folder the user picked by mistake is not a pack, and must not
    /// win over a real one.
    func testADirectoryWithoutAManifestIsNotAPack() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        try makePack("mobileclip-s2-v9", in: roots.imported, manifest: false)
        let real = try makePack("mobileclip-s2-v1", in: roots.bundled)

        let resolved = resolve(temp, roots)
        XCTAssertEqual(resolved?.directory, real)
        XCTAssertEqual(resolved?.source, .bundled)
    }

    func testCandidatesOfAMissingRootIsEmpty() {
        let temp = makeTemp()
        XCTAssertEqual(PackResolver.candidates(in: temp.appending("nope", isDirectory: true)), [])
        XCTAssertEqual(PackResolver.candidates(in: nil), [])
    }

    /// A loose file next to the pack directories — `.DS_Store`, a downloaded
    /// zip — is not a candidate.
    func testALooseFileIsNotAPack() throws {
        let temp = makeTemp()
        let roots = try roots(temp)
        try Data("x".utf8).write(to: roots.imported.appendingPathComponent("manifest.json"))
        try makePack("mobileclip-s2-v1", in: roots.bundled)

        XCTAssertEqual(PackResolver.candidates(in: roots.imported), [])
        XCTAssertEqual(resolve(temp, roots)?.source, .bundled)
    }
}
