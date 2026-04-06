import SwiftUI
import UIKit
import AVFoundation

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

// MARK: - Photo Viewer

struct PhotoViewerView: View {
    let photos: [PhotoFile]
    let initialPhoto: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    @State private var isChromeVisible: Bool = true
    @State private var showShareSheet: Bool = false
    @State private var showEXIF: Bool = false
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(dismissOffset > 0 ? max(0.3, 1.0 - Double(dismissOffset) / 300.0) : 1.0)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    PhotoPageView(
                        photo: photo,
                        isChromeVisible: $isChromeVisible
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
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
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
        .statusBarHidden(!isChromeVisible)
        .background(
            SwipeToDismissGestureInstaller(
                offset: $dismissOffset,
                onDismiss: { dismiss() }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if let idx = photos.firstIndex(where: { $0.id == initialPhoto.id }) {
                currentIndex = idx
            }
        }
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

// MARK: - Photo Page

struct PhotoPageView: View {
    let photo: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Binding var isChromeVisible: Bool

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var showVideoPlayer = false
    @State private var isPlayingLive = false
    @State private var livePlayer: AVPlayer?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if photo.isVideo {
                    // Video: show thumbnail with play button
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().tint(.white)
                    }

                    Button { showVideoPlayer = true } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                } else {
                    // Photo: zoomable image
                    if let displayImage = fullImage ?? thumbnail {
                        Image(uiImage: displayImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(scale > 1.0 ? panOffset : .zero)
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !photo.isVideo else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    if scale > 1.0 {
                        scale = 1.0
                        lastScale = 1.0
                        panOffset = .zero
                        lastPanOffset = .zero
                    } else {
                        scale = 3.0
                        lastScale = 3.0
                    }
                }
            }
            .onTapGesture(count: 1) {
                if photo.isVideo { return }
                withAnimation { isChromeVisible.toggle() }
            }
            .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
                guard let liveURL = photo.livePhotoVideoURL, scale <= 1.0 else { return }
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
            .simultaneousGesture(
                photo.isVideo ? nil :
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value, 1.0), 5.0)
                        if scale > 1.0 { isChromeVisible = false }
                    }
                    .onEnded { value in
                        scale = min(max(lastScale * value, 1.0), 5.0)
                        lastScale = scale
                        if scale <= 1.0 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                panOffset = .zero
                                lastPanOffset = .zero
                            }
                        }
                    }
            )
            .gesture(
                scale > 1.0 ?
                    DragGesture()
                        .onChanged { value in
                            panOffset = CGSize(
                                width: lastPanOffset.width + value.translation.width,
                                height: lastPanOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastPanOffset = panOffset
                        }
                    : nil
            )
        }
        .task(id: photo.id) {
            thumbnail = manager.cachedThumbnail(for: photo.url)
            fullImage = nil
            scale = 1.0
            lastScale = 1.0
            panOffset = .zero
            lastPanOffset = .zero
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
        .fullScreenCover(isPresented: $showVideoPlayer) {
            VideoPlayerView(url: photo.url)
        }
    }
}
