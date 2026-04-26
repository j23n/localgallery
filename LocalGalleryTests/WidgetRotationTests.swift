import XCTest
@testable import LocalGallery

final class WidgetRotationTests: XCTestCase {

    // MARK: - Determinism

    func testSameSeedSameOrder() {
        let a = pickRotation(count: 50, slots: 12, seed: "test")
        let b = pickRotation(count: 50, slots: 12, seed: "test")
        XCTAssertEqual(a, b)
    }

    func testDifferentSeedsDifferentOrder() {
        let a = pickRotation(count: 50, slots: 12, seed: "alpha")
        let b = pickRotation(count: 50, slots: 12, seed: "beta")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Edge cases

    func testZeroCountReturnsEmpty() {
        XCTAssertTrue(pickRotation(count: 0, slots: 12, seed: "x").isEmpty)
    }

    func testZeroSlotsReturnsEmpty() {
        XCTAssertTrue(pickRotation(count: 50, slots: 0, seed: "x").isEmpty)
    }

    func testSlotsLessThanCountIsAPermutationPrefix() {
        let result = pickRotation(count: 20, slots: 8, seed: "x")
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(Set(result).count, 8, "slots <= count → no repeats")
        XCTAssertTrue(result.allSatisfy { $0 < 20 })
    }

    func testSlotsGreaterThanCountFillsToSlots() {
        let result = pickRotation(count: 3, slots: 12, seed: "x")
        XCTAssertEqual(result.count, 12)
        XCTAssertTrue(result.allSatisfy { $0 < 3 })
    }

    func testNoBackToBackRepeatsAtReshuffleBoundary() {
        // count == 2 forces multiple re-shuffles to fill 12 slots; the
        // boundary protection should keep adjacent slots distinct.
        for seed in ["a", "b", "boundary-test", "longer seed value"] {
            let result = pickRotation(count: 2, slots: 12, seed: seed)
            for i in 1..<result.count {
                XCTAssertNotEqual(
                    result[i], result[i - 1],
                    "back-to-back repeat at index \(i) for seed=\(seed)"
                )
            }
        }
    }

    func testCountOneAlwaysReturnsZero() {
        // With only one element, repeats are unavoidable.
        let result = pickRotation(count: 1, slots: 5, seed: "x")
        XCTAssertEqual(result, [0, 0, 0, 0, 0])
    }

    // MARK: - Day key

    func testDayKeyIsStableForGivenDate() {
        let comps = DateComponents(year: 2026, month: 4, day: 26)
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(WidgetDayKey.string(for: date), "2026-04-26")
    }

    func testDayKeyDiffersAcrossDays() {
        let cal = Calendar.current
        let d1 = cal.date(from: DateComponents(year: 2026, month: 4, day: 26))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 4, day: 27))!
        XCTAssertNotEqual(WidgetDayKey.string(for: d1), WidgetDayKey.string(for: d2))
    }

    // MARK: - SeededRNG

    func testSeededRNGIsDeterministic() {
        var a = SeededRNG(seed: "rng-test")
        var b = SeededRNG(seed: "rng-test")
        for _ in 0..<10 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testSeededRNGDiffersBySeed() {
        var a = SeededRNG(seed: "alpha")
        var b = SeededRNG(seed: "beta")
        XCTAssertNotEqual(a.next(), b.next())
    }
}
