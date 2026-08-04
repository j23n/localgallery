import SwiftUI

/// One face cluster, up close: every face in it, a name field, and "Not a
/// person".
///
/// Naming writes `People/<Name>` keywords and MWG regions into the `.xmp`
/// sidecar of every photo the cluster reaches, so both actions are irreversible
/// from the user's point of view even though the core can retract them — and
/// both are refused while *either* core engine is running, which is why the
/// buttons disable on `faces.isCoreBusy` rather than queueing.
///
/// ## Naming somebody who already has a group
///
/// `name_cluster` names **this** group; it does not merge it into another one,
/// and the core has no merge operation yet. Two groups can carry one name, and
/// that is a supported state — a person photographed across ten years really
/// does cluster into more than one group, and naming both is how they end up as
/// one person in the library. What it is *not* is a merge, so this screen says
/// which of the two it is rather than letting the user infer the wrong one:
/// the photos join that person everywhere the app shows people, and the groups
/// stay separate here. `existingGroupNote` is that sentence.
struct ClusterReviewView: View {
    let clusterID: Int64

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var faces: [FaceService.Face] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showIgnoreAlert = false
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    private var cluster: FaceService.Cluster? {
        store.faces.allClusters.first { $0.id == clusterID }
    }

    /// Contact names that start with what has been typed, plus — before
    /// anything is typed — the people already in the library.
    ///
    /// Cheap and local: `store.contacts` is loaded for birthday memories
    /// anyway, and `people.peopleTags` is the existing tag aggregation. No new
    /// permission is asked for; with Contacts denied this quietly falls back to
    /// the library's own names.
    ///
    /// Names already carried by another *group* are deliberately **not**
    /// filtered out. They are the most likely right answer — the same person,
    /// clustered twice — and hiding them would make the common case harder to
    /// type. What they are not is a merge, so `existingGroupNote` says so as
    /// soon as one is chosen.
    private var suggestions: [String] {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = store.contacts.map(\.fullName) + store.people.peopleTags.map(\.displayName)
        var seen = Set<String>()
        return pool
            .filter { candidate in
                guard candidate != "(No name)", !candidate.isEmpty else { return false }
                guard !typed.isEmpty else { return true }
                return candidate.localizedCaseInsensitiveContains(typed) && candidate != typed
            }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(6)
            .map { $0 }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !isSaving && !store.faces.isCoreBusy
    }

    /// What the typed name will actually do, when another group already has it.
    ///
    /// Not shown for this cluster's own current name — re-saving that is a
    /// no-op, not a second group.
    private var existingGroupNote: String? {
        guard !trimmedName.isEmpty, trimmedName != cluster?.name else { return nil }
        let match = store.faces.namedClusters.first {
            $0.id != clusterID && $0.name?.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard let name = match?.name else { return nil }
        return "Another group is already named “\(name)”. These photos join \(name) everywhere the app shows people — the two groups stay separate here, because merging groups isn’t supported yet."
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }

                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { name = suggestion }
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Design.accentSoft, in: Capsule())
                                    .foregroundStyle(Design.ink)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                }

                if let note = existingGroupNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Design.ink2)
                }

                Button {
                    save()
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Label("Save Name", systemImage: "checkmark.circle")
                    }
                }
                .disabled(!canSave)

                Button(role: .destructive) {
                    showIgnoreAlert = true
                } label: {
                    Label("Not a Person", systemImage: "xmark.circle")
                }
                .disabled(isSaving || store.faces.isCoreBusy)
            } header: {
                Text("Who is this?")
            } footer: {
                if store.faces.isCoreBusy {
                    Text("A scan is running — naming is paused until it finishes.")
                } else {
                    Text("Saving writes “People/\(trimmedName.isEmpty ? "Name" : trimmedName)” and a face region into each photo’s `.xmp` sidecar. The photos themselves are never modified.")
                }
            }

            if let error = store.faces.lastError, error != .cancelled {
                Section {
                    Text(error.message)
                        .font(.footnote)
                        .foregroundStyle(Design.destructive)
                }
            }

            Section(faceSectionTitle) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading faces…")
                            .font(.caption)
                            .foregroundStyle(Design.ink2)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(faces) { face in
                            PersonThumbnailView(
                                url: face.url,
                                region: face.region,
                                size: 76,
                                cornerRadius: 10
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(cluster?.name ?? "Unnamed Person")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.bg)
        .alert("Not a person?", isPresented: $showIgnoreAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Dismiss Group", role: .destructive) { ignore() }
        } message: {
            Text("This group won’t be offered again, and anything already written for it is taken back out of the sidecars.")
        }
        .task(id: clusterID) {
            name = cluster?.name ?? ""
            faces = await store.faces.faces(inCluster: clusterID)
            isLoading = false
        }
    }

    private var faceSectionTitle: String {
        let count = faces.isEmpty ? (cluster?.size ?? 0) : faces.count
        return count == 1 ? "1 Face" : "\(count) Faces"
    }

    private func save() {
        nameFocused = false
        let value = trimmedName
        guard !value.isEmpty else { return }
        isSaving = true
        Task {
            let ok = await store.faces.name(cluster: clusterID, as: value)
            isSaving = false
            // Stay put on failure so the error line is readable and the typed
            // name is not lost.
            if ok { dismiss() }
        }
    }

    private func ignore() {
        isSaving = true
        Task {
            let ok = await store.faces.ignore(cluster: clusterID)
            isSaving = false
            if ok { dismiss() }
        }
    }
}
