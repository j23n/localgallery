import SwiftUI

/// The face-review queue: unlabeled clusters the core has found, waiting for a
/// name, plus the pairs it thinks are the same person.
///
/// Reached from the People screen when `store.faces.reviewableClusters` is
/// non-empty. Each card is one cluster; tapping it opens `ClusterReviewView`,
/// which is where naming, dismissing and splitting happen — deliberately one
/// action per screen rather than inline, because they all write to every photo
/// the cluster reaches.
///
/// Merge suggestions sit above the grid rather than inside it: they are about
/// two groups at once, and the answer ("yes, one person" / "no, two people") is
/// a judgement the crops themselves settle. Nothing merges on its own — the
/// core proposes, the user decides.
struct PeopleReviewView: View {
    @Environment(GalleryStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    /// Proposals resolved against the cluster list, in the same order the core
    /// returned them (strongest first).
    ///
    /// A proposal naming a group this screen does not have is dropped: the two
    /// reads come from one crossing, so that means the cluster is ignored or
    /// otherwise not on offer, and a row with one strip of faces answers
    /// nothing.
    private var suggestions: [(proposal: FaceService.Proposal, direction: MergeDirection)] {
        let byID = Dictionary(uniqueKeysWithValues: store.faces.allClusters.map { ($0.id, $0) })
        return store.faces.mergeProposals.compactMap { proposal in
            guard let a = byID[proposal.a], let b = byID[proposal.b],
                  let direction = MergeDirection(a, b) else { return nil }
            return (proposal, direction)
        }
    }

    var body: some View {
        ScrollView {
            let clusters = store.faces.reviewableClusters
            let suggestions = suggestions
            if clusters.isEmpty && suggestions.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !suggestions.isEmpty {
                        sectionHeader("Suggested Merges")
                        VStack(spacing: 0) {
                            ForEach(suggestions, id: \.proposal.id) { entry in
                                MergeSuggestionRow(
                                    proposal: entry.proposal,
                                    direction: entry.direction,
                                    onMerge: { merge(entry.direction) },
                                    onDismiss: { dismiss(entry.proposal) }
                                )
                                Divider()
                            }
                        }
                    }

                    if !clusters.isEmpty {
                        if !suggestions.isEmpty { sectionHeader("New Groups") }
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(clusters) { cluster in
                                NavigationLink(value: CollectionsRoute.clusterReview(cluster.id)) {
                                    ClusterCard(cluster: cluster)
                                }
                                .buttonStyle(.plain)
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
        .refreshable { await store.faces.refreshClusters() }
        .task {
            // The list can be stale: a scan may have run, or a re-cluster may
            // have rebuilt the partition, since this screen was last on top.
            await store.faces.refreshClusters()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Design.ink2)
            .textCase(.uppercase)
    }

    private func merge(_ direction: MergeDirection) {
        Task {
            await store.faces.merge(into: direction.survivor.id, from: direction.absorbed.id)
        }
    }

    private func dismiss(_ proposal: FaceService.Proposal) {
        Task { await store.faces.dismissProposal(proposal) }
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
                "Groups of at least \(FaceService.reviewMinimumFaces) faces appear here after a face scan. Run one from Settings › On-device Tagging."
            )
            .font(.system(size: 13))
            .foregroundStyle(Design.ink2)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }
}
