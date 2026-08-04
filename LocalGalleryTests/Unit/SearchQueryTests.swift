import XCTest
@testable import LocalGallery

/// `CoreLibraryIndex.search(query:requiredTags:)` is the single search entry
/// point — the matching itself is the Rust core's since Phase 4. Test it
/// directly so we don't have to spin up a `GalleryStore` for a deterministic
/// query path. The Unicode and virtual-tag edges are in `IndexConformanceTests`.
@MainActor
final class SearchQueryTests: XCTestCase {

    private func indexWithLibrary() async -> CoreLibraryIndex {
        let index = CoreLibraryIndex()
        let beach = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/Beach/IMG_001.jpg"),
            filename: "IMG_001",
            dateTaken: date(2024, 6, 1),
            tags: ["Places/Italy/Rome", "People/Alice"]
        )
        let mountain = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/Hike/Mountain.jpg"),
            filename: "Mountain",
            dateTaken: date(2024, 7, 4),
            tags: ["Places/Switzerland/Bern"]
        )
        let portrait = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/Portraits/Alice_Sunset.jpg"),
            filename: "Alice_Sunset",
            dateTaken: date(2024, 8, 15),
            tags: ["People/Alice"]
        )
        index.build(allPhotos: [beach, mountain, portrait])
        await index.settle()
        return index
    }

    // MARK: - Empty query

    func testEmptyQueryReturnsAllPhotosNewestFirst() async {
        let index = await indexWithLibrary()
        let results = index.search(query: "")
        XCTAssertEqual(results.count, 3)
        // Newest-first order from sortPhotos.
        XCTAssertEqual(results.first?.filename, "Alice_Sunset")
        XCTAssertEqual(results.last?.filename, "IMG_001")
    }

    // MARK: - Filename match

    func testFilenameSubstringMatchIsCaseInsensitive() async {
        let index = await indexWithLibrary()
        let results = index.search(query: "mountain")
        XCTAssertEqual(results.map(\.filename), ["Mountain"])
    }

    func testFilenameMatchHandlesPartialMatches() async {
        let index = await indexWithLibrary()
        // "alice" appears in the filename "Alice_Sunset" and as a leaf tag —
        // either path produces a match through the search corpus.
        let results = index.search(query: "alice")
        XCTAssertEqual(Set(results.map(\.filename)), ["Alice_Sunset", "IMG_001"])
    }

    // MARK: - Tag content match

    func testTagDisplayNameSubstringMatches() async {
        let index = await indexWithLibrary()
        // "Rome" is the leaf of `Places/Italy/Rome` — substring should hit
        // the search corpus entry for that photo.
        let results = index.search(query: "rome")
        XCTAssertEqual(results.map(\.filename), ["IMG_001"])
    }

    func testTagFullPathSubstringMatches() async {
        let index = await indexWithLibrary()
        // "switzerland" appears as a parent segment, only through tag.fullPath.
        let results = index.search(query: "switzerland")
        XCTAssertEqual(results.map(\.filename), ["Mountain"])
    }

    // MARK: - No-match

    func testNoMatchProducesEmptyResults() async {
        let index = await indexWithLibrary()
        XCTAssertTrue(index.search(query: "spaceship").isEmpty)
    }

    // MARK: - Empty library

    func testEmptyLibraryReturnsEmptyForAnyQuery() async {
        let index = CoreLibraryIndex()
        index.build(allPhotos: [])
        await index.settle()
        XCTAssertTrue(index.search(query: "").isEmpty)
        XCTAssertTrue(index.search(query: "anything").isEmpty)
    }
}
