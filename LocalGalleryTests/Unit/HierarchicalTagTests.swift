import XCTest
@testable import LocalGallery

final class HierarchicalTagTests: XCTestCase {

    // MARK: - Path parsing

    func testFlatTagHasNoNamespace() {
        let tag = HierarchicalTag(raw: "Vacation")
        XCTAssertEqual(tag.fullPath, "Vacation")
        XCTAssertNil(tag.namespace)
        XCTAssertEqual(tag.displayName, "Vacation")
    }

    func testTwoSegmentTagSplitsNamespaceAndDisplay() {
        let tag = HierarchicalTag(raw: "People/Johannes")
        XCTAssertEqual(tag.fullPath, "People/Johannes")
        XCTAssertEqual(tag.namespace, "People")
        XCTAssertEqual(tag.displayName, "Johannes")
    }

    func testDeepPlacesTagKeepsNamespaceAndLeaf() {
        let tag = HierarchicalTag(raw: "Places/Italy/Lazio/Rome")
        XCTAssertEqual(tag.fullPath, "Places/Italy/Lazio/Rome")
        XCTAssertEqual(tag.namespace, "Places")
        XCTAssertEqual(tag.displayName, "Rome")
    }

    func testNamespaceCapitalizationIsPreserved() {
        // Tag namespaces are written by photo-tools in TitleCase. The parser
        // doesn't lowercase them — downstream code (TagNamespace.icon) is
        // case-insensitive instead.
        let tag = HierarchicalTag(raw: "places/italy")
        XCTAssertEqual(tag.namespace, "places")
    }

    // MARK: - Namespace mapping

    func testRecognisedNamespacesPickEachIcon() {
        XCTAssertEqual(HierarchicalTag(raw: "People/Alice").namespace, "People")
        XCTAssertEqual(HierarchicalTag(raw: "Places/Italy").namespace, "Places")
        XCTAssertEqual(HierarchicalTag(raw: "Landmarks/Colosseum").namespace, "Landmarks")
        XCTAssertEqual(HierarchicalTag(raw: "Events/Wedding").namespace, "Events")
        XCTAssertEqual(HierarchicalTag(raw: "Objects/Camera").namespace, "Objects")
    }

    // MARK: - Direct memberwise init

    func testDirectInitPreservesProvidedValues() {
        let tag = HierarchicalTag(fullPath: "Custom/Path", namespace: "Custom", displayName: "Path")
        XCTAssertEqual(tag.fullPath, "Custom/Path")
        XCTAssertEqual(tag.namespace, "Custom")
        XCTAssertEqual(tag.displayName, "Path")
    }
}
