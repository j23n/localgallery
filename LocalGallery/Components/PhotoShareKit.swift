import SwiftUI

/// A request to share photos at a specific quality. Each request gets a fresh
/// `id` so the `.photoShareSheet` modifier's `task(id:)` re-fires on every new
/// invocation, even at the same quality.
struct PhotoShareRequest: Identifiable {
    let id = UUID()
    let photos: [PhotoFile]
    let quality: PhotoQuality
}

/// Reusable share menu that lists the four `PhotoQuality` tiers with icons.
/// Resized tiers are disabled when `canResize` is false (e.g. videos).
/// Use as the root of a share button or as a nested submenu inside a parent
/// `Menu` / `contextMenu`.
struct PhotoShareMenu<MenuLabel: View>: View {
    let canResize: Bool
    let onSelect: (PhotoQuality) -> Void
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            ForEach(PhotoQuality.allCases) { quality in
                Button {
                    onSelect(quality)
                } label: {
                    Label(quality.menuTitle, systemImage: quality.iconName)
                }
                .disabled(quality != .original && !canResize)
            }
        } label: {
            label()
        }
    }
}

extension View {
    /// Drives the export → spinner → share-sheet flow. Set `request` non-nil
    /// to kick off; the modifier shows a blocking progress overlay (count for
    /// multi-photo batches), then presents the system share sheet.
    func photoShareSheet(request: Binding<PhotoShareRequest?>) -> some View {
        modifier(PhotoShareController(request: request))
    }
}

private struct PhotoShareController: ViewModifier {
    @Binding var request: PhotoShareRequest?
    @State private var preparing: Bool = false
    @State private var progressDone: Int = 0
    @State private var progressTotal: Int = 0
    @State private var pending: ShareBag?

    func body(content: Content) -> some View {
        content
            .overlay {
                if preparing {
                    PreparingOverlay(done: progressDone, total: progressTotal)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: preparing)
            .sheet(item: $pending) { bag in
                ShareSheet(items: bag.urls)
            }
            .task(id: request?.id) {
                guard let req = request else { return }
                await runExport(req)
            }
    }

    private func runExport(_ req: PhotoShareRequest) async {
        progressDone = 0
        progressTotal = req.photos.count
        // Spinner only appears if export takes meaningful time. `.original`
        // and small batches return near-instantly.
        let spinnerTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { preparing = true }
        }
        defer {
            spinnerTask.cancel()
            preparing = false
        }

        var urls: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            for photo in req.photos {
                group.addTask {
                    do {
                        return try await PhotoExporter.export(photo, quality: req.quality)
                    } catch {
                        Log.ui.error("Photo export failed: \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            for await result in group {
                if let url = result { urls.append(url) }
                progressDone += 1
            }
        }
        guard !Task.isCancelled, !urls.isEmpty else { return }
        pending = ShareBag(urls: urls)
    }
}

/// Identifiable wrapper for `.sheet(item:)` over an array of URLs.
struct ShareBag: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct PreparingOverlay: View {
    let done: Int
    let total: Int

    var body: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                    if total > 1 {
                        Text("\(done) / \(total)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .monospacedDigit()
                    }
                }
            }
    }
}
