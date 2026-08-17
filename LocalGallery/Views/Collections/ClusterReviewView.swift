import SwiftUI

/// One face cluster, up close: every face in it, a name field, "Not a person",
/// and the two ways to reshape the group — merge it into another, or pull the
/// wrong faces out of it.
///
/// All four write `People/<Name>` keywords and MWG regions into the `.xmp`
/// sidecar of every photo the cluster reaches, so they are irreversible from
/// the user's point of view even though the core can retract them — and all
/// four are refused while *either* core engine is running, which is why the
/// controls disable on `faces.isCoreBusy` rather than queueing.
///
/// ## Naming somebody who already has a group
///
/// `name_cluster` names **this** group; it does not fold it into another one.
/// Two groups can carry one name, and that is a supported state — a person
/// photographed across ten years really does cluster into more than one group.
/// Merging them is now possible and is a *different* action, so this screen
/// says which of the two the user is about to do rather than letting them infer
/// the wrong one. `existingGroupNote` is that sentence.
struct ClusterReviewView: View {
    let clusterID: Int64

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var faces: [FaceService.Face] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showIgnoreAlert = false
    /// Multi-select over the face grid. Off by default: the ordinary reason to
    /// open this screen is to name the group, and a grid that responds to taps
    /// by selecting would make that harder for the sake of the rarer action.
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showSplitAlert = false
    @State private var showMergePicker = false
    @State private var pendingMerge: MergeDirection?
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
        return "Another group is already named “\(name)”. These photos join \(name) everywhere the app shows people, and the two groups stay separate here — use “Merge with…” if they should become one."
    }

    /// A split of every face would leave the source empty and the new group an
    /// exact copy, so the core refuses it; the button says so by being off.
    private var canSplit: Bool {
        !selection.isEmpty && selection.count < faces.count && !isSaving && !store.faces.isCoreBusy
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

            Section {
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
                            faceCell(face)
                        }
                    }
                    .padding(.vertical, 4)

                    if isSelecting {
                        Button {
                            showSplitAlert = true
                        } label: {
                            Label("Move to New Group", systemImage: "square.on.square.dashed")
                        }
                        .disabled(!canSplit)
                    }
                }
            } header: {
                HStack {
                    Text(faceSectionTitle)
                    Spacer(minLength: 0)
                    if !isLoading && faces.count > 1 {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            selection.removeAll()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .textCase(nil)
                    }
                }
            } footer: {
                if isSelecting {
                    Text("Pick the faces that are somebody else. They move into a new group of their own, and keep no name.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(cluster?.name ?? "Unnamed Person")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.bg)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMergePicker = true
                } label: {
                    Label("Merge with…", systemImage: "arrow.triangle.merge")
                }
                .disabled(isSaving || store.faces.isCoreBusy)
            }
        }
        .sheet(isPresented: $showMergePicker) {
            if let cluster {
                ClusterPickerView(source: cluster) { pendingMerge = $0 }
            }
        }
        .alert("Not a person?", isPresented: $showIgnoreAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Dismiss Group", role: .destructive) { ignore() }
        } message: {
            Text("This group won’t be offered again, and anything already written for it is taken back out of the sidecars.")
        }
        .alert("Move faces out?", isPresented: $showSplitAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Move", role: .destructive) { split() }
        } message: {
            Text(splitMessage)
        }
        // Presented from the direction itself, not from a separate flag: the
        // title and the message both have to name the group that survives, and
        // that is decided in the picker.
        .alert(
            pendingMerge?.buttonLabel ?? "Merge",
            isPresented: Binding(
                get: { pendingMerge != nil },
                set: { if !$0 { pendingMerge = nil } }
            ),
            presenting: pendingMerge
        ) { direction in
            Button("Cancel", role: .cancel) { }
            Button("Merge") { merge(direction) }
        } message: { direction in
            Text(direction.confirmation)
        }
        .task(id: clusterID) {
            name = cluster?.name ?? ""
            faces = await store.faces.faces(inCluster: clusterID)
            isLoading = false
        }
    }

    private func faceCell(_ face: FaceService.Face) -> some View {
        PersonThumbnailView(
            url: face.url,
            region: face.region,
            size: 76,
            cornerRadius: 10
        )
        .overlay(alignment: .bottomTrailing) {
            if isSelecting {
                Image(systemName: selection.contains(face.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selection.contains(face.id) ? Design.accentColor : .black.opacity(0.35))
                    .padding(4)
            }
        }
        .opacity(isSelecting && !selection.contains(face.id) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            if selection.contains(face.id) {
                selection.remove(face.id)
            } else {
                selection.insert(face.id)
            }
        }
    }

    /// Says the retraction in words when the group is named — that is the part
    /// of a split that reaches somebody's files.
    private var splitMessage: String {
        let count = selection.count
        let faces = count == 1 ? "This face" : "These \(count) faces"
        guard let name = cluster?.name else {
            return "\(faces) move into a new group of their own."
        }
        return "\(faces) will no longer be tagged \(name), and move into a new group of their own."
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

    /// Stays on the screen afterwards: the group the user is looking at still
    /// exists, it is just smaller, and the faces they moved out are exactly
    /// what they wanted to stop seeing here.
    private func split() {
        let keys = Array(selection)
        isSaving = true
        Task {
            let ok = await store.faces.split(cluster: clusterID, faces: keys)
            if ok {
                selection.removeAll()
                isSelecting = false
                faces = await store.faces.faces(inCluster: clusterID)
            }
            isSaving = false
        }
    }

    /// Leaves when this group was the one absorbed — there is nothing left to
    /// show — and stays when it survived.
    private func merge(_ direction: MergeDirection) {
        isSaving = true
        Task {
            let ok = await store.faces.merge(
                into: direction.survivor.id, from: direction.absorbed.id
            )
            isSaving = false
            guard ok else { return }
            if direction.absorbed.id == clusterID {
                dismiss()
            } else {
                name = cluster?.name ?? name
                faces = await store.faces.faces(inCluster: clusterID)
            }
        }
    }
}
