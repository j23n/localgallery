import Foundation
import os

/// Resolves person tags (`People/<name>`) to address-book contacts. Owns the
/// hash indexes used for O(1) auto-match by name and O(1) manual-link
/// resolution by `CNContact.identifier`. The Store keeps the observed
/// `personContactLinks` dictionary as the source of truth and passes it in;
/// this type stays a pure logic + index helper.
@MainActor
final class ContactLinker {
    /// Resolved link state for a person tag — what the UI should display.
    enum LinkState: Equatable {
        case unlinked          // no manual link, no auto match
        case disabled          // user explicitly disabled (no birthdays)
        case manual(ContactInfo)
        case auto(ContactInfo)
    }

    /// Lowercased "<given> <family>" → contact, used for birthday auto-matching.
    /// First-write wins so the address book's order determines which homonym
    /// auto-matches. Manual links via `links` always override.
    private(set) var contactsByLowerName: [String: ContactInfo] = [:]
    /// `CNContact.identifier` → contact. Avoids linear scans when resolving a
    /// manual link to its target contact.
    private var contactByID: [String: ContactInfo] = [:]

    /// Rebuild the indexes from the latest contacts list. Call when
    /// `contacts` changes (initial load, address-book refresh).
    func index(_ contacts: [ContactInfo]) {
        var byName: [String: ContactInfo] = [:]
        var byID: [String: ContactInfo] = [:]
        for c in contacts {
            byID[c.id] = c
            let key = c.fullName.lowercased()
            if byName[key] == nil { byName[key] = c }
        }
        contactsByLowerName = byName
        contactByID = byID
    }

    /// Resolved link state for a person tag. `links` is the user's manual
    /// override dictionary (kept on the Store so views observe mutations).
    func linkState(forPersonPath path: String, displayName: String, links: [String: PersonLink]) -> LinkState {
        switch links[path] {
        case .disabled:
            return .disabled
        case .manual(let id):
            if let c = contactByID[id] { return .manual(c) }
            return .unlinked  // dangling reference (contact deleted)
        case nil:
            if let auto = contactsByLowerName[displayName.lowercased()] { return .auto(auto) }
            return .unlinked
        }
    }

    /// Effective contact for a person tag: manual link if present, otherwise
    /// the auto-match. `nil` when explicitly disabled or no contact matches.
    func effectiveContact(forPersonPath path: String, displayName: String, links: [String: PersonLink]) -> ContactInfo? {
        switch linkState(forPersonPath: path, displayName: displayName, links: links) {
        case .manual(let c), .auto(let c): return c
        case .unlinked, .disabled: return nil
        }
    }

    /// Set of `<id>|<fullName>|<MM-DD>` keys — the only contact fields the
    /// memories pipeline reads. Comparing two snapshots' signatures tells
    /// `loadContacts()` whether to force a memory rebuild.
    static func birthdayRelevantSignature(_ contacts: [ContactInfo]) -> Set<String> {
        Set(contacts.map { c in
            let m = c.birthday?.month.map(String.init) ?? "-"
            let d = c.birthday?.day.map(String.init) ?? "-"
            return "\(c.id)|\(c.fullName)|\(m)-\(d)"
        })
    }
}
