import SwiftUI

/// One suggested-merge group on the review list: every face the core paired,
/// how sure it is in words, and a tap through to the select-to-merge screen.
///
/// The crops are the whole point — a similarity number tells the user nothing
/// they can check. Exemplars used to cap this at four per group; a merge
/// decision needs the rest of the photos too, which is why this loads every
/// face and why the tap opens `MergeProposalView` rather than merging inline.
struct MergeSuggestionRow: View {
    let group: MergeGroup

    @Environment(GalleryStore.self) private var store
    @State private var faces: [FaceService.Face] = []

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 4)]

    private var clusters: [FaceService.Cluster] {
        let byID = Dictionary(uniqueKeysWithValues: store.faces.allClusters.map { ($0.id, $0) })
        return group.clusterIDs.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(confidence)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.ink)
                Spacer(minLength: 0)
                Text(sizeLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(displayedFaces) { face in
                    PersonThumbnailView(
                        url: face.url,
                        region: face.region,
                        size: 48,
                        cornerRadius: 8
                    )
                    .frame(width: 48, height: 48)
                }
            }

            HStack(spacing: 6) {
                Text(namesLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Design.ink3)
            }
        }
        .padding(.vertical, 6)
        .task(id: group.clusterIDs) {
            var loaded: [FaceService.Face] = []
            for id in group.clusterIDs {
                loaded.append(contentsOf: await store.faces.faces(inCluster: id))
            }
            faces = loaded
        }
    }

    /// Full list once loaded; exemplars until then, so the row is not empty
    /// for the length of the cluster-face queries.
    private var displayedFaces: [FaceService.Face] {
        if !faces.isEmpty { return faces }
        return clusters.flatMap(\.exemplars)
    }

    private var confidence: String {
        switch group.similarity {
        case 0.9...: return "Very likely the same person"
        case 0.8..<0.9: return "Likely the same person"
        default: return "Possibly the same person"
        }
    }

    private var sizeLabel: String {
        let faceCount = clusters.reduce(0) { $0 + $1.size }
        let groups = group.clusterCount == 1 ? "1 group" : "\(group.clusterCount) groups"
        let faces = faceCount == 1 ? "1 face" : "\(faceCount) faces"
        return "\(faces) · \(groups)"
    }

    private var namesLabel: String {
        let names = clusters.map { $0.name ?? "Unnamed" }
        if names.isEmpty { return "Review groups" }
        return names.joined(separator: " · ")
    }
}
