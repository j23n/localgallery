import SwiftUI

// MARK: - Memory Card (large, rounded, gradient caption)

struct MemoryCardView: View {
    let memory: Memory
    @Environment(GalleryStore.self) private var store

    private var coverPhoto: PhotoFile? {
        if let p = store.photo(byID: memory.coverPhotoID) { return p }
        return memory.photoIDs.lazy.compactMap { store.photo(byID: $0) }.first
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let photo = coverPhoto {
                ThumbnailView(url: photo.url, size: 328, isRemote: photo.locality.isRemotePlaceholder)
                    .frame(width: 264, height: 328)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .frame(width: 264, height: 328)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Design.ink3)
                    }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: UnitPoint(x: 0.5, y: 0.4),
                endPoint: .bottom
            )
            .frame(width: 264, height: 328)

            VStack(alignment: .leading, spacing: 3) {
                Text(memory.title)
                    .font(Design.serifItalic(22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle = memory.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(14)
        }
        .frame(width: 264, height: 328)
        .clipShape(RoundedRectangle(cornerRadius: Design.memoryRadius))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

