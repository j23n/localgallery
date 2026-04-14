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
    let manager: GalleryManager
    @Binding var currentIndex: Int
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
        let initial = context.coordinator.makeHostingController(for: currentIndex)
        pvc.setViewControllers([initial], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let current = pvc.viewControllers?.first as? IndexedHostingController,
              current.pageIndex != currentIndex else { return }
        let direction: UIPageViewController.NavigationDirection = currentIndex > current.pageIndex ? .forward : .reverse
        let vc = context.coordinator.makeHostingController(for: currentIndex)
        pvc.setViewControllers([vc], direction: direction, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class IndexedHostingController: UIHostingController<AnyView> {
        let pageIndex: Int
        init(pageIndex: Int, rootView: AnyView) {
            self.pageIndex = pageIndex
            super.init(rootView: rootView)
            view.backgroundColor = .clear
        }
        @MainActor required init?(coder: NSCoder) { fatalError() }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagingPhotoView
        init(_ parent: PagingPhotoView) { self.parent = parent }

        func makeHostingController(for index: Int) -> IndexedHostingController {
            let photo = parent.photos[index]
            let view = PhotoPageView(
                photo: photo,
                initialThumbnail: parent.manager.cachedThumbnail(for: photo.url),
                isChromeVisible: parent.$isChromeVisible
            )
            .environmentObject(parent.manager)
            return IndexedHostingController(pageIndex: index, rootView: AnyView(view))
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let indexed = vc as? IndexedHostingController, indexed.pageIndex > 0 else { return nil }
            return makeHostingController(for: indexed.pageIndex - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let indexed = vc as? IndexedHostingController, indexed.pageIndex < parent.photos.count - 1 else { return nil }
            return makeHostingController(for: indexed.pageIndex + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let indexed = pvc.viewControllers?.first as? IndexedHostingController {
                parent.currentIndex = indexed.pageIndex
            }
        }
    }
}

// MARK: - Photo Viewer

struct PhotoViewerView: View {
    let photos: [PhotoFile]
    let initialPhoto: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int

    init(photos: [PhotoFile], initialPhoto: PhotoFile) {
        self.photos = photos
        self.initialPhoto = initialPhoto
        _currentIndex = State(initialValue: photos.firstIndex(where: { $0.id == initialPhoto.id }) ?? 0)
    }
    @State private var isChromeVisible: Bool = true
    @State private var showShareSheet: Bool = false
    @State private var showEXIF: Bool = false
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(dismissOffset > 0 ? max(0.3, 1.0 - Double(dismissOffset) / 300.0) : 1.0)
                .ignoresSafeArea()

            PagingPhotoView(
                photos: photos,
                manager: manager,
                currentIndex: $currentIndex,
                isChromeVisible: $isChromeVisible
            )
            .ignoresSafeArea()
            .offset(y: dismissOffset)

            if isChromeVisible {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        Spacer()
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.12), in: Capsule())
                        Spacer()
                        Color.clear.frame(width: 36, height: 36)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    HStack {
                        Button { showShareSheet = true } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        Spacer()
                        Button { showEXIF = true } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
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
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.15), .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                )
                .transition(.opacity)
                .offset(y: dismissOffset)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
        .statusBarHidden(!isChromeVisible)
        .background(
            SwipeToDismissGestureInstaller(
                offset: $dismissOffset,
                onDismiss: { dismiss() }
            )
            .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $showShareSheet) {
            if currentIndex < photos.count {
                ShareSheet(items: [photos[currentIndex].url])
            }
        }
        .sheet(isPresented: $showEXIF) {
            if currentIndex < photos.count {
                EXIFSheetView(photo: photos[currentIndex])
            }
        }
    }
}

// MARK: - Zoomable Image (UIScrollView-based)

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
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

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }
        if imageView.image !== image {
            imageView.image = image
            scrollView.zoomScale = 1.0
            layoutImageView(imageView, in: scrollView)
        } else if imageView.frame.size == .zero {
            layoutImageView(imageView, in: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap)
    }

    private func layoutImageView(_ imageView: UIImageView, in scrollView: UIScrollView) {
        guard let image = imageView.image else { return }
        let bounds = scrollView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let imageSize = image.size
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        let fitScale = min(widthScale, heightScale)
        let fittedSize = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize
        centerImageView(imageView, in: scrollView)
    }

    func centerImageView(_ imageView: UIView, in scrollView: UIScrollView) {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let xOffset = max(0, (boundsSize.width - contentSize.width) / 2)
        let yOffset = max(0, (boundsSize.height - contentSize.height) / 2)
        imageView.center = CGPoint(
            x: contentSize.width / 2 + xOffset,
            y: contentSize.height / 2 + yOffset
        )
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
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
    @EnvironmentObject var manager: GalleryManager
    @Binding var isChromeVisible: Bool

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var videoPlayer: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isPlayingLive = false
    @State private var livePlayer: AVPlayer?

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
                        ZoomableImageView(image: displayImage) {
                            withAnimation { isChromeVisible.toggle() }
                        }
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
                if pressing {
                    let player = AVPlayer(url: liveURL)
                    livePlayer = player
                    player.play()
                    withAnimation(.easeIn(duration: 0.15)) { isPlayingLive = true }
                    isChromeVisible = false
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { isPlayingLive = false }
                    livePlayer?.pause()
                    livePlayer = nil
                }
            }, perform: {})
        }
        .task(id: photo.id) {
            await loadPhoto()
        }
    }

    private func loadPhoto() async {
        thumbnail = manager.cachedThumbnail(for: photo.url)
        fullImage = nil
        isPlayingVideo = false
        videoPlayer?.pause()
        videoPlayer = nil
        isPlayingLive = false
        livePlayer?.pause()
        livePlayer = nil

        if thumbnail == nil {
            thumbnail = await manager.thumbnail(for: photo.url, size: CGSize(width: 400, height: 400), isVideo: photo.isVideo)
        }
        if !photo.isVideo {
            fullImage = await manager.loadFullImage(for: photo.url)
        }
    }
}
