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

    @Environment(GalleryManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    private let baseSlideDuration: Double = 5.0
    private let slideJitter: Double = 0.6 // ± seconds, picked per slide
    private let pauseHoldDelay: Double = 0.2

    @State private var index: Int = 0
    @State private var progress: Double = 0
    @State private var isPaused: Bool = false
    @State private var slideStart: Date = Date()
    @State private var timer: Timer?
    @State private var goToGrid: Bool = false
    @State private var slideDuration: Double = 5.0
    @State private var showThemePicker: Bool = false
    @State private var audio = SlideshowAudioController()
    @AppStorage("slideshowMusicTheme") private var storedTheme: String = SlideshowMusicTheme.wistful.rawValue

    private var photos: [PhotoFile] { manager.photos(for: memory) }
    private var theme: SlideshowMusicTheme {
        SlideshowMusicTheme(rawValue: storedTheme) ?? .wistful
    }

    var body: some View {
        ZStack {
            // Full-bleed photo stage — sits behind safe area
            GeometryReader { geo in
                ZStack {
                    Color.black

                    if !photos.isEmpty {
                        let prev = photos[(index - 1 + photos.count) % photos.count]
                        let cur  = photos[index]

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

            // Tap zones: left-third = prev, right-third = next, anywhere = hold-to-pause.
            // Full-bleed so gestures reach the screen edges.
            HStack(spacing: 0) {
                tapZone { goPrev() }
                tapZone { /* middle: no-op, still holdable */ }
                tapZone { goNext() }
            }
            .ignoresSafeArea()

            // Chrome stays inside safe area so the x / "See all" clear the
            // dynamic island and the caption clears the home indicator.
            VStack {
                topBar
                Spacer()
                bottomChrome
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $goToGrid) {
            MemoryGridView(memory: memory)
        }
        .sheet(isPresented: $showThemePicker) {
            MusicThemePicker(selected: Binding(
                get: { theme },
                set: { storedTheme = $0.rawValue; audio.play(theme: $0) }
            ))
            .presentationDetents([.medium])
        }
        .onAppear {
            OrientationLock.lock(.portrait, rotateTo: .portrait)
            audio.play(theme: theme)
            startTimer()
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
                isPaused = true
            } onPressingChanged: { pressing in
                if !pressing { isPaused = false }
            }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.16), in: Circle())
            }

            Spacer()

            Button {
                showThemePicker = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.561, green: 0.769, blue: 0.608))
                        .frame(width: 6, height: 6)
                    Text("Playing · \(theme.displayName.lowercased())")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                if let onSeeAll {
                    onSeeAll(memory)
                } else {
                    goToGrid = true
                }
            } label: {
                Text("See all")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        )
    }

    private var bottomChrome: some View {
        let total = max(photos.count, 1)
        let overall = (Double(index) + min(progress, 1)) / Double(total)

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

            GeometryReader { pg in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white)
                        .frame(width: max(0, pg.size.width * CGFloat(overall)))
                }
            }
            .frame(height: 3)
        }
        .animation(.easeInOut(duration: 0.18), value: isPaused)
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Navigation

    private func goPrev() {
        guard !photos.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.55)) {
            index = (index - 1 + photos.count) % photos.count
        }
        resetSlide()
    }

    private func goNext() {
        guard !photos.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.55)) {
            index = (index + 1) % photos.count
        }
        resetSlide()
    }

    private func resetSlide() {
        progress = 0
        slideDuration = nextDuration()
        slideStart = Date()
    }

    private func nextDuration() -> Double {
        let jitter = Double.random(in: -slideJitter...slideJitter)
        return max(2.5, baseSlideDuration + jitter)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        slideDuration = nextDuration()
        slideStart = Date().addingTimeInterval(-progress * slideDuration)
        let t = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            Task { @MainActor in
                guard !isPaused, !photos.isEmpty else {
                    if isPaused { slideStart = Date().addingTimeInterval(-progress * slideDuration) }
                    return
                }
                let p = min(1.0, Date().timeIntervalSince(slideStart) / slideDuration)
                progress = p
                if p >= 1 {
                    progress = 0
                    withAnimation(.easeInOut(duration: 0.55)) {
                        index = (index + 1) % photos.count
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
    @Environment(GalleryManager.self) private var manager
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                renderedImage(image)
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: url) {
            image = await manager.loadFullImage(for: url)
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

// MARK: - Music theme picker

private struct MusicThemePicker: View {
    @Binding var selected: SlideshowMusicTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SlideshowMusicTheme.allCases) { theme in
                        Button {
                            selected = theme
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.displayName)
                                        .font(.system(size: 15.5, weight: .medium))
                                        .foregroundStyle(Design.ink)
                                    Text(theme.blurb)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Design.ink3)
                                }
                                Spacer()
                                if theme == selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Design.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Thematic music")
                } footer: {
                    Text("Played softly behind the slideshow. Your choice is remembered for next time.")
                }
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Audio controller wrapper

/// `@Observable` wrapper so the SwiftUI view owns the player's lifetime via
/// `@State`. The player itself is a plain main-actor class.
@Observable
@MainActor
final class SlideshowAudioController {
    private let player = SlideshowMusicPlayer()

    func play(theme: SlideshowMusicTheme) {
        player.play(theme: theme)
    }

    func stop() {
        player.stop()
    }
}
