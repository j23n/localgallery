import SwiftUI

/// One unlabeled face cluster in the review grid: the best crop the core could
/// find, the face count, and a strip of the other exemplars.
///
/// The crop is `PersonThumbnailView` with the region the core returned —
/// unchanged, because the core hands back MWG-shaped geometry precisely so the
/// existing cover-crop path takes it (`FaceService.Face`).
struct ClusterCard: View {
    let cluster: FaceService.Cluster

    private static let side: CGFloat = 108

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = cluster.exemplars.first {
                PersonThumbnailView(
                    url: cover.url,
                    region: cover.region,
                    size: Self.side
                )
            } else {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .overlay {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 26))
                            .foregroundStyle(Design.ink3)
                    }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: UnitPoint(x: 0.5, y: 0.5),
                endPoint: .bottom
            )

            HStack(spacing: 6) {
                Text(faceCountLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                // The remaining exemplars as a tiny strip: enough to tell "all
                // the same person" from "this cluster is a mess" without
                // opening it.
                HStack(spacing: -4) {
                    ForEach(cluster.exemplars.dropFirst().prefix(3)) { face in
                        PersonThumbnailView(
                            url: face.url,
                            region: face.region,
                            size: 18,
                            cornerRadius: 9
                        )
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        .clipShape(Circle())
                    }
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .accessibilityLabel("Unnamed person, \(faceCountLabel)")
    }

    private var faceCountLabel: String {
        cluster.size == 1 ? "1 face" : "\(cluster.size) faces"
    }
}
