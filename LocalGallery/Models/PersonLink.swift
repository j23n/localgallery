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

/// Decode wrapper that swallows per-element failures. The Store decodes the
/// persisted `[String: PersonLink]` through this so one unreadable entry
/// (e.g. after a case rename in a future version) degrades to losing that
/// entry instead of silently wiping every manual link the user ever made.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
