import XCTest
@testable import LocalGallery

final class GridLayoutConfigTests: XCTestCase {

    // MARK: - Column counts (portrait vs landscape × 4 tiers)

    func testPortraitColumnCountAcrossTiers() {
        XCTAssertEqual(GridLayoutConfig(sizeTier: 0, isLandscape: false).columnCount, 2)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 1, isLandscape: false).columnCount, 3)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 2, isLandscape: false).columnCount, 4)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 3, isLandscape: false).columnCount, 5)
    }

    func testLandscapeColumnCountAcrossTiers() {
        XCTAssertEqual(GridLayoutConfig(sizeTier: 0, isLandscape: true).columnCount, 3)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 1, isLandscape: true).columnCount, 5)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 2, isLandscape: true).columnCount, 7)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 3, isLandscape: true).columnCount, 9)
    }

    func testTierClampsAtTopAndBottom() {
        // Out-of-range tiers shouldn't crash — clamp into the table bounds.
        XCTAssertEqual(GridLayoutConfig(sizeTier: -10, isLandscape: false).columnCount, 2)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 99, isLandscape: false).columnCount, 5)
        XCTAssertEqual(GridLayoutConfig(sizeTier: 99, isLandscape: true).columnCount, 9)
    }

    // MARK: - Cell size math

    func testCellSizeAccountsFor2pxSpacingPerGap() {
        let config = GridLayoutConfig(sizeTier: 1, isLandscape: false) // 3 columns
        // 3 columns → 2 gaps of 2px → 396 / 3 = 132
        XCTAssertEqual(config.cellSize(for: 400), 132)
    }

    func testCellSizeNeverGoesBelowOnePoint() {
        // Width too small to fit gaps + cells → should clamp to 1, not produce
        // a negative or zero cell.
        let config = GridLayoutConfig(sizeTier: 3, isLandscape: true) // 9 columns
        XCTAssertEqual(config.cellSize(for: 0), 1)
    }

    // MARK: - Column array

    func testColumnsArrayMatchesColumnCount() {
        let config = GridLayoutConfig(sizeTier: 2, isLandscape: false)
        XCTAssertEqual(config.columns(for: 800).count, config.columnCount)
    }

    // MARK: - Grid icon

    func testIconNamePerTier() {
        XCTAssertEqual(GridLayoutConfig(sizeTier: 0, isLandscape: false).gridIconName,
                       "square.grid.2x2")
        XCTAssertEqual(GridLayoutConfig(sizeTier: 1, isLandscape: false).gridIconName,
                       "square.grid.3x3")
        XCTAssertEqual(GridLayoutConfig(sizeTier: 2, isLandscape: false).gridIconName,
                       "square.grid.3x3.fill")
        XCTAssertEqual(GridLayoutConfig(sizeTier: 3, isLandscape: false).gridIconName,
                       "square.grid.4x3.fill")
        // Anything past the explicit cases falls into the default branch.
        XCTAssertEqual(GridLayoutConfig(sizeTier: 99, isLandscape: false).gridIconName,
                       "square.grid.4x3.fill")
    }
}
