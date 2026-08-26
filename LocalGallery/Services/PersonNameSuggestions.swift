import Foundation

/// Autocomplete pool for naming a person: library `People/` tags plus the
/// address book already loaded for birthday memories.
///
/// An empty field offers names the library already knows — the usual reason
/// this cluster exists is a second group of someone already named. Typing
/// searches the address book too (given, family, nickname, and each word of
/// the full name), ranked so a prefix beats a contains-match. The string
/// returned is always the name that will be written to the sidecar.
///
/// A contact already linked to a library person (manual or auto-match) is
/// not offered as a second chip: "Anna" and the linked "Anna Schmidt" are
/// the same person, and the library name is the one the sidecar will keep.
enum PersonNameSuggestions {
    struct Item: Equatable, Identifiable, Sendable {
        var name: String
        var fromContacts: Bool
        var id: String { name.lowercased() }
    }

    static let limit = 8

    static func matching(
        typed: String,
        libraryNames: [String],
        contacts: [ContactInfo],
        linkedContactIDs: Set<String> = [],
        limit: Int = Self.limit
    ) -> [Item] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var ranked: [(item: Item, score: Int)] = []

        func consider(name: String, extraKeys: [String], fromContacts: Bool) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "(No name)" else { return }
            let identity = trimmed.lowercased()
            guard seen.insert(identity).inserted else { return }
            if query.isEmpty {
                guard !fromContacts else { return }
                ranked.append((Item(name: trimmed, fromContacts: false), 0))
                return
            }
            guard identity != query.lowercased() else { return }
            guard let score = score(query: query, displayName: trimmed, extraKeys: extraKeys) else {
                return
            }
            ranked.append((Item(name: trimmed, fromContacts: fromContacts), score))
        }

        for name in libraryNames {
            consider(name: name, extraKeys: [], fromContacts: false)
        }
        for contact in contacts where !linkedContactIDs.contains(contact.id) {
            consider(name: contact.fullName, extraKeys: contact.nameMatchKeys, fromContacts: true)
        }

        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.fromContacts != $1.item.fromContacts {
                return !$0.item.fromContacts
            }
            return $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending
        }
        return ranked.prefix(limit).map(\.item)
    }

    /// 300: the display name starts with the query. 200: any word (or
    /// nickname) does. 50: the query appears somewhere inside.
    private static func score(query: String, displayName: String, extraKeys: [String]) -> Int? {
        if anchored(displayName, query) { return 300 }
        let keys = [displayName] + extraKeys
        for key in keys {
            for token in key.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
                if anchored(String(token), query) { return 200 }
            }
        }
        for key in keys {
            if key.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return 50
            }
        }
        return nil
    }

    private static func anchored(_ string: String, _ prefix: String) -> Bool {
        string.range(
            of: prefix,
            options: [.caseInsensitive, .diacriticInsensitive, .anchored]
        ) != nil
    }
}
