import SwiftUI
import UIKit

/// People-rail thumbnail. When `region` is non-nil, crops a sized ImageIO
/// decode to the detected MWG box plus a little padding on each axis. The
/// crop is the face rectangle, not a square of the longer side: twenty faces
/// in a row are each ~5% of the photo width, and a square of the (taller)
/// head would pull in the neighbours. SwiftUI fill-clips that rect into the
/// square cell. Falls back to `ThumbnailView` when no region is provided.
///
/// Decode is the same gated ImageIO path the photo grid uses, not
/// `loadFullImage`. The source is dropped after the crop so a review grid
/// does not hold one viewer-sized bitmap per face.
struct PersonThumbnailView: View {
    /// Padding on each side of the MWG box, as a fraction of that axis.
    /// 0.1 → 10% extra per side (1.2× the box). Enough for a hairline,
    /// tight enough that a packed lineup still reads as one face.
    static let cropPadding: CGFloat = 0.1
    /// Upper bound for the decode used to cut a crop. Same cap as the
    /// viewer's `loadFullImage` path — small faces need the pixels, but
    /// we never keep this bitmap after cropping.
    static let sourceMaxPixelSize: CGFloat = 2000

    let url: URL
    let region: FaceRegion?
    let size: CGFloat
    var cornerRadius: CGFloat = 0
    var isRemote: Bool = false

    @Environment(GalleryStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        Group {
            if region == nil {
                ThumbnailView(url: url, size: size, cornerRadius: cornerRadius, isRemote: isRemote)
                    .frame(width: size, height: size)
            } else if let image {
                Image(uiImage: image)
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
        .task(id: cropTaskID) {
            await load()
        }
    }

    /// URL plus the region, so two faces in the same group photo do not
    /// reuse one view's crop when SwiftUI recycles the cell.
    private var cropTaskID: String {
        guard let region else { return url.path }
        return "\(url.path)#\(region.centerX),\(region.centerY),\(region.width),\(region.height)#\(Int(size))"
    }

    private func load() async {
        guard let region else { return }
        image = await store.faceCrop(for: url, region: region, cellSize: size)
    }

    /// Longest source edge so the face fills `cellSize` after cropping.
    /// Tiny faces would otherwise demand a 4k decode; those are capped.
    static func sourcePixelSize(
        cellSize: CGFloat,
        region: FaceRegion,
        scale: CGFloat
    ) -> CGFloat {
        let cellPx = max(cellSize * scale, 1)
        let frac = CGFloat(max(region.width, region.height, 0.04))
        return min(sourceMaxPixelSize, max(cellPx, (cellPx / frac).rounded()))
    }

    /// Crop around the face. Clamped to the image bounds — when the face is
    /// near an edge we shift the rect rather than shrink it so the face
    /// stays as centred as the photo allows.
    static func crop(_ image: UIImage, to region: FaceRegion) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let rect = cropRect(
            imageSize: CGSize(width: imgW, height: imgH),
            region: region
        )
        guard rect.width > 8, rect.height > 8,
              let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// The padded MWG box. Axes are padded independently so a tall head in a
    /// packed row does not grow the crop sideways into the next person.
    static func cropRect(imageSize: CGSize, region: FaceRegion) -> CGRect {
        let imgW = imageSize.width
        let imgH = imageSize.height
        let cx = CGFloat(region.centerX) * imgW
        let cy = CGFloat(region.centerY) * imgH
        let rW = max(CGFloat(region.width) * imgW, 8)
        let rH = max(CGFloat(region.height) * imgH, 8)
        let padW = rW * cropPadding
        let padH = rH * cropPadding
        var rect = CGRect(
            x: cx - rW / 2 - padW,
            y: cy - rH / 2 - padH,
            width: rW + 2 * padW,
            height: rH + 2 * padH
        )
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        if rect.maxX > imgW { rect.origin.x = imgW - rect.width }
        if rect.maxY > imgH { rect.origin.y = imgH - rect.height }
        return rect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    }
}
