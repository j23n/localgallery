import SwiftUI

/// One face cluster, up close: every face in it, a name field, and "Not a
/// person".
///
/// Naming writes `People/<Name>` keywords and MWG regions into the `.xmp`
/// sidecar of every photo the cluster reaches, so both actions are irreversible
/// from the user's point of view even though the core can retract them — and
/// both are refused by the core while a face scan is running, which is why the
/// buttons disable on `faces.isRunning` rather than queueing.
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
        !trimmedName.isEmpty && !isSaving && !store.faces.isRunning
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
                .disabled(isSaving || store.faces.isRunning)
            } header: {
                Text("Who is this?")
            } footer: {
                if store.faces.isRunning {
                    Text("A face scan is running — naming is paused until it finishes.")
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
