import SwiftUI

/// The People screen's doorway into the face-review queue.
///
/// Shown only when there is something to review, so its presence is the whole
/// message — no empty "0 new people" row to explain away.
struct PeopleReviewRow: View {
    /// Unlabeled clusters over `FaceService.reviewMinimumFaces`.
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
