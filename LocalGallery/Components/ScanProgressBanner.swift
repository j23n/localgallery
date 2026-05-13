import SwiftUI

/// Top-of-view banner that reflects `GalleryStore.scanProgress`. Renders
/// nothing when no scan is running, so callers attach it unconditionally via
/// `.overlay(alignment: .top) { ScanProgressBanner() }` on a tab root.
///
/// Two phases:
///   - **Scanning** — folders being walked. We don't know the total yet, so
///     the line reads "Scanning… X photos found" with an indeterminate bar.
///   - **Enriching** — EXIF / XMP / video-date reads with a known up-front
///     total. Shows "Reading metadata · X / Y" plus an ETA derived from
///     elapsed time and throughput.
struct ScanProgressBanner: View {
    @Environment(GalleryStore.self) private var store

    var body: some View {
        if let progress = store.scanProgress {
            content(for: progress)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Design.separator, lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }

    @ViewBuilder
    private func content(for progress: ScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.ink)
                Spacer(minLength: 0)
                Text(detailText(for: progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Design.ink2)
            }
            progressBar(for: progress)
        }
    }

    private func detailText(for progress: ScanProgress) -> String {
        switch progress.phase {
        case .scanning:
            return "\(progress.processed.formatted()) found"
        case .enriching:
            if let total = progress.total, total > 0 {
                let etaText = etaString(for: progress)
                if let etaText {
                    return "\(progress.processed.formatted()) / \(total.formatted()) · \(etaText)"
                } else {
                    return "\(progress.processed.formatted()) / \(total.formatted())"
                }
            }
            return progress.processed.formatted()
        }
    }

    @ViewBuilder
    private func progressBar(for progress: ScanProgress) -> some View {
        switch progress.phase {
        case .scanning:
            ProgressView().progressViewStyle(.linear)
                .tint(Design.accentColor)
        case .enriching:
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.processed), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(Design.accentColor)
            } else {
                ProgressView().progressViewStyle(.linear)
                    .tint(Design.accentColor)
            }
        }
    }

    /// "~1:42 remaining" style. Returns nil during the first second or before
    /// any work is done, since the throughput estimate is too noisy to show.
    private func etaString(for progress: ScanProgress) -> String? {
        guard let total = progress.total, total > 0, progress.processed > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(progress.startedAt)
        guard elapsed > 1 else { return nil }
        let throughput = Double(progress.processed) / elapsed
        guard throughput > 0 else { return nil }
        let remaining = max(0, total - progress.processed)
        let secondsRemaining = Int((Double(remaining) / throughput).rounded())
        if secondsRemaining < 1 { return nil }
        let minutes = secondsRemaining / 60
        let seconds = secondsRemaining % 60
        if minutes > 0 {
            return String(format: "~%d:%02d remaining", minutes, seconds)
        }
        return "~\(seconds)s remaining"
    }
}
