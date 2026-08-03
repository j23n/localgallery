import SwiftUI

/// The face-review queue: unlabeled clusters the core has found, waiting for a
/// name.
///
/// Reached from the People screen when `store.faces.reviewableClusters` is
/// non-empty. Each card is one cluster; tapping it opens `ClusterReviewView`,
/// which is where naming and dismissing actually happen — deliberately one
/// action per screen rather than inline, because both write to every photo the
/// cluster reaches.
///
/// Merge and split are **not** here. The core computes merge proposals but
/// applying one is not implemented (Phase 2 status), and offering half of it
/// would be worse than offering none.
struct PeopleReviewView: View {
    @Environment(GalleryStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    var body: some View {
        ScrollView {
            let clusters = store.faces.reviewableClusters
            if clusters.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(clusters) { cluster in
                        NavigationLink(value: CollectionsRoute.clusterReview(cluster.id)) {
                            ClusterCard(cluster: cluster)
                        }
                        .buttonStyle(.plain)
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
