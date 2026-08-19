import SwiftUI

/// Shared empty / unavailable state for the three library tabs. The default
/// copy is the "pick a folder" path; callers override `message` when a
/// folder is already selected, and pass both `retryTitle` and `onRetry` when
/// the recovery action is a rescan rather than a trip to Settings.
struct LibraryEmptyState: View {
    let icon: String
    let title: String
    var message: String = "Choose a folder in Settings to get started."
    var retryTitle: String? = nil
    var onRetry: (() -> Void)? = nil

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
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.accentColor)
            }
        }
        .padding(32)
    }

    /// Bookmark exists but the root is gone or unlistable. Retry is a
    /// non-silent light scan so progress UI is visible — a silent pass would
    /// look like the button did nothing.
    static func unavailable(icon: String, onRetry: @escaping () -> Void) -> LibraryEmptyState {
        LibraryEmptyState(
            icon: icon,
            title: "Library Unavailable",
            message: "The selected folder can’t be found. It may have been moved or is temporarily offline.",
            retryTitle: "Retry",
            onRetry: onRetry
        )
    }

    /// Folder is selected and listable, but the walk found no images.
    /// Distinct from the default copy so we don't send the user to Settings
    /// to "choose a folder" they already chose.
    static func selectedFolderEmpty(icon: String, title: String) -> LibraryEmptyState {
        LibraryEmptyState(
            icon: icon,
            title: title,
            message: "The selected folder doesn’t contain any images."
        )
    }
}
