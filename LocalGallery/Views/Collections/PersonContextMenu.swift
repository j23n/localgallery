import SwiftUI

/// The shared person context menu (Mark as Me / Feature / Link / Rename / Hide)
/// used by the Collections people rail and the full People list. Link and
/// rename presentation are delegated to the caller — a menu cannot present a
/// sheet of its own, so each screen owns the state.
struct PersonContextMenu: View {
    let person: TagSuggestion
    let onLink: (TagSuggestion) -> Void
    let onRename: (TagSuggestion) -> Void
    @Environment(GalleryStore.self) private var store

    var body: some View {
        let isFeatured = store.people.isFeatured(person.fullPath)
        let isMe = store.people.isMe(person.fullPath)
        Button {
            if isMe { store.people.unmarkAsMe() } else { store.people.markAsMe(person.fullPath) }
        } label: {
            Label(isMe ? "Unmark as Me" : "Mark as Me",
                  systemImage: isMe ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
        }
        Button {
            store.people.toggleFeaturePerson(person.fullPath)
        } label: {
            Label(isFeatured ? "Unfeature" : "Feature",
                  systemImage: isFeatured ? "star.slash" : "star")
        }
        Button {
            onLink(person)
        } label: {
            Label(linkLabel, systemImage: "person.text.rectangle")
        }
        // Hidden without face models rather than disabled: renaming rewrites
        // the sidecars through the core's cluster table, and with a
        // tagging-only pack there is none — those `People/` tags came from
        // somebody else's tool and are not ours to rewrite.
        if store.faces.isAvailable {
            Button {
                onRename(person)
            } label: {
                Label("Rename Person…", systemImage: "pencil")
            }
            // The core refuses a write during a run; a disabled row explains
            // that better than an error afterwards.
            .disabled(store.faces.isCoreBusy)
        }
        Button(role: .destructive) {
            store.people.hidePerson(person.fullPath)
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
    }

    /// Label for the link entry. Reflects the current state so the menu
    /// doubles as status. Goes through `store.linkState` so we don't re-scan
    /// the contacts array per render.
    private var linkLabel: String {
        switch store.linkState(forPersonPath: person.fullPath, displayName: person.displayName) {
        case .unlinked:        return "Link to Contact"
        case .disabled:        return "Birthdays disabled"
        case .manual(let c):   return "Linked: \(c.fullName)"
        case .auto(let c):     return "Auto: \(c.fullName)"
        }
    }
}
