import XCTest
@testable import LocalGallery

final class PeopleSectionTests: XCTestCase {
    func testNamedPeopleAreEnoughToShowTheSection() {
        XCTAssertTrue(PeopleSectionVisibility.shouldShow(
            namedPeople: 1, reviewableClusters: 0, scanning: false
        ))
    }

    func testUnnamedFaceGroupsShowTheSectionWhenNobodyIsNamed() {
        XCTAssertTrue(PeopleSectionVisibility.shouldShow(
            namedPeople: 0, reviewableClusters: 2, scanning: false
        ))
    }

    func testAScanInFlightShowsTheSectionBeforeClustersLand() {
        XCTAssertTrue(PeopleSectionVisibility.shouldShow(
            namedPeople: 0, reviewableClusters: 0, scanning: true
        ))
    }

    func testAnIdleLibraryWithNoPeopleHidesTheSection() {
        XCTAssertFalse(PeopleSectionVisibility.shouldShow(
            namedPeople: 0, reviewableClusters: 0, scanning: false
        ))
    }
}
