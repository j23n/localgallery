import Foundation
import XCTest
@testable import LocalGallery

/// Empty successful sidecar values must retract stale tags / country / faces.
/// A failed or missing read must not, and a transient listing gap must not
/// look like a deletion when the store re-applies the cache.
@MainActor
final class SidecarMergeTests: XCTestCase {

    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    private func face(_ name: String) -> FaceRegion {
        FaceRegion(name: name, centerX: 0.5, centerY: 0.5, width: 0.1, height: 0.1)
    }

    // MARK: - Cache overlay (GalleryStore+Scanning)

    func testACachedEmptySidecarRetractsStaleFields() {
        var photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            tags: ["People/Ada"],
            countryCode: "IT"
        )
        photo.faceRegions = [face("Ada")]
        photo.sidecarStatus = .cached(.init(size: 40))

        let empty = SidecarCacheStore.CachedSidecar(
            version: .init(size: 8),
            hierarchicalTags: [],
            countryCode: nil,
            faceRegions: []
        )
        let merged = SidecarCacheMerge.apply(cached: empty, to: photo)
        XCTAssertTrue(merged.hierarchicalTags.isEmpty)
        XCTAssertNil(merged.countryCode)
        XCTAssertTrue(merged.faceRegions.isEmpty)
        XCTAssertEqual(merged.sidecarStatus, .cached(.init(size: 8)))
    }

    func testACacheHitReplacesRatherThanUnions() {
        var photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            tags: ["People/Ada"],
            countryCode: "IT"
        )
        photo.faceRegions = [face("Ada")]
        let cached = SidecarCacheStore.CachedSidecar(
            version: .init(size: 20),
            hierarchicalTags: [HierarchicalTag(raw: "People/Bea")],
            countryCode: "FR",
            faceRegions: [face("Bea")]
        )
        let merged = SidecarCacheMerge.apply(cached: cached, to: photo)
        XCTAssertEqual(merged.hierarchicalTags.map(\.fullPath), ["People/Bea"])
        XCTAssertEqual(merged.countryCode, "FR")
        XCTAssertEqual(merged.faceRegions.map(\.name), ["Bea"])
    }

    func testAConfirmedCacheDeletionRetractsPreviouslyCachedFields() {
        var photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            tags: ["People/Ada"],
            countryCode: "IT"
        )
        photo.faceRegions = [face("Ada")]
        photo.sidecarStatus = .cached(.init(size: 40))

        let merged = SidecarCacheMerge.apply(cached: nil, to: photo)
        XCTAssertTrue(merged.hierarchicalTags.isEmpty)
        XCTAssertNil(merged.countryCode)
        XCTAssertTrue(merged.faceRegions.isEmpty)
        XCTAssertEqual(merged.sidecarStatus, .absent)
    }

    func testANeverCachedPhotoKeepsEnrichmentValuesOnACacheMiss() {
        let photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            tags: ["Scenes/Beach"],
            countryCode: "ES"
        )
        XCTAssertEqual(photo.sidecarStatus, .absent)
        let merged = SidecarCacheMerge.apply(cached: nil, to: photo)
        XCTAssertEqual(merged.hierarchicalTags.map(\.fullPath), ["Scenes/Beach"])
        XCTAssertEqual(merged.countryCode, "ES")
        XCTAssertEqual(merged.sidecarStatus, .absent)
    }

    func testReapplySidecarMergesRetractsLivePhotos() {
        let harness = TestGalleryStore.make()
        addTeardownBlock { harness.teardown() }
        let url = URL(fileURLWithPath: "/library/a.jpg")
        var photo = PhotoFile.fixture(url: url, tags: ["People/Ada"], countryCode: "IT")
        photo.faceRegions = [face("Ada")]
        photo.sidecarStatus = .cached(.init(size: 10))
        let root = PhotoFolder.fixture(url: URL(fileURLWithPath: "/library"), photos: [photo])
        harness.store.apply(.scanResult(photos: [photo], root: root, persistCache: false))

        harness.store.sidecarCache.put(photo.id, SidecarCacheStore.CachedSidecar(
            version: .init(size: 11),
            hierarchicalTags: [],
            countryCode: nil,
            faceRegions: []
        ))
        harness.store.reapplySidecarMerges()

        XCTAssertEqual(harness.store.allPhotos.count, 1)
        let live = harness.store.allPhotos[0]
        XCTAssertTrue(live.hierarchicalTags.isEmpty)
        XCTAssertNil(live.countryCode)
        XCTAssertTrue(live.faceRegions.isEmpty)
    }

    // MARK: - EnrichmentService overlay

    func testSuccessfulEmptyReadRetractsStaleSidecarFields() {
        let fields = EnrichmentService.resolvedSidecarFields(
            existingTags: [HierarchicalTag(raw: "People/Ada")],
            existingCountry: "IT",
            existingFaces: [face("Ada")],
            readTags: [],
            readCountry: nil,
            readFaces: [],
            sidecarReadSucceeded: true
        )
        XCTAssertTrue(fields.tags.isEmpty)
        XCTAssertNil(fields.country)
        XCTAssertTrue(fields.faces.isEmpty)
    }

    func testFailedReadKeepsExistingSidecarFields() {
        let fields = EnrichmentService.resolvedSidecarFields(
            existingTags: [HierarchicalTag(raw: "People/Ada")],
            existingCountry: "IT",
            existingFaces: [face("Ada")],
            readTags: [],
            readCountry: nil,
            readFaces: [],
            sidecarReadSucceeded: false
        )
        XCTAssertEqual(fields.tags.map(\.fullPath), ["People/Ada"])
        XCTAssertEqual(fields.country, "IT")
        XCTAssertEqual(fields.faces.map(\.name), ["Ada"])
    }

    func testSuccessfulNonEmptyReadReplacesExistingFields() {
        let fields = EnrichmentService.resolvedSidecarFields(
            existingTags: [HierarchicalTag(raw: "People/Ada")],
            existingCountry: "IT",
            existingFaces: [face("Ada")],
            readTags: [HierarchicalTag(raw: "People/Bea")],
            readCountry: "FR",
            readFaces: [face("Bea")],
            sidecarReadSucceeded: true
        )
        XCTAssertEqual(fields.tags.map(\.fullPath), ["People/Bea"])
        XCTAssertEqual(fields.country, "FR")
        XCTAssertEqual(fields.faces.map(\.name), ["Bea"])
    }

    func testSidecarReadSucceededRequiresReadableBytes() throws {
        let temp = makeTemp()
        let image = temp.appending("photo.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data()))
        let missing = SidecarDocument.read(imagePath: image.path)
        XCTAssertFalse(missing.exists)
        XCTAssertFalse(EnrichmentService.sidecarReadSucceeded(missing))

        let xmp = URL(fileURLWithPath: image.path + ".xmp")
        try Data("<x:xmpmeta/>".utf8).write(to: xmp)
        let present = SidecarDocument.read(imagePath: image.path)
        XCTAssertTrue(present.exists)
        XCTAssertTrue(EnrichmentService.sidecarReadSucceeded(present))
    }

    /// End-to-end: enrichment of a stale photo with an empty sidecar must
    /// drop the in-memory tags, not keep them via the old fill-if-empty path.
    func testEnrichRetractsTagsFromASuccessfulEmptySidecar() async throws {
        let temp = makeTemp()
        let image = temp.appending("photo.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data("not-a-jpeg".utf8)))
        let xmp = URL(fileURLWithPath: image.path + ".xmp")
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'></x:xmpmeta>".utf8).write(to: xmp)

        var photo = PhotoFile.fixture(
            url: image,
            tags: ["People/Ada"],
            countryCode: "IT"
        )
        photo.faceRegions = [face("Ada")]
        XCTAssertNil(photo.enrichedFileDate)

        let enriched = await EnrichmentService.enrich(photos: [photo])
        XCTAssertTrue(enriched[0].hierarchicalTags.isEmpty, "empty sidecar left stale tags in place")
        XCTAssertNil(enriched[0].countryCode, "empty sidecar left a stale country")
        XCTAssertTrue(enriched[0].faceRegions.isEmpty, "empty sidecar left stale faces")
    }

    func testEnrichKeepsTagsWhenTheSidecarCannotBeRead() async {
        let temp = makeTemp()
        let image = temp.appending("photo.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data("not-a-jpeg".utf8)))

        var photo = PhotoFile.fixture(
            url: image,
            tags: ["People/Ada"],
            countryCode: "IT"
        )
        photo.faceRegions = [face("Ada")]

        let enriched = await EnrichmentService.enrich(photos: [photo])
        XCTAssertEqual(enriched[0].hierarchicalTags.map(\.fullPath), ["People/Ada"])
        XCTAssertEqual(enriched[0].countryCode, "IT")
        XCTAssertEqual(enriched[0].faceRegions.map(\.name), ["Ada"])
    }
}
