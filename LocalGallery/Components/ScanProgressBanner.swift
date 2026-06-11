import SwiftUI

/// Compact, single-line scan-progress label intended for the `.principal`
/// toolbar slot of the three main tabs (AllPhotos via `PhotoGridScreen`,
/// Collections, Folders). Renders nothing when `GalleryStore.scanProgress`
/// is nil; otherwise:
///
///   - **Scanning** phase — "Scanning… X found" (we don't know the total).
///   - **Enriching** phase — "X / Y · ~M:SS" with monospaced digits so the
///     count doesn't dance as it ticks up.
///
/// Width-aware: `.lineLimit(1)` + `.minimumScaleFactor(0.7)` lets the label
/// shrink under narrow nav bars (iPhone portrait with trailing items) rather
/// than truncating with an ellipsis.
struct ScanProgressBanner: View {
    @Environment(GalleryStore.self) private var store

    var body: some View {
        if let progress = store.scanProgress {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(detail(for: progress))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Design.ink)
            }
        }
    }

    private func detail(for progress: ScanProgress) -> String {
        switch progress.phase {
        case .scanning:
            return "Scanning… \(progress.countText)"
        case .enriching:
            if progress.total == nil {
                return "Reading metadata… \(progress.countText)"
            }
            return progress.countText
        }
    }
}

extension ScanProgress {
    /// Shared count/ETA text: "X found" while scanning, "X / Y · ~M:SS"
    /// while enriching (ETA from observed throughput since `startedAt`).
    /// Used by the toolbar banner and the Settings progress row — callers
    /// add their own phase prefix.
    var countText: String {
        switch phase {
        case .scanning:
            return "\(processed.formatted()) found"
        case .enriching:
            guard let total, total > 0 else {
                return processed.formatted()
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            if processed > 0, elapsed > 1 {
                let throughput = Double(processed) / elapsed
                let remaining = max(0, total - processed)
                let secs = Int((Double(remaining) / max(throughput, 0.001)).rounded())
                if secs > 0 {
                    let m = secs / 60
                    let s = secs % 60
                    let eta = m > 0 ? String(format: "~%d:%02d", m, s) : "~\(s)s"
                    return "\(processed.formatted()) / \(total.formatted()) · \(eta)"
                }
            }
            return "\(processed.formatted()) / \(total.formatted())"
        }
    }
}
