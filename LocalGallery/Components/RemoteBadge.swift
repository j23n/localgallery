import SwiftUI

/// Small SF Symbol overlay rendered in the top-right of a thumbnail tile to
/// indicate the photo is backed by a file provider and not yet downloaded
/// locally. The grid still shows a thumbnail (vended by the provider via
/// QuickLook); the badge tells the user a tap will trigger a download.
struct RemoteBadge: View {
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: "icloud.and.arrow.down")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
    }
}
