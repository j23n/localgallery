import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    var isVideo: Bool = false
    var isLivePhoto: Bool = false
    var cornerRadius: CGFloat = 0
    /// True when the URL is a file-provider placeholder (bytes not yet on
    /// disk). Drives the remote badge + the QuickLook thumbnail fallback.
    /// Callers pass `photo.locality.isRemotePlaceholder`; pure-URL call sites
    /// (folder covers etc.) accept the default. Pre-resolving this here
    /// avoids a per-cell `URLResourceValues` syscall on the main thread —
    /// that was stuttering scroll on the 20k All Photos grid.
    var isRemote: Bool = false
    @Environment(GalleryStore.self) private var store
    @State private var thumbnail: UIImage?
    @State private var thumbnailMissing: Bool = false

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .transition(.opacity)
            } else if thumbnailMissing {
                // Load finished with nothing to show — provider didn't vend
                // a thumb, or the local source file is gone. Same glyph tile
                // either way so the cell doesn't shimmer forever.
                Rectangle()
                    .fill(Color(.systemGray6))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: max(16, size * 0.2)))
                            .foregroundStyle(.secondary)
                    )
                    .transition(.opacity)
            } else {
                ShimmerView()
                    .frame(width: size, height: size)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isRemote {
                RemoteBadge(size: max(10, size * 0.09))
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: max(10, size * 0.1)))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if isLivePhoto && !isVideo {
                Text("LIVE")
                    .font(.system(size: max(8, size * 0.08), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .animation(.easeIn(duration: 0.2), value: thumbnail != nil)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // Keyed on size too: pinch-zooming the grid to a larger tier must
        // re-decode already-visible cells, or they keep their small decode
        // and render soft until recycled.
        .task(id: ThumbKey(url: url, size: Int(size))) {
            let result = await store.thumbnail(
                for: url,
                size: CGSize(width: size, height: size),
                isVideo: isVideo,
                useQuickLook: isRemote
            )
            self.thumbnail = result
            self.thumbnailMissing = (result == nil)
        }
    }
}

/// Identity for the thumbnail-loading task — re-fires on URL *or* cell-size
/// change.
private struct ThumbKey: Hashable {
    let url: URL
    let size: Int
}

// MARK: - Shimmer Placeholder

struct ShimmerView: View {
    @State private var isAnimating = false

    var body: some View {
        Rectangle()
            .fill(Color(.systemGray6))
            .overlay(
                Color(.systemGray4)
                    .opacity(isAnimating ? 0.35 : 0)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}
