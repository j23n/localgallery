import SwiftUI

struct GridLayoutConfig {
    let sizeTier: Int

    var targetCellSize: CGFloat {
        switch sizeTier {
        case 0: return 130  // large
        case 1: return 100  // medium
        default: return 78  // small
        }
    }

    func columnCount(for width: CGFloat) -> Int {
        max(2, Int((width + 2) / (targetCellSize + 2)))
    }

    func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount(for: width))
    }

    func cellSize(for width: CGFloat) -> CGFloat {
        let cols = columnCount(for: width)
        return max(1, (width - CGFloat(cols - 1) * 2) / CGFloat(cols))
    }

    var gridIconName: String {
        switch sizeTier {
        case 0: return "square.grid.3x3"
        case 1: return "square.grid.3x3.fill"
        default: return "square.grid.4x3.fill"
        }
    }

    static func cycleSizeTier(_ tier: inout Int) {
        tier = (tier + 1) % 3
    }
}
