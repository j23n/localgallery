import Foundation

/// How a person tag (`People/<name>`) is linked to an address-book contact.
/// Absence from the persisted dictionary means "auto-match by name" — only
/// explicit user choices need a stored value.
enum PersonLink: Codable, Equatable, Sendable {
    /// User picked a specific contact for this person tag.
    case manual(contactID: String)
    /// User explicitly turned off birthday memories for this person tag,
    /// suppressing the auto-match by name.
    case disabled
}
