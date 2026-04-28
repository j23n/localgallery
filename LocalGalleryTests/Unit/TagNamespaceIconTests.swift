import XCTest
@testable import LocalGallery

final class TagNamespaceIconTests: XCTestCase {

    // MARK: - Namespace icon

    func testEachKnownNamespaceMapsToItsIcon() {
        XCTAssertEqual(TagNamespace.icon(for: "People"), "person.fill")
        XCTAssertEqual(TagNamespace.icon(for: "Places"), "mappin.and.ellipse")
        XCTAssertEqual(TagNamespace.icon(for: "Landmarks"), "building.columns.fill")
        XCTAssertEqual(TagNamespace.icon(for: "Objects"), "cube.fill")
        XCTAssertEqual(TagNamespace.icon(for: "Scenes"), "mountain.2.fill")
        XCTAssertEqual(TagNamespace.icon(for: "Text"), "textformat")
    }

    func testNamespaceMatchIsCaseInsensitive() {
        XCTAssertEqual(TagNamespace.icon(for: "people"), "person.fill")
        XCTAssertEqual(TagNamespace.icon(for: "PLACES"), "mappin.and.ellipse")
    }

    func testUnknownAndNilNamespaceFallBackToTagIcon() {
        XCTAssertEqual(TagNamespace.icon(for: nil), "tag.fill")
        XCTAssertEqual(TagNamespace.icon(for: "Mood"), "tag.fill")
    }

    // MARK: - Places depth icon

    func testPlacesDepthZeroIsTheGenericPin() {
        XCTAssertEqual(TagNamespace.placesIcon(depth: 0), "mappin.and.ellipse")
        XCTAssertEqual(TagNamespace.placesIcon(depth: -1), "mappin.and.ellipse")
    }

    func testPlacesDepthsMapToFlagMapBuilding() {
        XCTAssertEqual(TagNamespace.placesIcon(depth: 1), "flag.fill")
        XCTAssertEqual(TagNamespace.placesIcon(depth: 2), "map.fill")
        XCTAssertEqual(TagNamespace.placesIcon(depth: 3), "building.2.fill")
    }

    func testDeeperDepthsFallBackToHouseIcon() {
        XCTAssertEqual(TagNamespace.placesIcon(depth: 4), "house.fill")
        XCTAssertEqual(TagNamespace.placesIcon(depth: 99), "house.fill")
    }

    // MARK: - TagSuggestion icon

    func testPlacesSuggestionPicksDepthSpecificIcon() {
        let italy = TagSuggestion(id: "places/italy", displayName: "Italy",
                                   fullPath: "Places/Italy", namespace: "Places", count: 3)
        XCTAssertEqual(italy.icon, "flag.fill") // depth 1 = country

        let lazio = TagSuggestion(id: "places/italy/lazio", displayName: "Lazio",
                                   fullPath: "Places/Italy/Lazio", namespace: "Places", count: 2)
        XCTAssertEqual(lazio.icon, "map.fill") // depth 2 = region

        let rome = TagSuggestion(id: "places/italy/lazio/rome", displayName: "Rome",
                                  fullPath: "Places/Italy/Lazio/Rome", namespace: "Places", count: 1)
        XCTAssertEqual(rome.icon, "building.2.fill") // depth 3 = city
    }

    func testNonPlacesSuggestionFallsBackToNamespaceIcon() {
        let person = TagSuggestion(id: "people/alice", displayName: "Alice",
                                    fullPath: "People/Alice", namespace: "People", count: 7)
        XCTAssertEqual(person.icon, "person.fill")
    }

    func testFlatSuggestionFallsBackToTagIcon() {
        let flat = TagSuggestion(id: "vacation", displayName: "Vacation",
                                  fullPath: "Vacation", namespace: nil, count: 1)
        XCTAssertEqual(flat.icon, "tag.fill")
    }
}
