import SwiftUI
import UIKit
import AVFoundation
import AVKit

// MARK: - Swipe-down dismiss (UIKit gesture — doesn't conflict with TabView paging)

/// Vertical-pan installer with state-aware actions:
/// - Info drawer closed: down past 150pt dismisses the viewer; up past 150pt
///   opens the info drawer. Downward pans drive `offset` for the rubber-band
///   dim. Upward pans don't slide the photo — the drawer animates open.
/// - Info drawer open: down past 150pt closes the drawer. Touches starting
///   below `photoHeight` are ignored so the info panel's scroll view handles
///   them natively.
struct SwipeToDismissGestureInstaller: UIViewRepresentable {
    @Binding var offset: CGFloat
    @Binding var isInfoOpen: Bool
    var photoHeight: CGFloat
    var onDismiss: () -> Void
    var onOpenInfo: () -> Void
    var onCloseInfo: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            guard let host = view.parentViewController?.view else { return }
            let pan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePan(_:))
            )
            pan.delegate = context.coordinator
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            host.addGestureRecognizer(pan)
            context.coordinator.panGesture = pan
            context.coordinator.hostView = host
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.offsetBinding = $offset
        context.coordinator.isInfoOpenBinding = $isInfoOpen
        context.coordinator.photoHeight = photoHeight
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onOpenInfo = onOpenInfo
        context.coordinator.onCloseInfo = onCloseInfo
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let pan = coordinator.panGesture, let host = coordinator.hostView {
            host.removeGestureRecognizer(pan)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            offset: $offset,
            isInfoOpen: $isInfoOpen,
            photoHeight: photoHeight,
            onDismiss: onDismiss,
            onOpenInfo: onOpenInfo,
            onCloseInfo: onCloseInfo
        )
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var offsetBinding: Binding<CGFloat>
        var isInfoOpenBinding: Binding<Bool>
        var photoHeight: CGFloat
        var onDismiss: () -> Void
        var onOpenInfo: () -> Void
        var onCloseInfo: () -> Void
        var panGesture: UIPanGestureRecognizer?
        weak var hostView: UIView?

        init(
            offset: Binding<CGFloat>,
            isInfoOpen: Binding<Bool>,
            photoHeight: CGFloat,
            onDismiss: @escaping () -> Void,
            onOpenInfo: @escaping () -> Void,
            onCloseInfo: @escaping () -> Void
        ) {
            self.offsetBinding = offset
            self.isInfoOpenBinding = isInfoOpen
            self.photoHeight = photoHeight
            self.onDismiss = onDismiss
            self.onOpenInfo = onOpenInfo
            self.onCloseInfo = onCloseInfo
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let dy = gesture.translation(in: gesture.view).y
            let infoOpen = isInfoOpenBinding.wrappedValue
            switch gesture.state {
            case .changed:
                // Rubber-band only when info is closed and user is pulling down
                // to dismiss. All other states are threshold-based — no live
                // preview while dragging.
                if !infoOpen, dy > 0 {
                    offsetBinding.wrappedValue = dy
                }
            case .ended, .cancelled:
                if infoOpen {
                    if dy > 150 { onCloseInfo() }
                } else {
                    if dy > 150 {
                        onDismiss()
                    } else if dy < -150 {
                        onOpenInfo()
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        offsetBinding.wrappedValue = 0
                    }
                }
            default:
                break
            }
        }

        // Begin for vertical pans. When info is open, only begin in the photo
        // area — touches in the info panel area belong to its scroll view.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            guard abs(v.y) > abs(v.x) * 2.0 else { return false }
            if isInfoOpenBinding.wrappedValue {
                let location = pan.location(in: pan.view)
                return location.y < photoHeight
            }
            return true
        }

        // Allow TabView's scroll gesture to work simultaneously
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}

// MARK: - Efficient Pager (UIPageViewController)

struct PagingPhotoView: UIViewControllerRepresentable {
    let photos: [PhotoFile]
    let store: GalleryStore
    /// Source of truth is the photo's id, not its index. A foreground rescan
    /// can insert/remove photos and shift indices — the index would silently
    /// land on a different photo, so we keep the id stable and re-resolve
    /// the index against the current `photos` array on every update.
    @Binding var currentPhotoID: UUID
    @Binding var isChromeVisible: Bool
    @Binding var isInfoOpen: Bool

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        // Fall back to the first photo's id when the bound id is no longer in
        // `photos` — defensive against being constructed mid-rescan.
        let initialID = photos.contains(where: { $0.id == currentPhotoID })
            ? currentPhotoID
            : photos.first?.id
        if let id = initialID {
            let initial = context.coordinator.makeHostingController(for: id)
            pvc.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let current = pvc.viewControllers?.first as? IndexedHostingController,
              current.photoID != currentPhotoID,
              photos.contains(where: { $0.id == currentPhotoID }) else { return }
        // Programmatic `setViewControllers` mid-swipe trips UIPageViewController's
        // "No view controller managing visible view" assertion — its in-flight
        // transition gets interrupted while the queuing scroll view still
        // points at a view it no longer manages. Stash the request and apply
        // it from `didFinishAnimating` instead.
        if context.coordinator.isTransitioning {
            context.coordinator.pendingPhotoID = currentPhotoID
            return
        }
        context.coordinator.applyPhotoID(currentPhotoID, to: pvc)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class IndexedHostingController: UIHostingController<AnyView> {
        let photoID: UUID
        init(photoID: UUID, rootView: AnyView) {
            self.photoID = photoID
            super.init(rootView: rootView)
            view.backgroundColor = .clear
        }
        @MainActor required init?(coder: NSCoder) { fatalError() }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagingPhotoView
        /// True between `willTransitionTo` and `didFinishAnimating` for a
        /// gesture-driven swipe. While set, programmatic photoID updates are
        /// queued via `pendingPhotoID` and data-source neighbor lookups read
        /// from `photosSnapshot` so an enrichment tick that rebuilds
        /// `parent.photos` can't shift the answers UIKit gets mid-transition.
        var isTransitioning = false
        /// Photo id requested by `updateUIViewController` while a transition
        /// was in flight. Applied from `didFinishAnimating`.
        var pendingPhotoID: UUID?
        /// Photos array frozen for the duration of a manual swipe.
        private var photosSnapshot: [PhotoFile]?
        /// Weak cache so a given photoID always resolves to the same hosting
        /// controller while UIPageViewController still holds it. Returning a
        /// fresh instance on every data-source call confused the page
        /// controller's bookkeeping when the user reversed direction mid-swipe.
        private final class WeakVC { weak var vc: IndexedHostingController? }
        private var vcCache: [UUID: WeakVC] = [:]

        init(_ parent: PagingPhotoView) { self.parent = parent }

        private var activePhotos: [PhotoFile] {
            photosSnapshot ?? parent.photos
        }

        func makeHostingController(for photoID: UUID) -> IndexedHostingController {
            if let cached = vcCache[photoID]?.vc { return cached }
            // Caller guarantees `photoID` is in `activePhotos`; the firstIndex
            // lookup is the canonical resolution path post-rescan.
            let photos = activePhotos
            let idx = photos.firstIndex(where: { $0.id == photoID }) ?? 0
            let photo = photos[idx]
            let view = PhotoPageView(
                photo: photo,
                initialThumbnail: parent.store.cachedThumbnail(for: photo.url),
                isChromeVisible: parent.$isChromeVisible,
                isInfoOpen: parent.$isInfoOpen
            )
            .environment(parent.store)
            let controller = IndexedHostingController(photoID: photoID, rootView: AnyView(view))
            let box = WeakVC()
            box.vc = controller
            vcCache[photoID] = box
            return controller
        }

        func applyPhotoID(_ photoID: UUID, to pvc: UIPageViewController) {
            guard let current = pvc.viewControllers?.first as? IndexedHostingController,
                  current.photoID != photoID,
                  parent.photos.contains(where: { $0.id == photoID }) else { return }
            let curIdx = parent.photos.firstIndex(where: { $0.id == current.photoID }) ?? 0
            let tarIdx = parent.photos.firstIndex(where: { $0.id == photoID }) ?? 0
            let direction: UIPageViewController.NavigationDirection = tarIdx > curIdx ? .forward : .reverse
            let vc = makeHostingController(for: photoID)
            pvc.setViewControllers([vc], direction: direction, animated: false)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            let photos = activePhotos
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = photos.firstIndex(where: { $0.id == indexed.photoID }),
                  curIdx > 0 else { return nil }
            return makeHostingController(for: photos[curIdx - 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            let photos = activePhotos
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = photos.firstIndex(where: { $0.id == indexed.photoID }),
                  curIdx < photos.count - 1 else { return nil }
            return makeHostingController(for: photos[curIdx + 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            isTransitioning = true
            photosSnapshot = parent.photos
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTransitioning = false
            photosSnapshot = nil
            if completed, let indexed = pvc.viewControllers?.first as? IndexedHostingController {
                parent.currentPhotoID = indexed.photoID
            }
            vcCache = vcCache.filter { $0.value.vc != nil }
            if let pending = pendingPhotoID {
                pendingPhotoID = nil
                applyPhotoID(pending, to: pvc)
            }
        }
    }
}

// MARK: - Photo Viewer

struct PhotoViewerView: View {
    let photos: [PhotoFile]
    /// Identifies the currently-shown photo. Tracked by id rather than index
    /// so a rescan that re-orders or splices `photos` doesn't silently land
    /// the user on a different image.
    @Binding var currentPhotoID: UUID
    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isChromeVisible: Bool = true
    @State private var isInfoOpen: Bool = false
    @State private var dismissOffset: CGFloat = 0
    @State private var shareRequest: PhotoShareRequest?
    /// Window-derived safe-area insets. `GeometryReader { geo in … }` paired
    /// with `.ignoresSafeArea()` — the pattern this view uses to get a
    /// full-screen canvas — reports zero insets inside a `fullScreenCover`
    /// on iOS 18, so chrome layered above the canvas would slide under the
    /// status bar / home indicator. Reading the live window's insets gives
    /// us the real values, regardless of the GeometryReader's frame.
    @State private var windowInsets: EdgeInsets = .init()

    /// How much vertical space the inline info drawer occupies when fully
    /// open, as a fraction of the screen height. The remainder is the photo
    /// area, which shrinks/translates up to make room.
    private static let infoFraction: CGFloat = 0.55
    private static let infoOpenSpring: Animation = .spring(response: 0.45, dampingFraction: 0.85)

    private static func currentWindowInsets() -> EdgeInsets {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.keyWindow else { return .init() }
        let i = window.safeAreaInsets
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// Index of `currentPhotoID` within `photos`, or nil if the id isn't
    /// present (rescan removed the photo, or the array is empty).
    private var currentIndex: Int? {
        photos.firstIndex(where: { $0.id == currentPhotoID })
    }

    /// Live re-resolution via `store.photo(byID:)`: the `photos` array is
    /// captured at sheet-present time, so any enrichment that landed since
    /// (Places tags, country code) wouldn't surface in the snapshot. Fall
    /// back to the snapshot when the store has dropped the id.
    private var currentPhoto: PhotoFile? {
        guard let idx = currentIndex else { return nil }
        let snapshot = photos[idx]
        return store.photo(byID: snapshot.id) ?? snapshot
    }

    var body: some View {
        GeometryReader { geo in
            let infoHeight = geo.size.height * Self.infoFraction
            let photoHeight = isInfoOpen ? (geo.size.height - infoHeight) : geo.size.height
            let chromeVisible = isInfoOpen || isChromeVisible

            ZStack {
                Color.black
                    .opacity(dismissOffset > 0 ? max(0.3, 1.0 - Double(dismissOffset) / 300.0) : 1.0)
                    .ignoresSafeArea()

                // Shared canvas: photo on top, info panel below. Both move as
                // one unit — the photo shrinks to make room for the info panel
                // sliding up into view (Apple Photos style).
                VStack(spacing: 0) {
                    Group {
                        if !photos.isEmpty {
                            PagingPhotoView(
                                photos: photos,
                                store: store,
                                currentPhotoID: $currentPhotoID,
                                isChromeVisible: $isChromeVisible,
                                isInfoOpen: $isInfoOpen
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: geo.size.width, height: photoHeight)

                    Group {
                        if let photo = currentPhoto {
                            PhotoInfoPanel(photo: photo)
                                .environment(store)
                        } else {
                            Color(.systemGroupedBackground)
                        }
                    }
                    .frame(width: geo.size.width, height: infoHeight)
                    .opacity(isInfoOpen ? 1 : 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .offset(y: dismissOffset)
                .animation(Self.infoOpenSpring, value: isInfoOpen)

                // Filmstrip — fades out when info is open or when the user
                // taps the photo to enter focus mode (chrome hidden).
                VStack {
                    Spacer()
                    filmstrip
                        .padding(.bottom, 64 + windowInsets.bottom)
                }
                .background(
                    VStack(spacing: 0) {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.15), .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 160)
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                )
                .opacity(isChromeVisible && !isInfoOpen ? 1 : 0)
                .allowsHitTesting(isChromeVisible && !isInfoOpen)
                .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
                .animation(.easeInOut(duration: 0.25), value: isInfoOpen)
                .offset(y: dismissOffset)

                if chromeVisible {
                    // Top bar — X always; pill hidden when info is open.
                    // Pad by windowInsets.top (read from UIWindow) — the
                    // GeometryReader ignores safe areas for the full-bleed
                    // canvas, so we can't trust geo.safeAreaInsets here.
                    VStack {
                        topBar
                        Spacer()
                    }
                    .padding(.top, windowInsets.top)
                    .background(
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0.55), .black.opacity(0.15), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 120)
                            .opacity(isInfoOpen ? 0 : 1)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                    )
                    .transition(.opacity)
                    .offset(y: dismissOffset)

                    // Bottom action bar — only shown over the photo when the
                    // info drawer is closed. While the drawer is open, only
                    // the X button remains; share/info are reachable again
                    // after dismissing the drawer.
                    if !isInfoOpen {
                        VStack {
                            Spacer()
                            bottomActionBar
                        }
                        .padding(.bottom, windowInsets.bottom)
                        .transition(.opacity)
                        .offset(y: dismissOffset)
                    }
                }

            }
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
            .statusBarHidden(!chromeVisible)
            .background(
                SwipeToDismissGestureInstaller(
                    offset: $dismissOffset,
                    isInfoOpen: $isInfoOpen,
                    photoHeight: photoHeight,
                    onDismiss: { dismiss() },
                    onOpenInfo: { withAnimation(Self.infoOpenSpring) { isInfoOpen = true } },
                    onCloseInfo: { withAnimation(Self.infoOpenSpring) { isInfoOpen = false } }
                )
                .frame(width: 0, height: 0)
            )
        }
        .ignoresSafeArea()
        .onAppear { windowInsets = Self.currentWindowInsets() }
        .onChange(of: photos) { _, newPhotos in
            // Rescan dropped the photo we were viewing; dismiss instead of
            // silently landing on a different image at a stale index. Defer
            // one runloop so an in-flight UIPageViewController transition can
            // finish before teardown — dismissing mid-transition trips its
            // visible-view assertion.
            if !newPhotos.contains(where: { $0.id == currentPhotoID }) {
                DispatchQueue.main.async { dismiss() }
            }
        }
        .photoShareSheet(request: $shareRequest)
    }

    // MARK: Chrome

    private var topBar: some View {
        ZStack {
            // Centred pill — anchored to screen mid regardless of the X
            // button. Fixed width + reserved second line so the pill stays
            // the same size whether or not a given photo has location data.
            if let photo = currentPhoto, let lines = PhotoChrome.pillLines(for: photo) {
                VStack(spacing: 1) {
                    Text(lines.date ?? " ")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(lines.location ?? " ")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .multilineTextAlignment(.center)
                .frame(width: PhotoChrome.pillWidth)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.14), in: Capsule())
                .opacity(isInfoOpen ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: isInfoOpen)
            }

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.15), in: Circle())
                }
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            shareButton
            Spacer()
            infoButton
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    private var shareButton: some View {
        PhotoShareMenu(
            canResize: !(currentPhoto?.isVideo ?? false),
            onSelect: { quality in
                guard let photo = currentPhoto else { return }
                shareRequest = PhotoShareRequest(photos: [photo], quality: quality)
            }
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private var infoButton: some View {
        Button {
            withAnimation(Self.infoOpenSpring) { isInfoOpen.toggle() }
        } label: {
            Label("Info", systemImage: isInfoOpen ? "info.circle.fill" : "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isInfoOpen ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isInfoOpen ? Color.white.opacity(0.92) : Color.white.opacity(0.18),
                    in: Capsule()
                )
        }
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { photo in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                currentPhotoID = photo.id
                            }
                        } label: {
                            ThumbnailView(url: photo.url, size: 56, cornerRadius: 6, isRemote: photo.locality.isRemotePlaceholder)
                                .frame(width: 56, height: 56)
                                .scaleEffect(photo.id == currentPhotoID ? 1.08 : 1.0)
                                .overlay {
                                    if photo.id == currentPhotoID {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(.white, lineWidth: 2)
                                    }
                                }
                                .animation(.easeOut(duration: 0.2), value: currentPhotoID)
                        }
                        .buttonStyle(.plain)
                        .id(photo.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 70)
            .onAppear {
                proxy.scrollTo(currentPhotoID, anchor: .center)
            }
            .onChange(of: currentPhotoID) { _, id in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

}

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

// MARK: - Photo Page

struct PhotoPageView: View {
    let photo: PhotoFile
    var initialThumbnail: UIImage? = nil
    @Environment(GalleryStore.self) private var store
    @Binding var isChromeVisible: Bool
    @Binding var isInfoOpen: Bool

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var videoPlayer: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isPlayingLive = false
    @State private var livePlayer: AVPlayer?
    @State private var isZoomed = false
    @State private var isMaterializing = false
    @State private var materializeError: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if photo.isVideo {
                    if isPlayingVideo, let player = videoPlayer {
                        VideoPlayer(player: player)
                    } else {
                        if let img = thumbnail ?? initialThumbnail {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().tint(.white)
                        }

                        Button {
                            let player = AVPlayer(url: photo.url)
                            videoPlayer = player
                            isPlayingVideo = true
                            player.play()
                            isChromeVisible = false
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 8)
                        }
                    }
                } else {
                    if let displayImage = fullImage ?? thumbnail ?? initialThumbnail {
                        ZoomableImageView(
                            image: displayImage,
                            isZoomEnabled: !isInfoOpen,
                            bottomAlign: isInfoOpen,
                            onSingleTap: {
                                // Tap on the photo only toggles chrome when
                                // info is closed — when open, chrome is forced
                                // visible by the parent and tapping is a no-op.
                                guard !isInfoOpen else { return }
                                withAnimation { isChromeVisible.toggle() }
                            },
                            onZoomChange: { zoomed in
                                isZoomed = zoomed
                                if zoomed {
                                    stopLivePlayback()
                                }
                            }
                        )
                    } else {
                        ProgressView().tint(.white)
                    }

                    // Live photo video overlay
                    if isPlayingLive, let player = livePlayer {
                        AVPlayerLayerView(player: player)
                            .allowsHitTesting(false)
                    }
                }

                // File-provider materialisation overlay. Centered over
                // whatever the page is showing (thumbnail or empty), so
                // users see "Downloading…" while bytes arrive.
                if isMaterializing {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Downloading…")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                } else if let err = materializeError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button("Retry") {
                            Task { await loadPhoto() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 280)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Live-photo press-and-hold. The `pressing` callback fires
            // *immediately* on touch start (before `minimumDuration`), so
            // anything heavyweight (start playback, hide chrome) MUST live in
            // `perform` — the recognised long-press — or every quick tap on a
            // live photo races the chrome toggle: pressing(true) hides
            // chrome, then ZoomableImageView's delayed singleTap toggles it
            // back. `pressing(false)` only stops playback, never starts it.
            .onLongPressGesture(
                minimumDuration: 0.3,
                maximumDistance: 50,
                perform: {
                    guard let liveURL = photo.livePhotoVideoURL, !isZoomed, !isInfoOpen else { return }
                    let player = AVPlayer(url: liveURL)
                    livePlayer = player
                    player.play()
                    withAnimation(.easeIn(duration: 0.15)) { isPlayingLive = true }
                    isChromeVisible = false
                },
                onPressingChanged: { pressing in
                    if !pressing { stopLivePlayback() }
                }
            )
        }
        .task(id: photo.id) {
            await loadPhoto()
        }
    }

    private func loadPhoto() async {
        thumbnail = store.cachedThumbnail(for: photo.url)
        fullImage = nil
        isPlayingVideo = false
        videoPlayer?.pause()
        videoPlayer = nil
        isPlayingLive = false
        livePlayer?.pause()
        livePlayer = nil
        isZoomed = false
        materializeError = nil

        if thumbnail == nil {
            // Cloud-aware decode for the placeholder thumbnail. Cheap; the
            // QL path inside ThumbnailService activates only when needed.
            let probe = FileProviderDetector.probe(photo.url)
            let useQL = probe.isFileProvider && probe.status != .local
            thumbnail = await store.thumbnail(
                for: photo.url,
                size: CGSize(width: 400, height: 400),
                isVideo: photo.isVideo,
                useQuickLook: useQL
            )
        }

        // Pull bytes down for file-provider placeholders before attempting
        // the full-resolution decode. Local photos short-circuit immediately.
        if photo.locality != .local {
            isMaterializing = true
            do {
                _ = try await store.ensureMaterialized(photo)
                isMaterializing = false
            } catch {
                isMaterializing = false
                materializeError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return
            }
        }

        if !photo.isVideo {
            fullImage = await store.loadFullImage(for: photo.url)
        }
    }

    private func stopLivePlayback() {
        guard isPlayingLive || livePlayer != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { isPlayingLive = false }
        livePlayer?.pause()
        livePlayer = nil
    }
}
