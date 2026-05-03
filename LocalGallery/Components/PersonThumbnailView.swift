import SwiftUI
import UIKit

/// People-rail thumbnail. When `region` is non-nil, crops the source image to
/// the face rectangle plus 1× padding on each side (per the user spec:
/// `[x(padding) – 2x(face) – x(padding)]` → total span = 3× the region's
/// extent). Falls back to the standard `ThumbnailView` aspect-fill when no
/// region is provided.
///
/// We load the full image rather than the cached 128px thumbnail so the crop
/// has enough resolution to render a recognisable face. The full image goes
/// through `ThumbnailService.loadFullImage`, which caches at 2000px on a
/// shared NSCache — so subsequent People rail renders are cheap.
struct PersonThumbnailView: View {
    let url: URL
    let region: FaceRegion?
    let size: CGFloat
    var cornerRadius: CGFloat = 0

    @Environment(GalleryStore.self) private var store
    @State private var fullImage: UIImage?
    @State private var placeholder: UIImage?

    var body: some View {
        Group {
            if region == nil {
                ThumbnailView(url: url, size: size, cornerRadius: cornerRadius)
                    .frame(width: size, height: size)
            } else if let fullImage {
                Image(uiImage: fullImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if let placeholder {
                Image(uiImage: placeholder)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                ShimmerView()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let region else { return }
        // Quick placeholder — the cached thumbnail (uncropped) so the cell
        // never sits on a shimmer for long.
        placeholder = await store.thumbnail(
            for: url, size: CGSize(width: size, height: size), isVideo: false
        )
        guard let full = await store.loadFullImage(for: url) else { return }
        fullImage = Self.crop(full, to: region)
    }

    /// Crop with `1× region width / height` padding on each axis, clamped to
    /// the image bounds. Returns the original image when the region is too
    /// small after clamping to be useful.
    static func crop(_ image: UIImage, to region: FaceRegion) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // MWG: centre + extent, normalized.
        let cx = CGFloat(region.centerX) * imgW
        let cy = CGFloat(region.centerY) * imgH
        let rW = CGFloat(region.width) * imgW
        let rH = CGFloat(region.height) * imgH

        // 1× padding on each side → span = 3× region extent.
        let span = max(rW, rH) * 3
        var rect = CGRect(
            x: cx - span / 2,
            y: cy - span / 2,
            width: span, height: span
        )
        // Clamp to image bounds — shift instead of shrink so the face stays
        // centred when we hit an edge.
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        if rect.maxX > imgW { rect.origin.x = imgW - rect.width }
        if rect.maxY > imgH { rect.origin.y = imgH - rect.height }
        // After shifting, the rect can still be larger than the image on one
        // axis — final clamp keeps it in bounds at the cost of breaking the
        // square aspect, which the SwiftUI fill-clip will re-square.
        rect = rect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard rect.width > 8, rect.height > 8,
              let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
