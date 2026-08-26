import Foundation

/// Pure helpers for the viewer info sheet. Kept off the view so header
/// dates, relative ML stamps, and the Files-app URL are unit-testable.
enum PhotoInfoFormatting {
    /// Files-app URL that reveals `fileURL` in the hierarchy.
    ///
    /// iOS has no public "Reveal in Files" API. The `shareddocuments`
    /// scheme is the same one Files itself uses for `file://` paths —
    /// iCloud Drive, the security-scoped library root, and third-party
    /// providers all resolve through it.
    static func filesAppURL(for fileURL: URL) -> URL? {
        var components = URLComponents(url: fileURL.standardizedFileURL, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        return components?.url
    }

    /// "12 August 2024" — full month; the info header has more room than
    /// the viewer pill (`PhotoChrome` uses the abbreviated month).
    static func headerDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter.string(from: date)
    }

    /// Locale-aware short time, e.g. "18:41" or "6:41 PM".
    static func headerTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Uppercased extension (`HEIC`) when the filename has one.
    static func fileFormat(filename: String) -> String? {
        let ext = URL(fileURLWithPath: filename).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    /// Sidecar XMP stamps are ISO-8601 (`2026-08-03T10:00:00Z`). Show
    /// "2 hours ago"; fall back to the raw string if it is not a date.
    static func relativeTimestamp(_ raw: String, now: Date = .now) -> String {
        guard let date = parseISO8601(raw) else { return raw }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// "2 named · 1 unnamed". `scanned` is true when a face pack stamp
    /// exists so an empty detection still reads as "none", not missing.
    static func facesSummary(named: Int, unnamed: Int, scanned: Bool) -> String? {
        if named == 0 && unnamed == 0 { return scanned ? "none" : nil }
        if unnamed == 0 { return named == 1 ? "1 named" : "\(named) named" }
        if named == 0 { return unnamed == 1 ? "1 unnamed" : "\(unnamed) unnamed" }
        return "\(named) named · \(unnamed) unnamed"
    }

    static func sidecarLabel(_ status: SidecarStatus) -> String {
        switch status {
        case .absent: return "none"
        case .cached: return "present"
        }
    }

    /// How `dateTaken` was sourced. Nil when the photo has no date.
    static func dateSourceLabel(hasDate: Bool, fromMetadata: Bool) -> String? {
        guard hasDate else { return nil }
        return fromMetadata ? "from EXIF" : "from filesystem"
    }
}
