import XCTest
@testable import LocalGallery

final class WidgetDeepLinkTests: XCTestCase {

    // MARK: - memory

    func testMemoryRoundTrip() {
        let link = WidgetDeepLink.memory(id: "yearsAgo-5")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(WidgetDeepLink.parse(url), link)
    }

    func testMemoryEmptyIdReturnsNilURL() {
        XCTAssertNil(WidgetDeepLink.memory(id: "").url)
    }

    func testMemoryParseRejectsEmptyPath() {
        let url = URL(string: "localgallery://memory/")!
        XCTAssertNil(WidgetDeepLink.parse(url))
    }

    // MARK: - folder

    func testFolderRoundTrip() {
        let link = WidgetDeepLink.folder(id: "ABCD-1234")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(WidgetDeepLink.parse(url), link)
    }

    func testFolderEmptyIdReturnsNilURL() {
        XCTAssertNil(WidgetDeepLink.folder(id: "").url)
    }

    // MARK: - tags

    func testTagsSinglePathRoundTrip() {
        let link = WidgetDeepLink.tags(paths: ["People/Alice"])
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(WidgetDeepLink.parse(url), link)
    }

    func testTagsMultiplePathsRoundTrip() {
        let link = WidgetDeepLink.tags(paths: ["People/Alice", "Places/Italy/Rome"])
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(WidgetDeepLink.parse(url), link)
    }

    func testTagsCommaInPathSurvives() {
        // The original encoding joined on `,` and split on `,`, which silently
        // corrupted any tag containing a literal comma. Using repeated
        // `paths=` query items round-trips intact.
        let link = WidgetDeepLink.tags(paths: ["Places/Buenos Aires, AR"])
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(WidgetDeepLink.parse(url), link)
    }

    func testTagsLegacyCommaJoinedFormStillParses() {
        // Older widget instances may have built URLs with the comma-joined
        // form. Parser must keep accepting them until the user replaces the
        // widget.
        let url = URL(string: "localgallery://tags?paths=People/Alice,Places/Italy")!
        XCTAssertEqual(
            WidgetDeepLink.parse(url),
            .tags(paths: ["People/Alice", "Places/Italy"])
        )
    }

    func testTagsEmptyPathsReturnsNilURL() {
        XCTAssertNil(WidgetDeepLink.tags(paths: []).url)
    }

    func testTagsParseRejectsMissingQuery() {
        let url = URL(string: "localgallery://tags")!
        XCTAssertNil(WidgetDeepLink.parse(url))
    }

    // MARK: - bad input

    func testRejectsForeignScheme() {
        let url = URL(string: "https://example.com/memory/123")!
        XCTAssertNil(WidgetDeepLink.parse(url))
    }

    func testRejectsUnknownHost() {
        let url = URL(string: "localgallery://other/123")!
        XCTAssertNil(WidgetDeepLink.parse(url))
    }
}
