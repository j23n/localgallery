import SwiftUI

// MARK: - People List View

struct PeopleListView: View {
    @Environment(GalleryStore.self) private var store
    @State private var searchText = ""
    @State private var linkingPerson: TagSuggestion?

    private var filteredPeople: [TagSuggestion] {
        let all = store.people.visiblePeople
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredPeople) { person in
                NavigationLink(value: CollectionsRoute.personGrid(person)) {
                    PeopleListRow(tag: person)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        store.people.hidePerson(person.fullPath)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                }
                .contextMenu {
                    PersonContextMenu(person: person) { linkingPerson = $0 }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search")
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .background(Design.bg)
        .sheet(item: $linkingPerson) { person in
            ContactLinkSheet(person: person)
        }
    }

}

// MARK: - People List Row

struct PeopleListRow: View {
    let tag: TagSuggestion
    @Environment(GalleryStore.self) private var store

    private var rowPhotos: [PhotoFile] {
        let all = store.photos(forTag: tag)
        guard let cover = store.people.featuredPhoto(for: tag) else {
            return Array(all.prefix(2))
        }
        var result = [cover]
        if let other = all.first(where: { $0.id != cover.id }) {
            result.append(other)
        }
        return result
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(rowPhotos) { photo in
                    PersonThumbnailView(
                        url: photo.url,
                        region: store.people.faceRegion(for: photo, person: tag.displayName),
                        size: 52,
                        cornerRadius: 9,
                        isRemote: photo.locality.isRemotePlaceholder
                    )
                    .frame(width: 52, height: 52)
                }
                if rowPhotos.isEmpty {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Design.bgGrouped)
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Design.ink3)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(tag.displayName)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(Design.ink)
                    if store.people.isFeatured(tag.fullPath) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Design.accentColor)
                    }
                }
                Text(photoCountLabel(tag.count))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Design.ink2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

