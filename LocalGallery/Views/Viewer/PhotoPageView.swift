import SwiftUI
import UIKit
import AVFoundation
import AVKit

// MARK: - Photo Page

struct PhotoPageView: View {
    let photo: PhotoFile
    var initialThumbnail: UIImage? = nil
    @Environment(GalleryStore.self) private var store
    @Binding var isChromeVisible: Bool
    @Binding var isInfoOpen: Bool

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var videoPlayer: AVPlayer?
    @State private var isPlayingVideo = false
    @State private var isPlayingLive = false
    @State private var livePlayer: AVPlayer?
    @State private var isZoomed = false
    @State private var isMaterializing = false
    @State private var materializeError: String?

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
                            isZoomEnabled: !isInfoOpen,
                            bottomAlign: isInfoOpen,
                            onSingleTap: {
                                // Tap on the photo only toggles chrome when
                                // info is closed — when open, chrome is forced
                                // visible by the parent and tapping is a no-op.
                                guard !isInfoOpen else { return }
                                withAnimation { isChromeVisible.toggle() }
                            },
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

                // File-provider materialisation overlay. Centered over
                // whatever the page is showing (thumbnail or empty), so
                // users see "Downloading…" while bytes arrive.
                if isMaterializing {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Downloading…")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                } else if let err = materializeError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button("Retry") {
                            Task { await loadPhoto() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 280)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Live-photo press-and-hold. The `pressing` callback fires
            // *immediately* on touch start (before `minimumDuration`), so
            // anything heavyweight (start playback, hide chrome) MUST live in
            // `perform` — the recognised long-press — or every quick tap on a
            // live photo races the chrome toggle: pressing(true) hides
            // chrome, then ZoomableImageView's delayed singleTap toggles it
            // back. `pressing(false)` only stops playback, never starts it.
            .onLongPressGesture(
                minimumDuration: 0.3,
                maximumDistance: 50,
                perform: {
                    guard let liveURL = photo.livePhotoVideoURL, !isZoomed, !isInfoOpen else { return }
                    let player = AVPlayer(url: liveURL)
                    livePlayer = player
                    player.play()
                    withAnimation(.easeIn(duration: 0.15)) { isPlayingLive = true }
                    isChromeVisible = false
                },
                onPressingChanged: { pressing in
                    if !pressing { stopLivePlayback() }
                }
            )
        }
        .task(id: photo.id) {
            await loadPhoto()
        }
        .onDisappear {
            // UIPageViewController retains neighbour pages, so without this
            // a playing video keeps its audio going after the user swipes to
            // the next photo.
            videoPlayer?.pause()
            isPlayingVideo = false
            stopLivePlayback()
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
        materializeError = nil

        if thumbnail == nil {
            // Cloud-aware decode for the placeholder thumbnail. Cheap; the
            // QL path inside ThumbnailService activates only when needed.
            let probe = FileProviderDetector.probe(photo.url)
            let useQL = probe.isFileProvider && probe.status != .local
            thumbnail = await store.thumbnail(
                for: photo.url,
                size: CGSize(width: 400, height: 400),
                isVideo: photo.isVideo,
                useQuickLook: useQL
            )
        }

        // Pull bytes down for file-provider placeholders before attempting
        // the full-resolution decode. Local photos short-circuit immediately.
        if photo.locality != .local {
            isMaterializing = true
            do {
                _ = try await store.ensureMaterialized(photo)
                isMaterializing = false
            } catch {
                isMaterializing = false
                materializeError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return
            }
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

