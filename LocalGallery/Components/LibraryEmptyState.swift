import SwiftUI

/// Shared "choose a folder to get started" empty state used by the three
/// main tabs before a library folder has been picked.
struct LibraryEmptyState: View {
    let icon: String
    let title: String
    var message: String = "Choose a folder in Settings to get started."

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(Design.accentColor.opacity(0.7))
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Design.ink2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}
