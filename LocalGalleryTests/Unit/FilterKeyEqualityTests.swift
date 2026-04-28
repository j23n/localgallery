import XCTest
@testable import LocalGallery

/// `FilterKey` is the identity used by `.task(id:)` to drive the filter
/// recompute on `PhotoGridScreen`. If equality misfires we either re-run
/// the filter on every body re-evaluation (over-firing) or fail to refresh
/// when search/tags change (under-firing).
final class FilterKeyEqualityTests: XCTestCase {

    private func key(
        count: Int = 10,
        firstDate: Date? = nil,
        lastDate: Date? = nil,
        query: String = "",
        activeTagIDs: [String] = []
    ) -> PhotoGridScreen.FilterKey {
        PhotoGridScreen.FilterKey(
            count: count,
            firstDate: firstDate,
            lastDate: lastDate,
            query: query,
            activeTagIDs: activeTagIDs
        )
    }

    func testIdenticalInputsAreEqual() {
        XCTAssertEqual(key(), key())
    }

    func testDifferentCountIsNotEqual() {
        XCTAssertNotEqual(key(count: 10), key(count: 11))
    }

    func testDifferentQueryIsNotEqual() {
        XCTAssertNotEqual(key(query: "rome"), key(query: "milan"))
    }

    func testDifferentTagSetIsNotEqual() {
        XCTAssertNotEqual(key(activeTagIDs: ["a"]), key(activeTagIDs: ["a", "b"]))
    }

    func testDifferentDateRangeIsNotEqual() {
        let a = key(firstDate: date(2024, 1, 1), lastDate: date(2024, 12, 31))
        let b = key(firstDate: date(2024, 1, 1), lastDate: date(2025, 12, 31))
        XCTAssertNotEqual(a, b)
    }

    func testTagOrderMatters() {
        // activeTagIDs is an `[String]`, not a `Set` — re-ordering active
        // tags changes the key. That's intentional: re-ordering happens via
        // explicit user action and should refresh the grid.
        XCTAssertNotEqual(
            key(activeTagIDs: ["a", "b"]),
            key(activeTagIDs: ["b", "a"])
        )
    }

    func testWhitespaceOnlyDifferenceIsAStringDifference() {
        // FilterKey doesn't trim — the caller is responsible for that. This
        // test pins the contract so changing it is a deliberate decision.
        XCTAssertNotEqual(key(query: "rome"), key(query: " rome "))
    }
}
