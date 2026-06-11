import SwiftUI

/// The shared person context menu (Mark as Me / Feature / Link / Hide) used
/// by the Collections people rail and the full People list. Link
/// presentation is delegated to the caller via `onLink` — each screen owns
/// its own `linkingPerson` sheet state.
struct PersonContextMenu: View {
    let person: TagSuggestion
    let onLink: (TagSuggestion) -> Void
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
