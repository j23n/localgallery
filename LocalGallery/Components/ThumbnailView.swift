import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    var isVideo: Bool = false
    var isLivePhoto: Bool = false
    var cornerRadius: CGFloat = 0
    @Environment(GalleryStore.self) private var store
    @State private var thumbnail: UIImage?
    @State private var isRemotePlaceholder: Bool = false
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
            } else if thumbnailMissing && isRemotePlaceholder {
                // Provider didn't vend a thumbnail. Show a plain placeholder
                // tile with a photo glyph so the grid doesn't stall on a
                // forever-spinning shimmer.
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

            if isRemotePlaceholder {
                VStack {
                    HStack {
                        Spacer()
                        RemoteBadge(size: max(10, size * 0.09))
                            .padding(4)
                    }
                    Spacer()
                }
            }

            if isVideo {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.system(size: max(10, size * 0.1)))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
            } else if isLivePhoto {
                VStack {
                    HStack {
                        Text("LIVE")
                            .font(.system(size: max(8, size * 0.08), weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .animation(.easeIn(duration: 0.2), value: thumbnail != nil)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: url) {
            // Per-file probe is metadata-only (one URLResourceValues read),
            // so cheap enough to do unconditionally — purely-local libraries
            // come back as `.local` and skip the QL path.
            let probe = FileProviderDetector.probe(url)
            let isPlaceholder = probe.isFileProvider && probe.status != .local
            self.isRemotePlaceholder = isPlaceholder
            let result = await store.thumbnail(
                for: url,
                size: CGSize(width: size, height: size),
                isVideo: isVideo,
                useQuickLook: isPlaceholder
            )
            self.thumbnail = result
            self.thumbnailMissing = (result == nil)
        }
    }
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
