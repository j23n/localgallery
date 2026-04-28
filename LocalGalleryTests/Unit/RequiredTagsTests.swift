import XCTest
@testable import LocalGallery

@MainActor
final class RequiredTagsTests: XCTestCase {

    private func suggestion(_ path: String, count: Int = 1) -> TagSuggestion {
        let tag = HierarchicalTag(raw: path)
        return TagSuggestion(
            id: tag.fullPath.lowercased(),
            displayName: tag.displayName,
            fullPath: tag.fullPath,
            namespace: tag.namespace,
            count: count
        )
    }

    private func indexWithLibrary() -> SearchIndex {
        let index = SearchIndex()
        let romeWithAlice = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/Trip/rome.jpg"),
            filename: "rome",
            dateTaken: date(2024, 6, 1),
            tags: ["Places/Italy/Lazio/Rome", "People/Alice"]
        )
        let milanWithBob = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/Trip/milan.jpg"),
            filename: "milan",
            dateTaken: date(2024, 6, 5),
            tags: ["Places/Italy/Lombardy/Milan", "People/Bob"]
        )
        let zurichWithAlice = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/Trip/zurich.jpg"),
            filename: "zurich",
            dateTaken: date(2024, 7, 1),
            tags: ["Places/Switzerland/Zurich", "People/Alice"]
        )
        index.build(allPhotos: [romeWithAlice, milanWithBob, zurichWithAlice])
        return index
    }

    // MARK: - Single tag

    func testSinglePeopleTagFiltersExactPath() {
        let index = indexWithLibrary()
        let alice = suggestion("People/Alice")
        let results = index.search(query: "", requiredTags: [alice], allTags: [])
        XCTAssertEqual(Set(results.map(\.filename)), ["rome", "zurich"])
    }

    // MARK: - Places prefix matching

    func testPlacesParentMatchesAllNestedLeaves() {
        let index = indexWithLibrary()
        let italy = suggestion("Places/Italy")
        let results = index.search(query: "", requiredTags: [italy], allTags: [])
        XCTAssertEqual(Set(results.map(\.filename)), ["rome", "milan"])
    }

    func testPlacesRegionMatchesAllChildCities() {
        let index = indexWithLibrary()
        let lazio = suggestion("Places/Italy/Lazio")
        let results = index.search(query: "", requiredTags: [lazio], allTags: [])
        XCTAssertEqual(results.map(\.filename), ["rome"])
    }

    // MARK: - AND across multiple tags

    func testMultipleTagsAreAndedTogether() {
        let index = indexWithLibrary()
        let italy = suggestion("Places/Italy")
        let alice = suggestion("People/Alice")
        let results = index.search(query: "", requiredTags: [italy, alice], allTags: [])
        XCTAssertEqual(results.map(\.filename), ["rome"])
    }

    func testNoPhotoMatchesAllRequiredTagsYieldsEmptyResult() {
        let index = indexWithLibrary()
        // No photo carries Bob in Switzerland.
        let switzerland = suggestion("Places/Switzerland")
        let bob = suggestion("People/Bob")
        let results = index.search(query: "", requiredTags: [switzerland, bob], allTags: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - People is exact path, not prefix

    func testPeopleTagDoesNotMatchByPrefix() {
        // A photo tagged `People/Alice/Daughter` should NOT be returned by
        // `People/Alice` — People uses exact-path semantics, not prefix.
        let index = SearchIndex()
        let parent = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/p/parent.jpg"),
            filename: "parent",
            dateTaken: date(2024, 1, 1),
            tags: ["People/Alice"]
        )
        let nested = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/p/nested.jpg"),
            filename: "nested",
            dateTaken: date(2024, 1, 2),
            tags: ["People/Alice/Daughter"]
        )
        index.build(allPhotos: [parent, nested])

        let alice = suggestion("People/Alice")
        let results = index.search(query: "", requiredTags: [alice], allTags: [])
        XCTAssertEqual(results.map(\.filename), ["parent"])
    }
}
