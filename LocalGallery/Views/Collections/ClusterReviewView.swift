import SwiftUI

/// One face cluster, up close: every face in it, a name field, and the two
/// dismissals — Ignore (a real face this library is not naming) and Not a
/// Face (a rejected detection). Merge folds the group into someone already
/// named. Select mode reshapes the group: move faces out, ignore them, or
/// mark them as not a face. It does not name the person.
///
/// All four write `People/<Name>` keywords and MWG regions into the `.xmp`
/// sidecar of every photo the cluster reaches, so they are irreversible from
/// the user's point of view even though the core can retract them — and all
/// four are refused while *either* core engine is running, which is why the
/// controls disable on `faces.isCoreBusy` rather than queueing.
///
/// ## Naming somebody who already has a group
///
/// Typing a name another group already carries is a merge: the button becomes
/// "Merge Person" and the same confirmation as the other merge entry points
/// runs before anything is written. `name_cluster` is only used when the name
/// is new.
struct ClusterReviewView: View {
    let clusterID: Int64

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var faces: [FaceService.Face] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showIgnoreAlert = false
    @State private var showRejectAlert = false
    /// Multi-select over the face grid. Off by default: the ordinary reason to
    /// open this screen is to name the group, and a grid that responds to taps
    /// by selecting would make that harder for the sake of the rarer action.
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var pendingSplit: [String] = []
    @State private var pendingIgnore: [String] = []
    @State private var pendingReject: [String] = []
    @State private var pendingMerge: MergeDirection?
    @State private var viewer: FacePhotoViewer?
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    private var cluster: FaceService.Cluster? {
        store.faces.allClusters.first { $0.id == clusterID }
    }

    /// Contact names that start with what has been typed, plus — before
    /// anything is typed — the people already in the library.
    ///
    /// `store.contacts` is the same address-book snapshot birthday memories
    /// use. This screen reloads it on appear so a grant that landed after
    /// launch still fills the chips. Denied access falls back to library
    /// names, same as the linking sheet.
    ///
    /// Names already carried by another *group* are deliberately **not**
    /// filtered out. They are the most likely right answer — the same person,
    /// clustered twice — and picking one turns the save button into a merge.
    private var suggestions: [PersonNameSuggestions.Item] {
        PersonNameSuggestions.matching(
            typed: name,
            libraryNames: store.people.peopleTags.map(\.displayName),
            contacts: store.contacts,
            linkedContactIDs: store.linkedContactIDs
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !isSaving && !store.faces.isCoreBusy
    }

    /// The named group this typed name would merge into. Nil for this
    /// cluster's own current name — re-saving that is a no-op, not a merge.
    private var existingNamedCluster: FaceService.Cluster? {
        FaceClusterNaming.mergeTarget(
            typed: trimmedName,
            clusterID: clusterID,
            currentName: cluster?.name,
            named: store.faces.namedClusters
        )
    }

    private var primaryActionTitle: String {
        existingNamedCluster == nil ? "Save Person" : "Merge Person"
    }

    /// A split of every face would leave the source empty and the new group an
    /// exact copy, so the core refuses it; the button says so by being off.
    private var canSplitSelection: Bool {
        !selection.isEmpty && selection.count < faces.count && !isSaving && !store.faces.isCoreBusy
    }

    private var canIgnoreSelection: Bool {
        !selection.isEmpty && !isSaving && !store.faces.isCoreBusy
    }

    var body: some View {
        ScrollView {
            // Direct children, not a VStack: a stack would measure the
            // LazyVGrid at unbounded height and decode every face at once.
            if !isSelecting {
                whoSection
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            }
            if let error = store.faces.lastError, error != .cancelled {
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(Design.destructive)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            facesHeader
                .padding(.horizontal, 16)
                .padding(.top, 20)
            facesGrid
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            facesFooterBlock
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .navigationTitle(cluster?.name ?? "Unnamed Person")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.bg)
        .softTopScrollEdge()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(primaryActionTitle) { attemptSave() }
                    .disabled(!canSave || isSelecting)
            }
        }
        .alert("Ignore this group?", isPresented: $showIgnoreAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Ignore", role: .destructive) { ignore() }
        } message: {
            Text(groupIgnoreMessage)
        }
        .alert("Not a face?", isPresented: $showRejectAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Not a Face", role: .destructive) { reject() }
        } message: {
            Text(groupRejectMessage)
        }
        .alert("Move faces out?", isPresented: Binding(
            get: { !pendingSplit.isEmpty },
            set: { if !$0 { pendingSplit = [] } }
        )) {
            Button("Cancel", role: .cancel) { pendingSplit = [] }
            Button("Move", role: .destructive) {
                let keys = pendingSplit
                split(keys)
            }
        } message: {
            Text(splitMessage(pendingSplit))
        }
        .alert("Ignore faces?", isPresented: Binding(
            get: { !pendingIgnore.isEmpty },
            set: { if !$0 { pendingIgnore = [] } }
        )) {
            Button("Cancel", role: .cancel) { pendingIgnore = [] }
            Button("Ignore", role: .destructive) {
                let keys = pendingIgnore
                ignoreSelection(keys)
            }
        } message: {
            Text(ignoreMessage(pendingIgnore))
        }
        .alert("Not a face?", isPresented: Binding(
            get: { !pendingReject.isEmpty },
            set: { if !$0 { pendingReject = [] } }
        )) {
            Button("Cancel", role: .cancel) { pendingReject = [] }
            Button("Not a Face", role: .destructive) {
                let keys = pendingReject
                rejectSelection(keys)
            }
        } message: {
            Text(rejectMessage(pendingReject))
        }
        .fullScreenCover(item: $viewer) { session in
            PhotoViewerView(
                photos: session.photos,
                currentPhotoID: Binding(
                    get: { viewer?.currentID ?? session.currentID },
                    set: { newValue in
                        guard var current = viewer else { return }
                        current.currentID = newValue
                        viewer = current
                    }
                )
            )
        }
        // Presented from the direction itself, not from a separate flag: the
        // title and the message both have to name the group that survives.
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
            async let loaded = store.faces.faces(inCluster: clusterID)
            await store.loadContacts()
            faces = await loaded
            isLoading = false
        }
    }

    private var whoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is this?")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { if canSave { attemptSave() } }

            if !suggestions.isEmpty {
                NameSuggestionChips(items: suggestions) { name = $0 }
            }

            Button {
                attemptSave()
            } label: {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text(primaryActionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSave)

            Button(role: .destructive) {
                showIgnoreAlert = true
            } label: {
                Text("Ignore")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isSaving || store.faces.isCoreBusy)

            Button(role: .destructive) {
                showRejectAlert = true
            } label: {
                Text("Not a Face")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isSaving || store.faces.isCoreBusy)

            if store.faces.isCoreBusy {
                Text("A scan is running — naming is paused until it finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var facesHeader: some View {
        HStack {
            Text(faceSectionTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Design.ink2)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            if !isLoading && faces.count > 1 {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    selection.removeAll()
                    if isSelecting { nameFocused = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var facesGrid: some View {
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
        }
    }

    @ViewBuilder
    private var facesFooterBlock: some View {
        if isSelecting {
            VStack(spacing: 10) {
                Button {
                    pendingSplit = Array(selection)
                } label: {
                    Text("Move to New Group")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSplitSelection)

                Button(role: .destructive) {
                    pendingIgnore = Array(selection)
                } label: {
                    Text("Ignore")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canIgnoreSelection)

                Button(role: .destructive) {
                    pendingReject = Array(selection)
                } label: {
                    Text("Not a Face")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canIgnoreSelection)

                Text(facesFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(facesFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var facesFooter: String {
        if isSelecting {
            return "Pick the faces that do not belong. Move them into a new group, ignore someone you do not want to name, or mark a detection as not a face."
        }
        return "Tap a face to open the photo. Use Select to move, ignore, or dismiss faces."
    }

    private func faceCell(_ face: FaceService.Face) -> some View {
        FaceReviewThumb(
            face: face,
            isDimmed: isSelecting && !selection.contains(face.id),
            isChecked: isSelecting ? selection.contains(face.id) : nil,
            onTap: {
                if isSelecting {
                    toggle(face.id)
                } else {
                    open(face)
                }
            }
        )
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func open(_ face: FaceService.Face) {
        let photo = store.photo(forFace: face)
        viewer = FacePhotoViewer(photo: photo, album: store.photos(forFaces: faces))
    }

    /// Says the retraction in words when the group is named — that is the part
    /// of a split that reaches somebody's files.
    private func splitMessage(_ keys: [String]) -> String {
        let count = keys.count
        let faces = count == 1 ? "This face" : "These \(count) faces"
        guard let name = cluster?.name else {
            return "\(faces) move into a new group of their own."
        }
        return "\(faces) will no longer be tagged \(name), and move into a new group of their own."
    }

    private var groupIgnoreMessage: String {
        "This group won’t be offered again. They are faces, just not someone this library is naming. Anything already written for it is taken back out of the sidecars."
    }

    private var groupRejectMessage: String {
        "This group will be dismissed as not a face and won’t be offered again. Anything already written for it is taken back out of the sidecars."
    }

    /// Ignore is for a passer-by or a poster: they are faces, just not someone
    /// this library is naming. Split out, then ignore the new group, so they
    /// do not come back on the next pass.
    private func ignoreMessage(_ keys: [String]) -> String {
        let count = keys.count
        let faces = count == 1 ? "This face" : "These \(count) faces"
        if keys.count >= self.faces.count {
            return "\(faces) will be ignored with the whole group, and will not be offered again."
        }
        return "\(faces) will leave this group and will not be offered again."
    }

    private func rejectMessage(_ keys: [String]) -> String {
        let count = keys.count
        let faces = count == 1 ? "This detection" : "These \(count) detections"
        if keys.count >= self.faces.count {
            return "\(faces) will be dismissed with the whole group, and will not be offered again."
        }
        return "\(faces) will be removed from this group and will not be offered again."
    }

    private var faceSectionTitle: String {
        let count = faces.isEmpty ? (cluster?.size ?? 0) : faces.count
        return count == 1 ? "1 Face" : "\(count) Faces"
    }

    private func attemptSave() {
        nameFocused = false
        guard canSave else { return }
        if let match = existingNamedCluster, let cluster,
           let direction = MergeDirection(cluster, match) {
            pendingMerge = direction
            return
        }
        save()
    }

    private func save() {
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

    private func reject() {
        isSaving = true
        Task {
            let ok = await store.faces.reject(cluster: clusterID)
            isSaving = false
            if ok { dismiss() }
        }
    }

    /// Stays on the screen afterwards: the group the user is looking at still
    /// exists, it is just smaller, and the faces they moved out are exactly
    /// what they wanted to stop seeing here.
    private func split(_ keys: [String]) {
        pendingSplit = []
        isSaving = true
        Task {
            let ok = await store.faces.split(cluster: clusterID, faces: keys)
            if ok {
                selection.removeAll()
                isSelecting = false
                faces = await store.faces.faces(inCluster: clusterID)
                if faces.isEmpty { dismiss() }
            }
            isSaving = false
        }
    }

    private func ignoreSelection(_ keys: [String]) {
        pendingIgnore = []
        dismissSelection(keys, ignore: true)
    }

    private func rejectSelection(_ keys: [String]) {
        pendingReject = []
        dismissSelection(keys, ignore: false)
    }

    private func dismissSelection(_ keys: [String], ignore: Bool) {
        let dismissingGroup = keys.count >= faces.count
        isSaving = true
        Task {
            let ok: Bool
            if ignore {
                ok = await store.faces.ignore(cluster: clusterID, faces: keys)
            } else {
                ok = await store.faces.reject(cluster: clusterID, faces: keys)
            }
            isSaving = false
            guard ok else { return }
            selection.removeAll()
            isSelecting = false
            if dismissingGroup {
                dismiss()
            } else {
                faces = await store.faces.faces(inCluster: clusterID)
                if faces.isEmpty { dismiss() }
            }
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

/// Horizontal chips for person-name autocomplete. A contacts glyph marks
/// address-book hits so they are distinguishable from library names.
struct NameSuggestionChips: View {
    let items: [PersonNameSuggestions.Item]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        onPick(item.name)
                    } label: {
                        HStack(spacing: 4) {
                            if item.fromContacts {
                                Image(systemName: "person.text.rectangle")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(item.name)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Design.accentSoft, in: Capsule())
                    .foregroundStyle(Design.ink)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// One face crop in a review grid: tap opens the photo (or toggles selection
/// when the parent is in Select mode). Checkmarks are the parent's job —
/// this only draws them.
///
/// Pressed state is opacity only. System button chrome was the shadow that
/// bobbed with the first merge-section header.
struct FaceReviewThumb: View {
    let face: FaceService.Face
    var size: CGFloat = 76
    var isDimmed: Bool = false
    var isChecked: Bool? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            PersonThumbnailView(
                url: face.url,
                region: face.region,
                size: size,
                cornerRadius: 10
            )
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let isChecked {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isChecked ? Design.accentColor : .black.opacity(0.35))
                        .padding(4)
                }
            }
            .opacity(isDimmed ? 0.5 : 1)
        }
        .buttonStyle(FaceThumbButtonStyle())
        .contentShape(Rectangle())
        .frame(width: size, height: size)
        .accessibilityLabel("Open photo")
    }
}

private struct FaceThumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Payload for opening the photo viewer from a face crop. One value so
/// `fullScreenCover(item:)` cannot present with an empty album or a
/// mismatched current id — that combination made `PhotoViewerView` dismiss
/// itself on the next runloop, which looked like a dead tap.
struct FacePhotoViewer: Identifiable {
    let id: UUID
    var currentID: UUID
    let photos: [PhotoFile]

    init(photo: PhotoFile, album: [PhotoFile]) {
        let photos = album.contains(where: { $0.id == photo.id })
            ? album
            : [photo]
        self.id = UUID()
        self.currentID = photo.id
        self.photos = photos
    }
}
