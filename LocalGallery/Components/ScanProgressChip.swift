import SwiftUI

/// The live scan / analysis readout: spinner, a short phase word, optional
/// count/ETA. Same chip in the tab titlebars and the Settings running rows;
/// Settings adds Cancel beside it.
///
/// Phase is a single word (`Scanning`, `Tagging`, `Faces`) so a long count
/// (`4,821 / 18,220 · ~8:40`) does not wrap a Settings cell. Count and Cancel
/// keep layout priority; the phase word shrinks first.
struct ScanProgressChip: View {
    let phase: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(phase)
                .lineLimit(1)
                .layoutPriority(0)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
        }
        .font(.caption.weight(.semibold))
    }
}
