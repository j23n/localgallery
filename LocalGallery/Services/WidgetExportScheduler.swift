import Foundation

/// Debounces calls to `WidgetSnapshotExporter.shared.export(_:)`. A single
/// scan often fires three times in quick succession (post-scan +
/// post-tag-aggregation + post-memory-regen) — coalescing those into one
/// export means the exporter sees the freshest snapshot exactly once.
///
/// `@MainActor` because the Store calls `schedule(_:)` synchronously from
/// MainActor contexts; the heavy work runs inside the exporter actor.
@MainActor
final class WidgetExportScheduler {
    /// In-flight export. Successive `schedule` calls within the coalesce
    /// window cancel this so only the newest inputs run; the reference is
    /// dropped on completion so the captured `Inputs` (which include the
    /// full photo array) don't outlive the export.
    private var pending: Task<Void, Never>?

    /// 200ms coalesce window — enough to absorb the typical post-scan
    /// flurry without delaying the widget visibly.
    private static let coalesceWindow: Duration = .milliseconds(200)

    func schedule(_ inputs: WidgetSnapshotExporter.Inputs) {
        pending?.cancel()
        // Plain Task, not detached: the only pre-export work is a sleep, and
        // the exporter is an actor — nothing here needs to leave the main
        // actor early.
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceWindow)
            guard !Task.isCancelled else { return }
            await WidgetSnapshotExporter.shared.export(inputs)
            self?.pending = nil
        }
    }
}
