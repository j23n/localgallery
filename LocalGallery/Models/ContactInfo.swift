import Foundation

/// Lightweight contact representation: the fields LocalGallery uses for
/// birthday memories and for person-name autocomplete. Hashable so we can
/// dedupe in pickers; Sendable so it can cross actor boundaries during
/// memory generation.
struct ContactInfo: Identifiable, Hashable, Codable, Sendable {
    /// `CNContact.identifier` — stable for the lifetime of the contact in the
    /// address book, persisted as the link key.
    let id: String
    let givenName: String
    let familyName: String
    /// Address-book nickname, used only for name autocomplete — the person
    /// tag we write is still `fullName`.
    let nickname: String
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

    /// Tokens a typed query may match, besides `fullName` itself.
    var nameMatchKeys: [String] {
        [givenName, familyName, nickname].filter { !$0.isEmpty }
    }

    var hasUsableBirthday: Bool {
        birthday?.month != nil && birthday?.day != nil
    }

    init(
        id: String,
        givenName: String,
        familyName: String,
        nickname: String = "",
        birthday: DateComponents? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.birthday = birthday
    }
}
