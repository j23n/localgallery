import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    @EnvironmentObject var manager: GalleryManager
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            thumbnail = await manager.thumbnail(for: url, size: CGSize(width: size, height: size))
        }
    }
}
