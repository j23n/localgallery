import SwiftUI

// MARK: - Design Tokens (Quiet direction)

enum Design {
    // Warm, stock-adjacent palette (#FAF7F2 canvas, muted amber accent).
    static let accentColor  = Color("AccentColor")
    static let accentSoft   = Color("AccentColor").opacity(0.13)

    static let bg           = Color(red: 0.980, green: 0.969, blue: 0.949)  // #FAF7F2
    static let bgCard       = Color.white                                    // #FFFFFF
    static let bgGrouped    = Color(red: 0.949, green: 0.929, blue: 0.898)  // #F2EDE5

    static let ink          = Color(red: 0.110, green: 0.102, blue: 0.086)  // #1C1A16
    static let ink2         = Color(red: 0.369, green: 0.341, blue: 0.302)  // #5E574D
    static let ink3         = Color(red: 0.584, green: 0.553, blue: 0.510)  // #958D82
    static let separator    = Color(red: 0.235, green: 0.216, blue: 0.176).opacity(0.10)

    static let destructive  = Color(red: 0.698, green: 0.290, blue: 0.227)  // #B24A3A

    static let cardRadius: CGFloat = 14
    static let memoryRadius: CGFloat = 20

    /// Newsreader italic stand-in (system serif italic) — used for memory titles.
    static func serifItalic(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).italic()
    }
}

extension View {
    /// Soft gradient fade at the top edge of the enclosing scroll view so
    /// content dissolves into the nav bar (iOS 26+ — no-op on older OSes).
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
