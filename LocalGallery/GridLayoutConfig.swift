import SwiftUI

struct GridLayoutConfig {
    let sizeTier: Int
    let isLandscape: Bool

    static let tierCount = 4

    private static let portraitColumns = [2, 3, 4, 5]
    private static let landscapeColumns = [3, 5, 7, 9]

    var columnCount: Int {
        let table = isLandscape ? Self.landscapeColumns : Self.portraitColumns
        let idx = min(max(sizeTier, 0), table.count - 1)
        return table[idx]
    }

    func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    func cellSize(for width: CGFloat) -> CGFloat {
        let cols = columnCount
        return max(1, (width - CGFloat(cols - 1) * 2) / CGFloat(cols))
    }

    var gridIconName: String {
        switch sizeTier {
        case 0: return "square.grid.2x2"
        case 1: return "square.grid.3x3"
        case 2: return "square.grid.3x3.fill"
        default: return "square.grid.4x3.fill"
        }
    }
}
