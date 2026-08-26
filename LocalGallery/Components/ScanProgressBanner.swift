import SwiftUI

/// Compact, single-line scan-progress chip for the `.principal` toolbar slot
/// of the three main tabs (All Photos, Collections, Folders). Renders nothing
/// when neither a library scan nor a photo analysis run is in flight.
///
/// Same chip as Settings; the only tab-specific bit is the leading phase
/// word (Scanning / Tagging / Faces / Places).
struct ScanProgressBanner: View {
    @Environment(GalleryStore.self) private var store

    var body: some View {
        if let progress = store.scanProgress {
            ScanProgressChip(phase: progress.shortLabel, detail: progress.countText)
                .foregroundStyle(Design.ink)
        } else if let progress = store.analysis.progress {
            ScanProgressChip(phase: progress.shortLabel, detail: progress.countText)
                .foregroundStyle(Design.ink)
        }
    }
}
