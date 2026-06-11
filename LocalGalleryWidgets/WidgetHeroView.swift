import SwiftUI
import WidgetKit

/// Full-bleed background for use inside `.containerBackground(for: .widget)`.
/// Renders the photo edge-to-edge with a bottom gradient scrim so the caption
/// text in the content layer remains readable. When `image` is nil, shows a
/// dark gradient placeholder.
struct WidgetBackgroundImage: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                // Opt the photo out of the Home Screen tint treatment —
                // without this, accented/tinted Home Screens render it as a
                // washed-out monochrome.
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 120)
                }
        } else {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

/// Caption overlay rendered in the widget's content layer (not containerBackground).
/// Shows title, optional subtitle, and an optional SF Symbol glyph above the title.
struct WidgetHeroView: View {
    @Environment(\.widgetFamily) private var family
    let title: String
    let subtitle: String?
    let glyph: String?

    init(title: String, subtitle: String? = nil, glyph: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
    }

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
        case .systemSmall:  return EdgeInsets(top: 8, leading: 2.5, bottom: 2, trailing: 10)
        case .systemMedium: return EdgeInsets(top: 10, leading: 3.5, bottom: 3, trailing: 14)
        default:            return EdgeInsets(top: 12, leading: 4.5, bottom: 4, trailing: 18)
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
