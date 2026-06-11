import SwiftUI
import UIKit

/// Full-bleed memory slideshow: crossfade between photos, single continuous
/// progress bar, tap-left/tap-right to navigate (with timer reset), tap-and-hold
/// to pause, "thematic music" indicator that opens a theme picker, and
/// "See all" → grid view.
///
/// Locked to portrait while presented (regardless of device rotation) so the
/// chrome layout stays consistent. Each photo is fit (not cropped) on a
/// soft blurred copy of itself, so landscapes letterbox onto their own
/// extended frame instead of getting panned across the canvas.
struct MemorySlideshowView: View {
    let memory: Memory
    /// Called when the user taps "See all". When non-nil, the view defers
    /// navigation to the parent (so the parent can replace the slideshow in
    /// the nav stack with the grid). When nil, falls back to pushing the
    /// grid as a child of this view.
    var onSeeAll: ((Memory) -> Void)? = nil

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let baseSlideDuration: Double = 5.0
    private let slideJitter: Double = 0.6 // ± seconds, picked per slide
    private let pauseHoldDelay: Double = 0.2

    @State private var index: Int = 0
    @State private var underlayIndex: Int = 0
    /// When this slide started, in absolute time. The progress bar reads this
    /// inside a `TimelineView` to compute its fill position from the current
    /// time directly — no per-frame @State writes, so the parent body doesn't
    /// re-evaluate 25× per second (which previously thrashed the menu's
    /// gesture state and made the ellipsis tap unreliable).
    @State private var slideStart: Date = Date()
    /// Non-nil while the user is holding a tap zone. We freeze the progress
    /// bar to this timestamp and shift `slideStart` forward by the elapsed
    /// pause duration on release — one @State write per pause edge instead
    /// of 25 per second.
    @State private var pausedSince: Date? = nil
    @State private var timer: Timer?
    @State private var goToGrid: Bool = false
    @State private var slideDuration: Double = 5.0
    @State private var shareRequest: PhotoShareRequest?
    @State private var audio = SlideshowAudioController()
    @AppStorage("slideshowMusicTheme") private var storedTheme: String = SlideshowMusicTheme.wistful.rawValue

    private var photos: [PhotoFile] { store.photos(for: memory) }
    private var theme: SlideshowMusicTheme {
        SlideshowMusicTheme(rawValue: storedTheme) ?? .wistful
    }
    private var currentPhoto: PhotoFile? {
        guard photos.indices.contains(index) else { return nil }
        return photos[index]
    }

    var body: some View {
        ZStack {
            // Full-bleed photo stage — sits behind safe area
            GeometryReader { geo in
                ZStack {
                    Color.black

                    if !photos.isEmpty {
                        // `photos` is recomputed from the store on every body
                        // evaluation; a rescan/sidecar sync can shrink it while
                        // the slideshow is open, so the @State indices must be
                        // bounds-protected at the read site (onChange fires
                        // only after the body that observes the shrink).
                        let prev = photos[underlayIndex % photos.count]
                        let cur  = photos[min(index, photos.count - 1)]

                        // Underneath = prev (held centered) so we always have
                        // something showing during the cross-fade. The current
                        // photo fades in via .opacity transition keyed on id.
                        SlideshowImage(url: prev.url, size: geo.size)
                        SlideshowImage(url: cur.url, size: geo.size)
                            .id(cur.id)
                            .transition(.opacity.animation(.easeInOut(duration: 0.55)))
                    }
                }
            }
            .ignoresSafeArea()

            // Chrome bookends the screen, with the prev/middle/next tap zones
            // occupying the photo region between them. Laying them out as
            // siblings (not overlapping) is critical: when the tap zones
            // extended under the chrome, the .onLongPressGesture(0.2) on the
            // tap zone fought the ellipsis Menu's internal press gesture, so
            // taps near the menu wouldn't open it reliably.
            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    tapZone { goPrev() }
                    tapZone { /* middle: no-op, still holdable */ }
                    tapZone { goNext() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomChrome
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $goToGrid) {
            MemoryGridView(memory: memory)
        }
        .photoShareSheet(request: $shareRequest)
        .onAppear {
            OrientationLock.lock(.portrait, rotateTo: .portrait)
            startTimer()
            store.memories.markSeen(memory.id)
        }
        .task {
            // Off the first-frame path: the synth + engine startup can stall
            // main for several hundred ms when the theme's PCM cache is
            // missing (cold install, or NSCachesDirectory got purged).
            await audio.play(theme: theme)
        }
        .onDisappear {
            OrientationLock.lock(.all)
            audio.stop()
            stopTimer()
        }
    }

    // MARK: - Tap + hold zone

    @ViewBuilder
    private func tapZone(onTap: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { onTap() }
            .onLongPressGesture(
                minimumDuration: pauseHoldDelay,
                maximumDistance: 50
            ) {
                pausedSince = Date()
            } onPressingChanged: { pressing in
                if !pressing, let p = pausedSince {
                    // Resume: shift the slide's start forward by however long
                    // we were paused, so elapsed time picks up where it left off.
                    slideStart = slideStart.addingTimeInterval(Date().timeIntervalSince(p))
                    pausedSince = nil
                }
            }
    }

    // MARK: - Chrome

    private var topBar: some View {
        ZStack {
            // Centred pill — anchored to screen mid regardless of corner buttons.
            if let lines = currentPhoto.flatMap(PhotoChrome.pillLines(for:)) {
                ChromePill(date: lines.date, location: lines.location)
            }

            HStack {
                ViewerDismissButton { dismiss() }

                Spacer()

                Menu {
                    Button {
                        if let onSeeAll {
                            onSeeAll(memory)
                        } else {
                            goToGrid = true
                        }
                    } label: {
                        Label("See all photos", systemImage: "square.grid.2x2")
                    }
                    Menu {
                        Picker("Music", selection: Binding(
                            get: { theme },
                            set: { newTheme in
                                storedTheme = newTheme.rawValue
                                Task { await audio.play(theme: newTheme) }
                            }
                        )) {
                            ForEach(SlideshowMusicTheme.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                    } label: {
                        Label("Music: \(theme.displayName)", systemImage: "music.note")
                    }
                    PhotoShareMenu(
                        canResize: !(currentPhoto?.isVideo ?? false),
                        onSelect: { quality in
                            guard let photo = currentPhoto else { return }
                            shareRequest = PhotoShareRequest(photos: [photo], quality: quality)
                        }
                    ) {
                        Label("Share photo", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            // Hit-testing intentionally enabled so taps that miss the small
            // ellipsis / x hit targets are absorbed by the chrome instead of
            // falling through to the goNext / goPrev tap zones beneath.
            LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomChrome: some View {
        let total = max(photos.count, 1)
        let isPaused = (pausedSince != nil)

        return VStack(alignment: .leading, spacing: 6) {
            // Reserve a fixed slot above the title so the caption block doesn't
            // jump when the paused chip appears/disappears.
            ZStack(alignment: .leading) {
                Text(" ")
                    .font(.system(size: 11, weight: .medium))
                if isPaused {
                    Text("PAUSED · RELEASE TO RESUME")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.8))
                        .transition(.opacity)
                }
            }

            Text(memory.title)
                .font(Design.serifItalic(28, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)

            if let subtitle = memory.subtitle {
                Text("\(subtitle) · \(index + 1) of \(photos.count)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 8)
            }

            // TimelineView re-renders only its own content on each tick — the
            // parent body stays stable so the menu's gesture state survives.
            // Paused: timeline freezes; unpaused: animates at the display rate.
            TimelineView(.animation(minimumInterval: 0.04, paused: isPaused)) { ctx in
                let referenceDate = pausedSince ?? ctx.date
                let elapsed = max(0, referenceDate.timeIntervalSince(slideStart))
                let p = min(1.0, elapsed / slideDuration)
                let overall = (Double(index) + p) / Double(total)
                GeometryReader { pg in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white)
                            .frame(width: max(0, pg.size.width * CGFloat(overall)))
                    }
                }
            }
            .frame(height: 3)
        }
        .animation(.easeInOut(duration: 0.18), value: isPaused)
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .background(
            // Hit-testing intentionally enabled — same reason as the top bar:
            // absorb stray taps in the chrome area so they don't trigger nav.
            LinearGradient(colors: [.clear, Color.black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Navigation

    private func goPrev() {
        guard !photos.isEmpty else { return }
        underlayIndex = index
        withAnimation(.easeInOut(duration: 0.55)) {
            index = (index - 1 + photos.count) % photos.count
        }
        resetSlide()
    }

    private func goNext() {
        guard !photos.isEmpty else { return }
        underlayIndex = index
        withAnimation(.easeInOut(duration: 0.55)) {
            index = (index + 1) % photos.count
        }
        resetSlide()
    }

    private func resetSlide() {
        slideDuration = nextDuration()
        slideStart = Date()
        pausedSince = nil
    }

    private func nextDuration() -> Double {
        let jitter = Double.random(in: -slideJitter...slideJitter)
        return max(2.5, baseSlideDuration + jitter)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        slideDuration = nextDuration()
        slideStart = Date()
        // Low-frequency advancement check. The progress bar is driven by
        // TimelineView locally, so this timer is only responsible for moving
        // to the next slide when the current one's duration has elapsed.
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                guard pausedSince == nil, !photos.isEmpty else { return }
                if Date().timeIntervalSince(slideStart) >= slideDuration {
                    underlayIndex = index
                    let nextIndex = (index + 1) % photos.count
                    withAnimation(.easeInOut(duration: 0.55)) {
                        index = nextIndex
                    }
                    slideDuration = nextDuration()
                    slideStart = Date()
                }
            }
        }
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Slideshow image: fit foreground on a blurred extension of itself

private struct SlideshowImage: View {
    let url: URL
    let size: CGSize
    @Environment(GalleryStore.self) private var store
    @State private var image: UIImage?
    /// Sync hit on the in-memory thumbnail cache. Shown under the full-res
    /// image so the canvas isn't black during the 2000px decode — matters
    /// especially for the first slide, whose full image is never pre-decoded
    /// elsewhere (only the memory card's cover thumbnail is).
    @State private var placeholder: UIImage?

    var body: some View {
        ZStack {
            if let image {
                renderedImage(image)
            } else if let placeholder {
                renderedImage(placeholder)
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: url) {
            placeholder = store.cachedThumbnail(for: url)
            image = await store.loadFullImage(for: url)
        }
    }

    @ViewBuilder
    private func renderedImage(_ image: UIImage) -> some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .blur(radius: 60, opaque: true)
                .overlay(Color.black.opacity(0.35))

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .brightness(-0.08)
    }
}

// MARK: - Audio controller wrapper

/// `@Observable` wrapper so the SwiftUI view owns the player's lifetime via
/// `@State`. The player itself is a plain main-actor class.
@Observable
@MainActor
final class SlideshowAudioController {
    private let player = SlideshowMusicPlayer()

    func play(theme: SlideshowMusicTheme) async {
        await player.play(theme: theme)
    }

    func stop() {
        player.stop()
    }
}
