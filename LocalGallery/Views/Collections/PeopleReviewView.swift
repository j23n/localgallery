import SwiftUI

/// The face-review queue: unlabeled clusters the core has found, waiting for a
/// name, plus the groups it thinks are the same person.
///
/// Reached from the People screen when `store.faces.reviewableClusters` is
/// non-empty. Each card is one cluster; tapping it opens `ClusterReviewView`,
/// which is where naming, dismissing and splitting happen for a single group.
///
/// Select mode is the bulk path: name, merge, ignore, or mark as not a face
/// the ticked groups without opening each one. Naming uses the same rule as
/// the detail screen — a new name saves, a name somebody already has merges.
///
/// Merge suggestions sit above the grid rather than inside it: they are about
/// two or more groups at once, and the answer is a judgement the crops
/// themselves settle. Overlapping pairs become one row so every face that
/// would be merged is on screen. Nothing merges on its own — the core
/// proposes, the user decides on the select screen.
struct PeopleReviewView: View {
    @Environment(GalleryStore.self) private var store

    @State private var isSelecting = false
    @State private var selection: Set<Int64> = []
    @State private var isSaving = false
    @State private var showNameSheet = false
    @State private var pendingIgnoreCount = 0
    @State private var pendingRejectCount = 0
    @State private var pendingMerge: MergePlan?
    @State private var pendingNaming: PeopleReviewNaming.Outcome?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    /// Pairwise proposals collapsed into connected groups, strongest first.
    private var suggestions: [MergeGroup] {
        MergeGroups.make(
            proposals: store.faces.mergeProposals,
            clusters: store.faces.allClusters
        )
    }

    private var clusters: [FaceService.Cluster] {
        store.faces.reviewableClusters
    }

    private var selectedClusters: [FaceService.Cluster] {
        clusters.filter { selection.contains($0.id) }
    }

    private var canAct: Bool {
        !selection.isEmpty && !isSaving && !store.faces.isCoreBusy
    }

    private var canMerge: Bool {
        selection.count >= 2 && !isSaving && !store.faces.isCoreBusy
    }

    var body: some View {
        ScrollView {
            let clusters = clusters
            let suggestions = suggestions
            if clusters.isEmpty && suggestions.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !suggestions.isEmpty {
                        sectionHeader("Suggested Merges")
                        VStack(spacing: 0) {
                            ForEach(suggestions) { group in
                                NavigationLink(value: CollectionsRoute.mergeProposal(group.clusterIDs)) {
                                    MergeSuggestionRow(group: group)
                                }
                                .buttonStyle(.plain)
                                .disabled(isSelecting)
                                Divider()
                            }
                        }
                    }

                    if !clusters.isEmpty {
                        if !suggestions.isEmpty { sectionHeader("New Groups") }
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(clusters) { cluster in
                                clusterCell(cluster)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Design.bg)
        .navigationTitle("New People")
        .navigationBarTitleDisplayMode(.inline)
        .softTopScrollEdge()
        .toolbar {
            if !clusters.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        selection.removeAll()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                actionBar
            }
        }
        .sheet(isPresented: $showNameSheet) {
            PeopleReviewNameSheet(
                selectedCount: selection.count,
                namedClusters: store.faces.namedClusters
            ) { name in
                showNameSheet = false
                applyName(name)
            }
        }
        .alert(
            pendingMerge?.buttonLabel ?? pendingNaming?.buttonTitle ?? "Merge",
            isPresented: Binding(
                get: { pendingMerge != nil || pendingNaming != nil },
                set: { if !$0 { pendingMerge = nil; pendingNaming = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingMerge = nil
                pendingNaming = nil
            }
            Button("Merge") {
                if let naming = pendingNaming {
                    pendingNaming = nil
                    perform(naming)
                } else if let plan = pendingMerge {
                    pendingMerge = nil
                    merge(plan)
                }
            }
        } message: {
            if let naming = pendingNaming {
                Text(naming.confirmation)
            } else if let plan = pendingMerge {
                Text(plan.confirmation)
            }
        }
        .alert("Ignore groups?", isPresented: Binding(
            get: { pendingIgnoreCount > 0 },
            set: { if !$0 { pendingIgnoreCount = 0 } }
        )) {
            Button("Cancel", role: .cancel) { pendingIgnoreCount = 0 }
            Button("Ignore", role: .destructive) { ignoreSelected() }
        } message: {
            Text(ignoreMessage)
        }
        .alert("Not a face?", isPresented: Binding(
            get: { pendingRejectCount > 0 },
            set: { if !$0 { pendingRejectCount = 0 } }
        )) {
            Button("Cancel", role: .cancel) { pendingRejectCount = 0 }
            Button("Not a Face", role: .destructive) { rejectSelected() }
        } message: {
            Text(rejectMessage)
        }
        .refreshable { await store.faces.refreshClusters() }
        .task {
            // The list can be stale: a scan may have run, or a re-cluster may
            // have rebuilt the partition, since this screen was last on top.
            await store.faces.refreshClusters()
        }
        .onChange(of: clusters.map(\.id)) { _, remaining in
            selection = selection.intersection(remaining)
            if remaining.isEmpty {
                isSelecting = false
            }
        }
    }

    @ViewBuilder
    private func clusterCell(_ cluster: FaceService.Cluster) -> some View {
        if isSelecting {
            Button {
                toggle(cluster.id)
            } label: {
                ClusterCard(
                    cluster: cluster,
                    isDimmed: !selection.contains(cluster.id),
                    isChecked: selection.contains(cluster.id)
                )
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: CollectionsRoute.clusterReview(cluster.id)) {
                ClusterCard(cluster: cluster)
            }
            .buttonStyle(.plain)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if let error = store.faces.lastError, error != .cancelled {
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(Design.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                showNameSheet = true
            } label: {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Name")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAct)

            Button {
                pendingMerge = MergePlan(selectedClusters)
            } label: {
                Text("Merge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canMerge)

            Button(role: .destructive) {
                pendingIgnoreCount = selection.count
            } label: {
                Text("Ignore")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canAct)

            Button(role: .destructive) {
                pendingRejectCount = selection.count
            } label: {
                Text("Not a Face")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canAct)

            Text(actionFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Design.bg)
    }

    private var actionFooter: String {
        if store.faces.isCoreBusy {
            return "A scan is running — naming is paused until it finishes."
        }
        return "Name, merge, ignore, or mark the selected groups as not a face."
    }

    private var ignoreMessage: String {
        let count = pendingIgnoreCount
        let groups = count == 1 ? "This group" : "These \(count) groups"
        return "\(groups) won’t be offered again. They are faces, just not someone this library is naming. Anything already written for them is taken back out of the sidecars."
    }

    private var rejectMessage: String {
        let count = pendingRejectCount
        let groups = count == 1 ? "This group" : "These \(count) groups"
        return "\(groups) will be dismissed as not a face and won’t be offered again. Anything already written for them is taken back out of the sidecars."
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Design.ink2)
            .textCase(.uppercase)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.square.badge.camera")
                .font(.system(size: 34))
                .foregroundStyle(Design.ink3)
            Text("Nothing to review")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Design.ink)
            Text(
                "Every unlabeled face group appears here after a photo scan, including singles. Run one from Settings › On-device Tagging."
            )
            .font(.system(size: 13))
            .foregroundStyle(Design.ink2)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    private func toggle(_ id: Int64) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func applyName(_ typed: String) {
        guard let outcome = PeopleReviewNaming.outcome(
            selected: selectedClusters,
            typed: typed,
            named: store.faces.namedClusters
        ) else { return }
        if outcome.needsConfirmation {
            pendingNaming = outcome
        } else {
            perform(outcome)
        }
    }

    private func perform(_ outcome: PeopleReviewNaming.Outcome) {
        isSaving = true
        Task {
            let ok: Bool
            switch outcome {
            case .name(let id, let name):
                ok = await store.faces.name(cluster: id, as: name)
            case .merge(let plan):
                ok = await store.faces.merge(
                    into: plan.survivor.id,
                    absorbing: plan.absorbed.map(\.id)
                )
            case .mergeThenName(let plan, let name):
                let merged = await store.faces.merge(
                    into: plan.survivor.id,
                    absorbing: plan.absorbed.map(\.id)
                )
                if merged {
                    ok = await store.faces.name(cluster: plan.survivor.id, as: name)
                } else {
                    ok = false
                }
            }
            if ok {
                selection.removeAll()
                isSelecting = false
            }
            isSaving = false
        }
    }

    private func merge(_ plan: MergePlan) {
        isSaving = true
        Task {
            let ok = await store.faces.merge(
                into: plan.survivor.id,
                absorbing: plan.absorbed.map(\.id)
            )
            if ok {
                selection.removeAll()
                isSelecting = false
            }
            isSaving = false
        }
    }

    private func ignoreSelected() {
        pendingIgnoreCount = 0
        dismissSelected(ignore: true)
    }

    private func rejectSelected() {
        pendingRejectCount = 0
        dismissSelected(ignore: false)
    }

    private func dismissSelected(ignore: Bool) {
        let ids = Array(selection)
        isSaving = true
        Task {
            var ok = true
            for id in ids {
                if ignore {
                    ok = await store.faces.ignore(cluster: id)
                } else {
                    ok = await store.faces.reject(cluster: id)
                }
                if !ok { break }
            }
            if ok {
                selection.removeAll()
                isSelecting = false
            }
            isSaving = false
        }
    }
}

/// Native name field for the New People selection. Save vs merge follows
/// `PeopleReviewNaming` — the same rule as the single-group screen.
private struct PeopleReviewNameSheet: View {
    let selectedCount: Int
    let namedClusters: [FaceService.Cluster]
    let onSave: (String) -> Void

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var mergesIntoExisting: Bool {
        namedClusters.contains {
            $0.name?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmed.isEmpty
    }

    private var suggestions: [PersonNameSuggestions.Item] {
        PersonNameSuggestions.matching(
            typed: name,
            libraryNames: store.people.peopleTags.map(\.displayName),
            contacts: store.contacts,
            linkedContactIDs: store.linkedContactIDs
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { attemptSave() }

                    if !suggestions.isEmpty {
                        NameSuggestionChips(items: suggestions) { name = $0 }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                    }
                } header: {
                    Text(selectedCount == 1 ? "Name this group" : "Name these \(selectedCount) groups")
                }
            }
            .navigationTitle("Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mergesIntoExisting ? "Merge Person" : "Save Person") { attemptSave() }
                        .disabled(!canSave)
                }
            }
            .task {
                focused = true
                await store.loadContacts()
            }
        }
    }

    private func attemptSave() {
        guard canSave else { return }
        onSave(trimmed)
    }
}
