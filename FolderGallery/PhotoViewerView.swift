import SwiftUI

struct PhotoViewerView: View {
    let photos: [PhotoFile]
    let initialPhoto: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    @State private var isChromeVisible: Bool = true
    @State private var showEXIF: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var dragOffset: CGFloat = 0

    private var dismissProgress: CGFloat {
        min(abs(dragOffset) / 300, 1.0)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1.0 - dismissProgress * 0.5)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    ZoomablePhotoView(
                        photo: photo,
                        isChromeVisible: $isChromeVisible,
                        dragOffset: $dragOffset,
                        onSwipeUp: { showEXIF = true },
                        onDismiss: { dismiss() }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .ignoresSafeArea()

            if isChromeVisible && dragOffset == 0 {
                VStack {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
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
                        Color.clear
                            .frame(width: 40, height: 40)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    HStack(spacing: 32) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        Button {
                            showEXIF = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
        .statusBarHidden(!isChromeVisible)
        .onAppear {
            if let idx = photos.firstIndex(where: { $0.id == initialPhoto.id }) {
                currentIndex = idx
            }
        }
        .sheet(isPresented: $showEXIF) {
            if currentIndex < photos.count {
                EXIFPanelView(photo: photos[currentIndex])
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if currentIndex < photos.count {
                ShareSheet(items: [photos[currentIndex].url])
            }
        }
    }
}

// MARK: - Zoomable Photo

struct ZoomablePhotoView: View {
    let photo: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @Binding var isChromeVisible: Bool
    @Binding var dragOffset: CGFloat
    var onSwipeUp: () -> Void
    var onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragDirection: DragDirection = .none

    private enum DragDirection {
        case none, vertical, horizontal
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(scale > 1.0 ? offset : .zero)
                        .gesture(magnificationGesture)
                        .simultaneousGesture(dragGesture)
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                if scale > 1.0 {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                } else {
                                    scale = 3.0
                                    lastScale = 3.0
                                }
                            }
                        }
                        .onTapGesture(count: 1) {
                            withAnimation {
                                isChromeVisible.toggle()
                            }
                        }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: photo.id) {
            image = nil
            image = await manager.loadFullImage(for: photo.url)
        }
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { value in
                let newScale = lastScale * value
                scale = min(max(newScale, 1.0), 5.0)
                lastScale = scale
                if scale <= 1.0 {
                    withAnimation {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if scale > 1.0 {
                    // Pan while zoomed
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    // Determine drag direction on first significant movement
                    if dragDirection == .none {
                        if abs(value.translation.height) > abs(value.translation.width) {
                            dragDirection = .vertical
                        } else {
                            dragDirection = .horizontal
                        }
                    }
                    if dragDirection == .vertical {
                        dragOffset = value.translation.height
                    }
                }
            }
            .onEnded { value in
                if scale > 1.0 {
                    lastOffset = offset
                } else if dragDirection == .vertical {
                    let threshold: CGFloat = 100
                    let velocity = value.predictedEndTranslation.height - value.translation.height

                    if value.translation.height > threshold || velocity > 500 {
                        // Swipe down → dismiss
                        onDismiss()
                    } else if value.translation.height < -threshold || velocity < -500 {
                        // Swipe up → show EXIF
                        withAnimation(.easeOut(duration: 0.25)) { dragOffset = 0 }
                        onSwipeUp()
                    } else {
                        // Snap back
                        withAnimation(.easeOut(duration: 0.25)) { dragOffset = 0 }
                    }
                }
                dragDirection = .none
            }
    }
}
