import SwiftUI

/// One "these two look like the same person" suggestion: a strip of crops from
/// each group, how sure the core is in words, and the two answers.
///
/// The crops are the whole point — a similarity number tells the user nothing
/// they can check, and two rows of faces tell them everything. `Merge` is
/// directional (see `MergeDirection`) and the button says which group survives.
struct MergeSuggestionRow: View {
    let proposal: FaceService.Proposal
    let direction: MergeDirection
    let onMerge: () -> Void
    let onDismiss: () -> Void

    @Environment(GalleryStore.self) private var store

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

            faceStrip(direction.survivor)
            faceStrip(direction.absorbed)

            Text(direction.confirmation)
                .font(.footnote)
                .foregroundStyle(Design.ink2)

            HStack(spacing: 10) {
                Button(direction.buttonLabel, action: onMerge)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Not the Same", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            .disabled(store.faces.isCoreBusy)
        }
        .padding(.vertical, 6)
    }

    private func faceStrip(_ cluster: FaceService.Cluster) -> some View {
        HStack(spacing: 6) {
            ForEach(cluster.exemplars) { face in
                PersonThumbnailView(
                    url: face.url,
                    region: face.region,
                    size: 48,
                    cornerRadius: 8
                )
            }
            if let name = cluster.name {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Design.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// The similarity as something a person can act on. The exact cosine is
    /// meaningless outside the clustering thresholds, and showing it invites
    /// the user to compare two numbers that were never on the same scale.
    private var confidence: String {
        switch proposal.similarity {
        case 0.9...: return "Very likely the same person"
        case 0.8..<0.9: return "Likely the same person"
        default: return "Possibly the same person"
        }
    }

    private var sizeLabel: String {
        "\(direction.survivor.size) + \(direction.absorbed.size) faces"
    }
}
