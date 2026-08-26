import SwiftUI

/// The People screen's doorway into the face-review queue.
///
/// Shown only when there is something to review, so its presence is the whole
/// message — no empty "0 new people" row to explain away.
struct PeopleReviewRow: View {
    /// Unlabeled clusters waiting for a name or Ignore.
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Design.accentSoft)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "person.crop.square.badge.camera")
                        .font(.system(size: 21))
                        .foregroundStyle(Design.accentColor)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Review New People")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Design.ink)
                Text(count == 1 ? "1 group found" : "\(count) groups found")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Design.ink2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Shown on the People rail while a scan is running and nobody is named yet,
/// so the section isn't an empty header waiting for clusters to land.
struct PeopleScanningCard: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Design.bgGrouped
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            )

            Text("Finding people…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.bottom, 7)
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}
