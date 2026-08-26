import SwiftUI

// MARK: - People List View

struct PeopleListView: View {
    @Environment(GalleryStore.self) private var store
    @State private var searchText = ""
    @State private var linkingPerson: TagSuggestion?
    @State private var renamingPerson: TagSuggestion?

    private var filteredPeople: [TagSuggestion] {
        let all = store.people.visiblePeople
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// Unlabeled face clusters waiting for a name or Ignore.
    private var reviewable: [FaceService.Cluster] {
        store.faces.reviewableClusters
    }

    var body: some View {
        List {
            // Only while the search field is empty: search is about the people
            // who already have names, and a review banner is not one of them.
            if searchText.isEmpty, !reviewable.isEmpty {
                Section {
                    NavigationLink(value: CollectionsRoute.peopleReview) {
                        PeopleReviewRow(count: reviewable.count)
                    }
                }
            }

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
                    PersonContextMenu(
                        person: person,
                        onLink: { linkingPerson = $0 },
                        onRename: { renamingPerson = $0 }
                    )
                }
            }

            if filteredPeople.isEmpty, searchText.isEmpty, reviewable.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No people yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Design.ink)
                        Text(
                            store.analysis.isRunning || store.faces.isRunning
                                ? "Looking for faces in your library. Each group — including a single face — will show up here to name or ignore."
                                : "After a photo scan, unnamed face groups appear here. Name one and they’ll show up in Collections."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(Design.ink2)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
        .sheet(item: $renamingPerson) { person in
            RenamePersonSheet(person: person)
        }
        .task {
            await store.faces.refreshClusters()
        }
    }

}

// MARK: - People List Row

struct PeopleListRow: View {
    let tag: TagSuggestion
    @Environment(GalleryStore.self) private var store

    private var coverPhoto: PhotoFile? {
        store.people.featuredPhoto(for: tag)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let photo = coverPhoto {
                PersonThumbnailView(
                    url: photo.url,
                    region: store.people.faceRegion(for: photo, person: tag.displayName),
                    size: 52,
                    cornerRadius: 9,
                    isRemote: photo.locality.isRemotePlaceholder
                )
                .frame(width: 52, height: 52)
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Design.bgGrouped)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Design.ink3)
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

