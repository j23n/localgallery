import SwiftUI
import UIKit
import AVFoundation
import AVKit

// MARK: - Swipe-down dismiss (UIKit gesture — doesn't conflict with TabView paging)

struct SwipeToDismissGestureInstaller: UIViewRepresentable {
    @Binding var offset: CGFloat
    var onDismiss: () -> Void

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
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let pan = coordinator.panGesture, let host = coordinator.hostView {
            host.removeGestureRecognizer(pan)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset, onDismiss: onDismiss)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var offsetBinding: Binding<CGFloat>
        var onDismiss: () -> Void
        var panGesture: UIPanGestureRecognizer?
        weak var hostView: UIView?

        init(offset: Binding<CGFloat>, onDismiss: @escaping () -> Void) {
            self.offsetBinding = offset
            self.onDismiss = onDismiss
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let dy = gesture.translation(in: gesture.view).y
            switch gesture.state {
            case .changed:
                if dy > 0 {
                    offsetBinding.wrappedValue = dy
                }
            case .ended, .cancelled:
                if dy > 150 {
                    onDismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        offsetBinding.wrappedValue = 0
                    }
                }
            default:
                break
            }
        }

        // Only begin for clearly downward vertical pans
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return v.y > 0 && abs(v.y) > abs(v.x) * 2.0
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
        let curIdx = photos.firstIndex(where: { $0.id == current.photoID }) ?? 0
        let tarIdx = photos.firstIndex(where: { $0.id == currentPhotoID }) ?? 0
        let direction: UIPageViewController.NavigationDirection = tarIdx > curIdx ? .forward : .reverse
        let vc = context.coordinator.makeHostingController(for: currentPhotoID)
        pvc.setViewControllers([vc], direction: direction, animated: false)
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
        init(_ parent: PagingPhotoView) { self.parent = parent }

        func makeHostingController(for photoID: UUID) -> IndexedHostingController {
            // Caller guarantees `photoID` is in `parent.photos`; the firstIndex
            // lookup is the canonical resolution path post-rescan.
            let idx = parent.photos.firstIndex(where: { $0.id == photoID }) ?? 0
            let photo = parent.photos[idx]
            let view = PhotoPageView(
                photo: photo,
                initialThumbnail: parent.store.cachedThumbnail(for: photo.url),
                isChromeVisible: parent.$isChromeVisible
            )
            .environment(parent.store)
            return IndexedHostingController(photoID: photoID, rootView: AnyView(view))
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = parent.photos.firstIndex(where: { $0.id == indexed.photoID }),
                  curIdx > 0 else { return nil }
            return makeHostingController(for: parent.photos[curIdx - 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = parent.photos.firstIndex(where: { $0.id == indexed.photoID }),
                  curIdx < parent.photos.count - 1 else { return nil }
            return makeHostingController(for: parent.photos[curIdx + 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let indexed = pvc.viewControllers?.first as? IndexedHostingController {
                parent.currentPhotoID = indexed.photoID
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
    @State private var showEXIF: Bool = false
    @State private var dismissOffset: CGFloat = 0
    @State private var pendingShareItem: ShareItem?
    @State private var isPreparingShare: Bool = false

    /// Index of `currentPhotoID` within `photos`, or nil if the id isn't
    /// present (rescan removed the photo, or the array is empty).
    private var currentIndex: Int? {
        photos.firstIndex(where: { $0.id == currentPhotoID })
    }

    private var currentPhoto: PhotoFile? {
        guard let idx = currentIndex else { return nil }
        return photos[idx]
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(dismissOffset > 0 ? max(0.3, 1.0 - Double(dismissOffset) / 300.0) : 1.0)
                .ignoresSafeArea()

            if !photos.isEmpty {
                PagingPhotoView(
                    photos: photos,
                    store: store,
                    currentPhotoID: $currentPhotoID,
                    isChromeVisible: $isChromeVisible
                )
                .ignoresSafeArea()
                .offset(y: dismissOffset)
            }

            // Filmstrip is always visible — taps on the photo only toggle
            // the other chrome (top pill + share + info).
            VStack {
                Spacer()
                filmstrip
                    .padding(.bottom, isChromeVisible ? 64 : 12)
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
            .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
            .offset(y: dismissOffset)

            if isChromeVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomActionBar
                }
                .background(
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.black.opacity(0.55), .black.opacity(0.15), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                )
                .transition(.opacity)
                .offset(y: dismissOffset)
            }

            if isPreparingShare {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
        .animation(.easeOut(duration: 0.15), value: isPreparingShare)
        .statusBarHidden(!isChromeVisible)
        .background(
            SwipeToDismissGestureInstaller(
                offset: $dismissOffset,
                onDismiss: { dismiss() }
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: photos) { _, newPhotos in
            // Rescan dropped the photo we were viewing; dismiss instead of
            // silently landing on a different image at a stale index.
            if !newPhotos.contains(where: { $0.id == currentPhotoID }) {
                dismiss()
            }
        }
        .sheet(item: $pendingShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showEXIF) {
            if let photo = currentPhoto {
                EXIFSheetView(photo: photo)
            }
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
            }

            Spacer()

            if let photo = currentPhoto, let lines = PhotoChrome.pillLines(for: photo) {
                VStack(spacing: 1) {
                    if let date = lines.date {
                        Text(date)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if let location = lines.location {
                        Text(location)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.14), in: Capsule())
            }

            Spacer()

            Color.clear.frame(width: 36, height: 36)
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
        Menu {
            Button("Original") { share(quality: .original) }
            Button("High (4096px)") { share(quality: .high) }
                .disabled(currentPhoto?.isVideo ?? false)
            Button("Medium (2048px)") { share(quality: .medium) }
                .disabled(currentPhoto?.isVideo ?? false)
            Button("Small (1024px)") { share(quality: .small) }
                .disabled(currentPhoto?.isVideo ?? false)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private var infoButton: some View {
        Button { showEXIF = true } label: {
            Label("Info", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.18), in: Capsule())
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
                            ThumbnailView(url: photo.url, size: 56, cornerRadius: 6)
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

    // MARK: Share

    private func share(quality: PhotoQuality) {
        guard let photo = currentPhoto else { return }
        // Show spinner only if the export takes meaningful time. `.original`
        // and small images return near-instantly.
        let spinnerTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled { isPreparingShare = true }
        }
        Task {
            defer {
                spinnerTask.cancel()
                isPreparingShare = false
            }
            do {
                let url = try await PhotoExporter.export(photo, quality: quality)
                pendingShareItem = ShareItem(url: url)
            } catch {
                Log.ui.error("Photo export failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Identifiable wrapper for sheet(item:) on a URL

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
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
    private var lastLaidOutBounds: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView, imageView.image != nil else { return }
        // Only re-fit when bounds change AND the user hasn't zoomed in —
        // otherwise a scroll/zoom gesture would fight with automatic fitting.
        if bounds.size != lastLaidOutBounds, zoomScale == minimumZoomScale {
            lastLaidOutBounds = bounds.size
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
        let yOffset = max(0, (b.height - size.height) / 2)
        imageView.center = CGPoint(x: size.width / 2 + xOffset, y: size.height / 2 + yOffset)
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    var onZoomChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

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

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var videoPlayer: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isPlayingLive = false
    @State private var livePlayer: AVPlayer?
    @State private var isZoomed = false

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
                            onSingleTap: { withAnimation { isChromeVisible.toggle() } },
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
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
                guard let liveURL = photo.livePhotoVideoURL else { return }
                // Suppress live playback while the still is zoomed in —
                // otherwise a hold to pan the zoomed image would superimpose
                // a fitted-frame video on top of the zoomed content.
                if pressing && isZoomed { return }
                if pressing {
                    let player = AVPlayer(url: liveURL)
                    livePlayer = player
                    player.play()
                    withAnimation(.easeIn(duration: 0.15)) { isPlayingLive = true }
                    isChromeVisible = false
                } else {
                    stopLivePlayback()
                }
            }, perform: {})
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

        if thumbnail == nil {
            thumbnail = await store.thumbnail(for: photo.url, size: CGSize(width: 400, height: 400), isVideo: photo.isVideo)
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
