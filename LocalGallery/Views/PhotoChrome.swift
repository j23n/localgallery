import CoreGraphics
import Foundation
import SwiftUI

/// Helpers for rendering the date+location pill that appears in both the
/// photo viewer's top bar and the memory slideshow's top bar. Pure functions
/// over a `PhotoFile` so the Store doesn't need to be involved.
enum PhotoChrome {
    /// Fixed pill width used in both the memory slideshow and the photo
    /// viewer. Wide enough for "5 May 2024" / "Reykjavík, Iceland"-class
    /// labels; longer city/country strings truncate with an ellipsis rather
    /// than reflowing the surrounding chrome.
    static let pillWidth: CGFloat = 200

    /// Two-line pill content: date on top, location below. Either field may
    /// be nil, in which case the corresponding line is omitted by the caller.
    /// Returns nil only when the photo has neither.
    static func pillLines(for photo: PhotoFile) -> (date: String?, location: String?)? {
        let date = formattedDate(photo.dateTaken)
        let location = formattedLocation(for: photo)
        if date == nil && location == nil { return nil }
        return (date, location)
    }

    /// "5 May 2024" — locale-aware, day-month-year. Nil when `date` is nil.
    static func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return fmt.string(from: date)
    }

    /// Prefer `<city>, <country>` from a `Places/<Country>/<Region>/<City>`
    /// path of depth ≥3. Fall back to country alone (from country code or
    /// shallow Places path). Returns nil when no location data is present.
    static func formattedLocation(for photo: PhotoFile) -> String? {
        let placePaths = photo.hierarchicalTags
            .filter { $0.namespace?.lowercased() == "places" }
            .map { $0.fullPath.split(separator: "/").map(String.init) }

        if let deepest = placePaths.max(by: { $0.count < $1.count }), deepest.count >= 4 {
            // ["Places", country, region, city, ...] — segment 3 = city, segment 1 = country.
            let city = deepest[3]
            let country = deepest[1]
            return "\(city), \(country)"
        }
        if let deepest = placePaths.max(by: { $0.count < $1.count }), deepest.count >= 3 {
            // ["Places", country, region] — no city; show "Region, Country".
            let region = deepest[2]
            let country = deepest[1]
            return "\(region), \(country)"
        }
        if let deepest = placePaths.max(by: { $0.count < $1.count }), deepest.count >= 2 {
            // ["Places", country] — country only.
            let country = deepest[1]
            // If a country code is also present, prefer the localized name.
            if let code = photo.countryCode, let localized = MemoryEngine.countryName(from: code) {
                return localized
            }
            return country
        }
        if let code = photo.countryCode, let localized = MemoryEngine.countryName(from: code) {
            return localized
        }
        return nil
    }
}

// MARK: - Liquid Glass adapters

extension View {
    /// Background for chrome drawn over photos (pills, circular buttons):
    /// Liquid Glass on iOS 26+, the legacy translucent white fill earlier.
    @ViewBuilder
    func chromeGlass(in shape: some Shape, legacyOpacity: Double) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.white.opacity(legacyOpacity), in: shape)
        }
    }
}

/// Groups sibling glass elements into one `GlassEffectContainer` on iOS 26+
/// so nearby glass shapes blend correctly (per the Liquid Glass HIG);
/// passes content through unchanged on earlier systems.
struct ChromeGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

/// The shared two-line date/location pill drawn over the photo viewer's and
/// the memory slideshow's top bars. Both lines are always reserved so the
/// pill height stays constant whether or not a given photo has location data.
struct ChromePill: View {
    let date: String?
    let location: String?

    var body: some View {
        VStack(spacing: 1) {
            Text(date ?? " ")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(location ?? " ")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .frame(width: PhotoChrome.pillWidth)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .chromeGlass(in: Capsule(), legacyOpacity: 0.14)
    }
}

/// Circular translucent "X" shared by the photo viewer and memory slideshow.
struct ViewerDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .chromeGlass(in: Circle(), legacyOpacity: 0.16)
        }
    }
}
