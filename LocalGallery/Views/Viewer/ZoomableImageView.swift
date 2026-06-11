import SwiftUI
import UIKit

// MARK: - Zoomable Image (UIScrollView-based)

/// Custom UIScrollView that re-fits its image subview whenever bounds change.
/// Without this, the initial `makeUIView` call runs before the scrollView has
/// been laid out, so bounds are zero and the imageView frame stays zero —
/// the viewer comes up black until the user zooms or swipes. SwiftUI does
/// not guarantee a follow-up `updateUIView` call purely from a layout pass,
/// so we drive the re-fit from UIKit.
final class ZoomingScrollView: UIScrollView {
    weak var imageView: UIImageView?
    /// When true, the image bottom-aligns inside its container (used while
    /// the info drawer is open so the photo sits flush against the info
    /// panel — Apple Photos style). Otherwise centered.
    var bottomAlign: Bool = false
    private var lastLaidOutBounds: CGSize = .zero
    private var lastLaidOutBottomAlign: Bool = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView, imageView.image != nil else { return }
        // Only re-fit when bounds or alignment change AND the user hasn't
        // zoomed in — otherwise a scroll/zoom gesture would fight with
        // automatic fitting.
        let needsRefit = bounds.size != lastLaidOutBounds || bottomAlign != lastLaidOutBottomAlign
        if needsRefit, zoomScale == minimumZoomScale {
            lastLaidOutBounds = bounds.size
            lastLaidOutBottomAlign = bottomAlign
            fitImage()
        }
    }

    func fitImage() {
        guard let imageView, let image = imageView.image else { return }
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let fit = min(b.width / image.size.width, b.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        let xOffset = max(0, (b.width - size.width) / 2)
        let yOffset = bottomAlign
            ? max(0, b.height - size.height)
            : max(0, (b.height - size.height) / 2)
        imageView.center = CGPoint(x: size.width / 2 + xOffset, y: size.height / 2 + yOffset)
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var isZoomEnabled: Bool = true
    var bottomAlign: Bool = false
    var onSingleTap: () -> Void = {}
    var onZoomChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = isZoomEnabled ? 5.0 : 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bottomAlign = bottomAlign

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = .zero
        imageView.tag = 100
        scrollView.addSubview(imageView)
        scrollView.imageView = imageView

        // Double-tap to zoom
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Single-tap to toggle chrome
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: ZoomingScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChange = onZoomChange
        let newMax: CGFloat = isZoomEnabled ? 5.0 : 1.0
        if scrollView.maximumZoomScale != newMax {
            scrollView.maximumZoomScale = newMax
            if !isZoomEnabled && scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            }
        }
        if scrollView.bottomAlign != bottomAlign {
            scrollView.bottomAlign = bottomAlign
            // layoutSubviews picks the new alignment up via lastLaidOutBottomAlign
            scrollView.setNeedsLayout()
        }
        guard let imageView = scrollView.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            scrollView.zoomScale = 1.0
            scrollView.fitImage()
            context.coordinator.reportZoom(scale: 1.0)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChange: onZoomChange)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var onSingleTap: () -> Void
        var onZoomChange: (Bool) -> Void
        private var lastReportedZoomed = false

        init(onSingleTap: @escaping () -> Void, onZoomChange: @escaping (Bool) -> Void) {
            self.onSingleTap = onSingleTap
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView = scrollView.viewWithTag(100) else { return }
            let boundsSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize
            let xOffset = max(0, (boundsSize.width - contentSize.width) / 2)
            let yOffset = max(0, (boundsSize.height - contentSize.height) / 2)
            imageView.center = CGPoint(
                x: contentSize.width / 2 + xOffset,
                y: contentSize.height / 2 + yOffset
            )
            reportZoom(scale: scrollView.zoomScale)
        }

        func reportZoom(scale: CGFloat) {
            let zoomed = scale > 1.001
            if zoomed != lastReportedZoomed {
                lastReportedZoomed = zoomed
                onZoomChange(zoomed)
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let location = gesture.location(in: scrollView.viewWithTag(100))
                let zoomRect = CGRect(
                    x: location.x - 50,
                    y: location.y - 50,
                    width: 100,
                    height: 100
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }
    }
}

