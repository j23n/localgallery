import Foundation
import XCTest
@testable import LocalGallery

/// The bundled pack, end to end: it is in the built app, the production path
/// finds it, and the core verifies its declared hashes.
///
/// Everything else about packs is tested against the ~16 KB committed test
/// pack (`PackResolverTests`, `TaggingServiceTests`). This is the one check
/// that the *real* thing shipped, which nothing smaller can answer: the pack is
/// git-ignored, so only the built app knows whether it is there.
///
/// **Skipped, not failed, when it is absent.** A checkout that has not run
/// `scripts/prepare_pack.sh` still runs the suite green — the script itself is
/// what makes a missing pack loud, at the start of a build rather than here.
@MainActor
final class BundledModelPackTests: XCTestCase {
    /// The packs inside the app bundle, or a skip when this build has none.
    ///
    /// Both halves of "none" skip, because both mean the same thing — nobody
    /// staged a pack. `build/pack` missing entirely leaves
    /// `bundledModelPackURL` nil; `build/pack` present but empty (xcodegen
    /// needs the path to exist, so an unstaged tree can still carry an empty
    /// one) leaves the root there with nothing in it.
    ///
    /// Read through `GalleryPaths.production` rather than `Bundle.main`
    /// directly, so this also proves the path the app actually uses resolves.
    private func bundledPacks() throws -> (root: URL, candidates: [URL]) {
        let skip = XCTSkip(
            "this build bundles no model pack — run ./scripts/prepare_pack.sh, then xcodegen"
        )
        guard let root = GalleryPaths.production.bundledModelPackURL else { throw skip }
        let candidates = PackResolver.candidates(in: root)
        if candidates.isEmpty { throw skip }
        return (root, candidates)
    }

    func testTheBundledPackResolvesAndVerifies() async throws {
        let candidates = try bundledPacks().candidates
        XCTAssertEqual(
            candidates.count, 1,
            "build/pack must hold exactly one pack directory, got \(candidates.map(\.lastPathComponent))"
        )

        let resolved = try XCTUnwrap(PackResolver.resolve(bundled: candidates, imported: []))
        XCTAssertEqual(resolved.source, .bundled)

        // The real verification: every file the manifest declares is present
        // and hashes to what it claims. This is the same call the app makes
        // before it opens a session.
        let dir = resolved.directory
        let info = try await Task.detached(priority: .userInitiated) {
            try inspectModelPack(modelPackDir: dir.path)
        }.value
        XCTAssertFalse(info.version.isEmpty)
        XCTAssertGreaterThan(
            info.labelCount, 0, "a pack with no labels can tag nothing"
        )
        XCTAssertEqual(
            info.version, dir.lastPathComponent,
            "the staged directory name and the manifest's pack version disagree, so the resolver would order this pack by a version it does not have"
        )
    }

    /// A fresh install must be able to tag with no import step — that is the
    /// point of shipping a pack. The bundled one is the only pack a clean
    /// simulator has.
    func testAFreshInstallHasATaggingCapablePack() async throws {
        let root = try bundledPacks().root
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }

        let service = TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            // Empty, as on a device where the user has imported nothing.
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true),
            bundledPackDirectory: root,
            refresh: SidecarRefreshCoalescer(interval: TaggingService.refreshInterval)
        )

        await service.refreshAvailability()
        XCTAssertTrue(service.isAvailable)
        XCTAssertTrue(service.hasBundledPack)
        XCTAssertEqual(service.pack?.source, .bundled)
    }
}
