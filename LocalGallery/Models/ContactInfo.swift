import Foundation

/// Lightweight contact representation: just the fields LocalGallery uses for
/// birthday memories. Hashable so we can dedupe in pickers; Sendable so it can
/// cross actor boundaries during memory generation.
struct ContactInfo: Identifiable, Hashable, Codable, Sendable {
    /// `CNContact.identifier` — stable for the lifetime of the contact in the
    /// address book, persisted as the link key.
    let id: String
    let givenName: String
    let familyName: String
    /// `.month` and `.day` are the only components we rely on. `.year` is often
    /// missing in address-book data and is treated as "unknown" downstream.
    let birthday: DateComponents?

    /// "GivenName FamilyName" trimmed; falls back to either side when the other
    /// is empty (matches address-book conventions for mononyms).
    var fullName: String {
        let combined = "\(givenName) \(familyName)"
            .trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? "(No name)" : combined
    }

    var hasUsableBirthday: Bool {
        birthday?.month != nil && birthday?.day != nil
    }
}
