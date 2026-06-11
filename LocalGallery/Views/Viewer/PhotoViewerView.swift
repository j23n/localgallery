import SwiftUI
import UIKit

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
            // `onAppear` alone leaves the insets stale after a rotation —
            // chrome would keep the old orientation's padding and slide
            // under the status bar / home indicator.
            .onChange(of: geo.size) { _, _ in
                windowInsets = Self.currentWindowInsets()
            }
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
        // Pre-warm the neighbouring pages' bytes for file-provider photos so
        // a swipe doesn't land on a "Downloading…" overlay. `task(id:)` so
        // it fires on appear and again on every page change; gated inside on
        // the "Pre-fetch in Viewer" setting (and the cellular setting, via
        // the materializer).
        .task(id: currentPhotoID) {
            guard store.prefetchAdjacentRemotePhotos, let idx = currentIndex else { return }
            let neighbours = [idx - 1, idx + 1]
                .filter { photos.indices.contains($0) }
                .map { photos[$0] }
            store.prefetchMaterialize(neighbours)
        }
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
                ChromePill(date: lines.date, location: lines.location)
                    .opacity(isInfoOpen ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isInfoOpen)
            }

            HStack {
                ViewerDismissButton { dismiss() }
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

    /// Half-width of the filmstrip window. The strip materialises a slice of
    /// `photos` centred on `currentPhotoID` (2*window + 1 items) rather than
    /// the full array — at 20k photos, ForEach identity bookkeeping and
    /// `ScrollViewReader.scrollTo` over the entire LazyHStack add hundreds of
    /// milliseconds to viewer presentation.
    private static let filmstripWindow = 50

    private var filmstripPhotos: ArraySlice<PhotoFile> {
        guard !photos.isEmpty else { return photos.prefix(0) }
        let curIdx = currentIndex ?? 0
        let lower = max(0, curIdx - Self.filmstripWindow)
        let upper = min(photos.count, curIdx + Self.filmstripWindow + 1)
        return photos[lower..<upper]
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(filmstripPhotos) { photo in
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

