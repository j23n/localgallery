import Foundation

/// Debounces calls to `WidgetSnapshotExporter.shared.export(_:)`. A single
/// scan often fires three times in quick succession (post-scan +
/// post-tag-aggregation + post-memory-regen) — coalescing those into one
/// export means the exporter sees the freshest snapshot exactly once.
///
/// `@MainActor` because the Store calls `schedule(_:)` synchronously from
/// MainActor contexts; the underlying export runs on a detached task.
@MainActor
final class WidgetExportScheduler {
    /// In-flight detached export. Successive `schedule` calls within the
    /// coalesce window cancel this so only the newest inputs run.
    private var pending: Task<Void, Never>?

    /// 200ms coalesce window — enough to absorb the typical post-scan
    /// flurry without delaying the widget visibly.
    private let coalesceNanoseconds: UInt64 = 200_000_000

    func schedule(_ inputs: WidgetSnapshotExporter.Inputs) {
        pending?.cancel()
        let nanoseconds = coalesceNanoseconds
        pending = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await WidgetSnapshotExporter.shared.export(inputs)
        }
    }
}
