import SwiftUI
import WidgetKit

/// Single hero-photo layout used by all three widgets across all sizes.
/// Differs only in font sizing per family.
struct WidgetHeroView: View {
    @Environment(\.widgetFamily) private var family
    let image: UIImage?
    let title: String
    let subtitle: String?
    /// When non-nil, an SF Symbol is rendered above the title (e.g. "gift" for birthdays).
    let glyph: String?

    init(image: UIImage?, title: String, subtitle: String? = nil, glyph: String? = nil) {
        self.image = image
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            captionOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var background: some View {
        if let image {
            // `.fill` + explicit max-frame + `.clipped()` is the canonical
            // edge-to-edge pattern. Without the frame, SwiftUI may resolve the
            // image's intrinsic size and leave the widget's black container
            // background visible as letterbox bars when the source aspect
            // ratio differs from the widget family's.
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var captionOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(titleFont)
                .foregroundStyle(.white)
                .lineLimit(family == .systemSmall ? 2 : 1)
                .minimumScaleFactor(0.8)
            if family != .systemSmall, let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(subtitleFont)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(captionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: gradientHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        )
    }

    private var titleFont: Font {
        switch family {
        case .systemSmall:  return .system(size: 13, weight: .semibold, design: .serif)
        case .systemMedium: return .system(size: 17, weight: .semibold, design: .serif)
        default:            return .system(size: 22, weight: .semibold, design: .serif)
        }
    }

    private var subtitleFont: Font {
        switch family {
        case .systemMedium: return .system(size: 12, weight: .regular)
        default:            return .system(size: 14, weight: .regular)
        }
    }

    private var glyphSize: CGFloat {
        switch family {
        case .systemSmall:  return 12
        case .systemMedium: return 14
        default:            return 18
        }
    }

    private var captionPadding: EdgeInsets {
        switch family {
        case .systemSmall:  return EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        case .systemMedium: return EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14)
        default:            return EdgeInsets(top: 12, leading: 18, bottom: 16, trailing: 18)
        }
    }

    private var gradientHeight: CGFloat {
        switch family {
        case .systemSmall:  return 60
        case .systemMedium: return 80
        default:            return 120
        }
    }
}

/// Centered SF symbol + label fallback, used when no snapshot exists or no
/// photos match the configured filter.
struct WidgetEmptyView: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
