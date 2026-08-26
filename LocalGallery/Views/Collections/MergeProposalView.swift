import SwiftUI

/// Every face in a suggested merge, grouped by the clusters the core paired.
///
/// Reached by tapping a Suggested Merges row. Tap a crop to open the photo.
/// Merging is a Select-mode action: the user ticks the groups that are
/// actually the same person (they start ticked, because that is the proposal)
/// and confirms. Unticked groups stay as they are.
struct MergeProposalView: View {
    let clusterIDs: [Int64]

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var facesByCluster: [Int64: [FaceService.Face]] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isSelecting = false
    @State private var selected: Set<Int64> = []
    @State private var pendingPlan: MergePlan?
    @State private var viewer: FacePhotoViewer?

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    private var clusters: [FaceService.Cluster] {
        let byID = Dictionary(uniqueKeysWithValues: store.faces.allClusters.map { ($0.id, $0) })
        return clusterIDs.compactMap { byID[$0] }
    }

    private var selectedClusters: [FaceService.Cluster] {
        clusters.filter { selected.contains($0.id) }
    }

    private var plan: MergePlan? { MergePlan(selectedClusters) }

    private var canMerge: Bool {
        selected.count >= 2 && !isSaving && !store.faces.isCoreBusy
    }

    private var allFaces: [FaceService.Face] {
        clusters.flatMap { faces(in: $0) }
    }

    private var totalFaces: Int {
        clusters.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ScrollView {
            // A single VStack, not a LazyVGrid-with-Section: the first
            // section header and its first cell were measuring against a
            // shifting lazy height, which made them (and that cell's
            // overlay) bob. Headers sit outside the grid so they have a
            // stable frame.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(confidence)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Design.ink)
                    Text(sizeLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Design.ink2)
                    if !isSelecting && clusters.count > 1 {
                        Text("Tap a face to open the photo. Use Select to choose which groups to merge.")
                            .font(.footnote)
                            .foregroundStyle(Design.ink2)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if let error = store.faces.lastError, error != .cancelled {
                    Text(error.message)
                        .font(.footnote)
                        .foregroundStyle(Design.destructive)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading faces…")
                            .font(.caption)
                            .foregroundStyle(Design.ink2)
                    }
                    .padding(16)
                } else {
                    ForEach(clusters) { cluster in
                        clusterHeader(cluster)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(faces(in: cluster)) { face in
                                faceCell(face, cluster: cluster)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .navigationTitle("Suggested Merge")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.bg)
        .softTopScrollEdge()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if clusters.count > 1 {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if isSelecting {
                            selected = Set(clusters.map(\.id))
                        } else {
                            selected.removeAll()
                        }
                    }
                    .disabled(isSaving || isLoading)
                }
            }
        }
        .alert(
            pendingPlan?.buttonLabel ?? "Merge",
            isPresented: Binding(
                get: { pendingPlan != nil },
                set: { if !$0 { pendingPlan = nil } }
            ),
            presenting: pendingPlan
        ) { plan in
            Button("Cancel", role: .cancel) { }
            Button("Merge") { merge(plan) }
        } message: { plan in
            Text(plan.confirmation)
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
        .task(id: clusterIDs) {
            await loadFaces()
        }
        .onChange(of: clusters.map(\.id)) { _, remaining in
            selected = selected.intersection(remaining)
            if remaining.count < 2, !isSaving {
                dismiss()
            }
        }
    }

    /// Pinned, not in the scroll view — a LazyVGrid below the fold keeps
    /// correcting its height as cells appear, which used to bounce this bar.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSelecting {
                Button {
                    pendingPlan = plan
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Label(plan?.buttonLabel ?? "Merge Groups", systemImage: "arrow.triangle.merge")
                    }
                }
                .disabled(!canMerge)
                Text("Tick the groups that are the same person. Unticked groups stay as they are.")
                    .font(.footnote)
                    .foregroundStyle(Design.ink2)
            }
            Button("Not the Same", role: .destructive) {
                dismissSuggestion()
            }
            .disabled(isSaving || store.faces.isCoreBusy)
            if store.faces.isCoreBusy {
                Text("A scan is running — merging is paused until it finishes.")
                    .font(.footnote)
                    .foregroundStyle(Design.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Design.bg)
    }

    private func clusterHeader(_ cluster: FaceService.Cluster) -> some View {
        HStack {
            Text(cluster.name ?? "Unnamed group")
            Text("·")
            Text(cluster.size == 1 ? "1 face" : "\(cluster.size) faces")
            Spacer(minLength: 0)
            if isSelecting {
                Image(systemName: selected.contains(cluster.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        .white,
                        selected.contains(cluster.id) ? Design.accentColor : .black.opacity(0.35)
                    )
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Design.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            toggle(cluster.id)
        }
    }

    private func faceCell(_ face: FaceService.Face, cluster: FaceService.Cluster) -> some View {
        FaceReviewThumb(
            face: face,
            isDimmed: isSelecting && !selected.contains(cluster.id),
            onTap: {
                if isSelecting {
                    toggle(cluster.id)
                } else {
                    open(face)
                }
            }
        )
    }

    private func faces(in cluster: FaceService.Cluster) -> [FaceService.Face] {
        facesByCluster[cluster.id] ?? cluster.exemplars
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func open(_ face: FaceService.Face) {
        let photo = store.photo(forFace: face)
        viewer = FacePhotoViewer(photo: photo, album: store.photos(forFaces: allFaces))
    }

    private func loadFaces() async {
        isLoading = true
        var loaded: [Int64: [FaceService.Face]] = [:]
        for id in clusterIDs {
            loaded[id] = await store.faces.faces(inCluster: id)
        }
        facesByCluster = loaded
        isLoading = false
    }

    private var similarity: Double {
        store.faces.mergeProposals
            .filter { clusterIDs.contains($0.a) && clusterIDs.contains($0.b) }
            .map(\.similarity)
            .max() ?? 0
    }

    private var confidence: String {
        switch similarity {
        case 0.9...: return "Very likely the same person"
        case 0.8..<0.9: return "Likely the same person"
        default: return "Possibly the same person"
        }
    }

    private var sizeLabel: String {
        let groups = clusters.count == 1 ? "1 group" : "\(clusters.count) groups"
        let faces = totalFaces == 1 ? "1 face" : "\(totalFaces) faces"
        return "\(faces) in \(groups)"
    }

    private func merge(_ plan: MergePlan) {
        isSaving = true
        Task {
            let ok = await store.faces.merge(
                into: plan.survivor.id,
                absorbing: plan.absorbed.map(\.id)
            )
            isSaving = false
            pendingPlan = nil
            if ok { dismiss() }
        }
    }

    private func dismissSuggestion() {
        isSaving = true
        Task {
            let proposals = store.faces.mergeProposals.filter {
                clusterIDs.contains($0.a) && clusterIDs.contains($0.b)
            }
            for proposal in proposals {
                await store.faces.dismissProposal(proposal)
            }
            isSaving = false
            dismiss()
        }
    }
}
