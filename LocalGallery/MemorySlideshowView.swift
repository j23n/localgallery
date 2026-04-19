import SwiftUI

/// Full-bleed memory slideshow: crossfade between photos, segmented progress bar,
/// tap-and-hold to pause, "thematic music" indicator, and "See all" → grid view.
struct MemorySlideshowView: View {
    let memory: Memory
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss

    private let slideDuration: Double = 3.8

    @State private var index: Int = 0
    @State private var progress: Double = 0
    @State private var isPaused: Bool = false
    @State private var slideStart: Date = Date()
    @State private var timer: Timer?
    @State private var goToGrid: Bool = false

    private var photos: [PhotoFile] { manager.photos(for: memory) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if !photos.isEmpty {
                    let prev = photos[(index - 1 + photos.count) % photos.count]
                    let cur  = photos[index]

                    // Previous (underneath) + current (fades in) for crossfade
                    SlideshowImage(url: prev.url, geo: geo)
                    SlideshowImage(url: cur.url, geo: geo)
                        .id(cur.id)
                        .transition(.opacity)
                }

                // Tap-and-hold pause surface
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.001)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { _ in isPaused = true }
                            .onEnded { _ in isPaused = false }
                    )

                VStack {
                    topBar
                    Spacer()
                    bottomChrome
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .statusBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $goToGrid) {
            MemoryGridView(memory: memory)
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
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
                .allowsHitTesting(false)
        )
    }

    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            HStack(spacing: 3) {
                ForEach(photos.indices, id: \.self) { i in
                    let fill: Double = i < index ? 1 : (i == index ? progress : 0)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.22))
                            Capsule().fill(Color.white)
                                .frame(width: max(0, geo.size.width * CGFloat(fill)))
                        }
                    }
                    .frame(height: 2.5)
                }
            }

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
        .padding(.bottom, 30)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
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
    let geo: GeometryProxy
    @EnvironmentObject var manager: GalleryManager
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        .brightness(-0.08)
        .task(id: url) {
            let size = CGSize(width: geo.size.width * UIScreen.main.scale,
                              height: geo.size.height * UIScreen.main.scale)
            image = await manager.thumbnail(for: url, size: size)
        }
    }
}
