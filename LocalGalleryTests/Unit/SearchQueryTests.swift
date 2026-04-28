import XCTest
@testable import LocalGallery

/// `SearchIndex.search(query:requiredTags:allTags:)` is the single search
/// engine. Test it directly so we don't have to spin up a `GalleryStore` for
/// a stateless, deterministic query path.
@MainActor
final class SearchQueryTests: XCTestCase {

    private func indexWithLibrary() -> SearchIndex {
        let index = SearchIndex()
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
        return index
    }

    // MARK: - Empty query

    func testEmptyQueryReturnsAllPhotosNewestFirst() {
        let index = indexWithLibrary()
        let results = index.search(query: "", requiredTags: [], allTags: [])
        XCTAssertEqual(results.count, 3)
        // Newest-first order from sortPhotos.
        XCTAssertEqual(results.first?.filename, "Alice_Sunset")
        XCTAssertEqual(results.last?.filename, "IMG_001")
    }

    // MARK: - Filename match

    func testFilenameSubstringMatchIsCaseInsensitive() {
        let index = indexWithLibrary()
        let results = index.search(query: "mountain", requiredTags: [], allTags: [])
        XCTAssertEqual(results.map(\.filename), ["Mountain"])
    }

    func testFilenameMatchHandlesPartialMatches() {
        let index = indexWithLibrary()
        // "alice" appears in the filename "Alice_Sunset" and as a leaf tag —
        // either path produces a match through the search corpus.
        let results = index.search(query: "alice", requiredTags: [], allTags: [])
        XCTAssertEqual(Set(results.map(\.filename)), ["Alice_Sunset", "IMG_001"])
    }

    // MARK: - Tag content match

    func testTagDisplayNameSubstringMatches() {
        let index = indexWithLibrary()
        // "Rome" is the leaf of `Places/Italy/Rome` — substring should hit
        // the search corpus entry for that photo.
        let results = index.search(query: "rome", requiredTags: [], allTags: [])
        XCTAssertEqual(results.map(\.filename), ["IMG_001"])
    }

    func testTagFullPathSubstringMatches() {
        let index = indexWithLibrary()
        // "switzerland" appears as a parent segment, only through tag.fullPath.
        let results = index.search(query: "switzerland", requiredTags: [], allTags: [])
        XCTAssertEqual(results.map(\.filename), ["Mountain"])
    }

    // MARK: - No-match

    func testNoMatchProducesEmptyResults() {
        let index = indexWithLibrary()
        XCTAssertTrue(index.search(query: "spaceship", requiredTags: [], allTags: []).isEmpty)
    }

    // MARK: - Empty library

    func testEmptyLibraryReturnsEmptyForAnyQuery() {
        let index = SearchIndex()
        index.build(allPhotos: [])
        XCTAssertTrue(index.search(query: "", requiredTags: [], allTags: []).isEmpty)
        XCTAssertTrue(index.search(query: "anything", requiredTags: [], allTags: []).isEmpty)
    }
}
