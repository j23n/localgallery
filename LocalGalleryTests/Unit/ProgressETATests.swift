import XCTest
@testable import LocalGallery

final class ProgressETATests: XCTestCase {
    func testCountTextOmitsETAUntilThroughputIsKnown() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ProgressETA.countText(processed: 0, total: 100, startedAt: start, now: start),
            "0 / 100"
        )
        XCTAssertEqual(
            ProgressETA.countText(
                processed: 10,
                total: 100,
                startedAt: start,
                now: start.addingTimeInterval(0.5)
            ),
            "10 / 100"
        )
    }

    func testCountTextAppendsRemainingTimeOnceASecondHasElapsed() {
        let start = Date(timeIntervalSince1970: 1_000)
        // 10 photos in 10s → 1/s → 90 remaining → ~1:30
        XCTAssertEqual(
            ProgressETA.countText(
                processed: 10,
                total: 100,
                startedAt: start,
                now: start.addingTimeInterval(10)
            ),
            "10 / 100 · ~1:30"
        )
    }

    func testCountTextUsesSecondsBelowAMinute() {
        let start = Date(timeIntervalSince1970: 1_000)
        // 50 in 10s → 5/s → 50 remaining → ~10s
        XCTAssertEqual(
            ProgressETA.countText(
                processed: 50,
                total: 100,
                startedAt: start,
                now: start.addingTimeInterval(10)
            ),
            "50 / 100 · ~10s"
        )
    }

    func testCountTextUsesHoursAfterAnHour() {
        XCTAssertEqual(ProgressETA.formatRemaining(3600), "~1h")
        XCTAssertEqual(ProgressETA.formatRemaining(4320), "~1h 12m")
        XCTAssertEqual(ProgressETA.formatRemaining(90), "~1:30")
        XCTAssertEqual(ProgressETA.formatRemaining(12), "~12s")
    }

    func testCountTextWithUnknownTotalIsJustTheCount() {
        XCTAssertEqual(
            ProgressETA.countText(
                processed: 12,
                total: 0,
                startedAt: Date(timeIntervalSince1970: 0),
                now: Date(timeIntervalSince1970: 10)
            ),
            "12"
        )
    }
}
