import SwiftUI

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct PhotoViewerView: View {
    let photos: [PhotoFile]
    let initialPhoto: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    @State private var isChromeVisible: Bool = true
    @State private var showShareSheet: Bool = false
    @State private var backgroundOpacity: Double = 1.0

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    PhotoPageView(
                        photo: photo,
                        isChromeVisible: $isChromeVisible,
                        backgroundOpacity: $backgroundOpacity,
                        onDismiss: { dismiss() }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if isChromeVisible {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Spacer()
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    HStack {
                        Button { showShareSheet = true } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .statusBarHidden(!isChromeVisible)
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
    }
}

// MARK: - Photo Page (Image + scrollable EXIF)

struct PhotoPageView: View {
    let photo: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Binding var isChromeVisible: Bool
    @Binding var backgroundOpacity: Double
    var onDismiss: () -> Void

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var exifData: EXIFData?
    @State private var isLoadingEXIF = true
    @State private var exifAppeared = false
    @State private var isDismissing = false

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Scroll position tracker
                    GeometryReader { inner in
                        Color.clear
                            .preference(
                                key: ScrollOffsetKey.self,
                                value: inner.frame(in: .named("photoScroll")).minY
                            )
                    }
                    .frame(height: 0)

                    // Full-screen image area
                    ZStack {
                        if let displayImage = fullImage ?? thumbnail {
                            Image(uiImage: displayImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .scaleEffect(scale)
                                .offset(scale > 1.0 ? panOffset : .zero)
                                .gesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            scale = min(max(lastScale * value, 1.0), 5.0)
                                        }
                                        .onEnded { value in
                                            scale = min(max(lastScale * value, 1.0), 5.0)
                                            lastScale = scale
                                            if scale <= 1.0 {
                                                withAnimation {
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
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeInOut(duration: 0.3)) {
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
                                    withAnimation { isChromeVisible.toggle() }
                                }
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)

                    // Inline EXIF below the image — lazy: only loads when scrolled into view
                    EXIFContentView(
                        photo: photo,
                        exifData: exifData,
                        isLoading: isLoadingEXIF
                    )
                    .onAppear {
                        guard !exifAppeared else { return }
                        exifAppeared = true
                        Task {
                            exifData = await manager.loadEXIF(for: photo)
                            isLoadingEXIF = false
                        }
                    }
                }
            }
            .coordinateSpace(name: "photoScroll")
            .scrollDisabled(scale > 1.0)
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                // Pulling down past top → dim background and dismiss
                if value > 0 {
                    backgroundOpacity = max(0.3, 1.0 - Double(value) / 300.0)
                } else {
                    backgroundOpacity = 1.0
                }
                if value > 120 && !isDismissing {
                    isDismissing = true
                    onDismiss()
                }
            }
        }
        .task(id: photo.id) {
            fullImage = nil
            isDismissing = false
            exifData = nil
            isLoadingEXIF = true
            exifAppeared = false
            // Show cached thumbnail instantly, then load full res in background
            thumbnail = await manager.thumbnail(for: photo.url, size: CGSize(width: 400, height: 400))
            fullImage = await manager.loadFullImage(for: photo.url)
        }
    }
}
