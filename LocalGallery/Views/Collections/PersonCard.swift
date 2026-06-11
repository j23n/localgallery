import SwiftUI

// MARK: - Person Card (single featured photo, bottom-left name)

struct PersonCard: View {
    let tag: TagSuggestion
    let featured: Bool
    @Environment(GalleryStore.self) private var store

    private var coverPhoto: PhotoFile? {
        store.people.featuredPhoto(for: tag)
    }

    /// True when this person resolves to a contact (manual link or auto-match
    /// by name). False when explicitly unlinked or no contact matches.
    private var isLinkedToContact: Bool {
        store.effectiveContact(forPersonPath: tag.fullPath, displayName: tag.displayName) != nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let photo = coverPhoto {
                PersonThumbnailView(
                    url: photo.url,
                    region: store.people.faceRegion(for: photo, person: tag.displayName),
                    size: 128,
                    isRemote: photo.locality.isRemotePlaceholder
                )
            } else {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Design.ink3)
                    }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            )

            // Top-right badges. Featured stays rightmost (matches existing
            // muscle memory); the contact-link badge sits to its left when
            // both apply.
            HStack(spacing: 4) {
                if isLinkedToContact {
                    badgeCircle(systemName: "person.text.rectangle.fill")
                }
                if featured {
                    badgeCircle(systemName: "star.fill")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(tag.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(photoCountLabel(tag.count))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(.horizontal, 9)
            .padding(.bottom, 7)
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private func badgeCircle(systemName: String) -> some View {
        Circle()
            .fill(Color.black.opacity(0.45))
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

