import SwiftUI

/// Full-bleed memory slideshow: crossfade between photos, single continuous
/// progress bar, tap-left/tap-right to navigate (with timer reset), tap-and-hold
/// to pause, "thematic music" indicator, and "See all" → grid view.
struct MemorySlideshowView: View {
    let memory: Memory
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss

    private let slideDuration: Double = 3.8
    private let pauseHoldDelay: Double = 0.2

    @State private var index: Int = 0
    @State private var progress: Double = 0
    @State private var isPaused: Bool = false
    @State private var slideStart: Date = Date()
    @State private var timer: Timer?
    @State private var goToGrid: Bool = false

    private var photos: [PhotoFile] { manager.photos(for: memory) }

    var body: some View {
        ZStack {
            // Full-bleed photo stage — sits behind safe area
            GeometryReader { geo in
                ZStack {
                    Color.black

                    if !photos.isEmpty {
                        let prev = photos[(index - 1 + photos.count) % photos.count]
                        let cur  = photos[index]

                        // Previous (underneath) + current (fades in) for crossfade
                        SlideshowImage(url: prev.url, size: geo.size)
                        SlideshowImage(url: cur.url, size: geo.size)
                            .id(cur.id)
                            .transition(.opacity)
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
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
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

            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 0.561, green: 0.769, blue: 0.608))
                    .frame(width: 6, height: 6)
                Text("Playing · thematic")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.14), in: Capsule())

            Spacer()

            Button {
                goToGrid = true
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

            if isPaused {
                Text("PAUSED · RELEASE TO RESUME")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
            }
        }
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
        index = (index - 1 + photos.count) % photos.count
        resetSlide()
    }

    private func goNext() {
        guard !photos.isEmpty else { return }
        index = (index + 1) % photos.count
        resetSlide()
    }

    private func resetSlide() {
        progress = 0
        slideStart = Date()
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
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
                    index = (index + 1) % photos.count
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

private struct SlideshowImage: View {
    let url: URL
    let size: CGSize
    @EnvironmentObject var manager: GalleryManager
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .brightness(-0.08)
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
}
