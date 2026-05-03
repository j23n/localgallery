import Foundation

/// Helpers for rendering the date+location pill that appears in both the
/// photo viewer's top bar and the memory slideshow's top bar. Pure functions
/// over a `PhotoFile` so the Store doesn't need to be involved.
enum PhotoChrome {
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
        if let deepest = placePaths.max(by: { $0.count < $1.count }), deepest.count >= 2 {
            // ["Places", country, ...] — country only.
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
