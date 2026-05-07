import Foundation
import MetricKit

/// Master switch for crash capture and the read-side of the crash banner.
///
/// Subscribes to `MXMetricManager` only when the user opts in via the
/// "Crash Reporting" toggle in Settings; off by default. When enabled,
/// MetricKit hands us an `MXDiagnosticPayload` on the next launch after a
/// crash and we persist its `jsonRepresentation()` to
/// `<AppSupport>/crashes/last-crash.json`. `LogPersistence` writes a tail of
/// the in-memory `LogStore` to `<AppSupport>/logs/recent.txt` so the user can
/// share both alongside the crash JSON.
///
/// Toggling the master switch off removes the subscriber and deletes both
/// directories so no captured data lingers on disk.
@Observable @MainActor
final class CrashDiagnosticsService: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsService()

    let crashFileURL: URL
    let logTailURL: URL
    private let crashesDir: URL
    private let logsDir: URL

    private(set) var isEnabled: Bool = false
    private(set) var hasPendingCrash: Bool = false

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.crashesDir = appSupport.appendingPathComponent("crashes", isDirectory: true)
        self.logsDir = appSupport.appendingPathComponent("logs", isDirectory: true)
        self.crashFileURL = crashesDir.appendingPathComponent("last-crash.json")
        self.logTailURL = logsDir.appendingPathComponent("recent.txt")
        super.init()
    }

    /// Single mutation point. Called once at launch from `LocalGalleryApp.init`
    /// reading the `@AppStorage` default, and again from the Settings toggle's
    /// `.onChange`. Idempotent — calling with the current value is a no-op.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            try? FileManager.default.createDirectory(at: crashesDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            MXMetricManager.shared.add(self)
            hasPendingCrash = FileManager.default.fileExists(atPath: crashFileURL.path)
        } else {
            MXMetricManager.shared.remove(self)
            try? FileManager.default.removeItem(at: crashesDir)
            try? FileManager.default.removeItem(at: logsDir)
            hasPendingCrash = false
        }
    }

    /// Re-reads disk state so a payload that arrives mid-session surfaces
    /// without relying solely on the `didReceive` write. Cheap; called from
    /// the Settings banner's `scenePhase` observer.
    func refreshPendingCrash() {
        guard isEnabled else {
            hasPendingCrash = false
            return
        }
        hasPendingCrash = FileManager.default.fileExists(atPath: crashFileURL.path)
    }

    func pendingCrashReport() -> Data? {
        try? Data(contentsOf: crashFileURL)
    }

    func recentLogTail() -> Data? {
        try? Data(contentsOf: logTailURL)
    }

    /// Removes both files; sets `hasPendingCrash = false`. Used by the
    /// Settings Dismiss button and by the off-transition.
    func clearPendingCrash() {
        try? FileManager.default.removeItem(at: crashFileURL)
        try? FileManager.default.removeItem(at: logTailURL)
        hasPendingCrash = false
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let withCrashes = payloads.filter { ($0.crashDiagnostics?.isEmpty == false) }
        guard let payload = withCrashes.last else { return }
        let data = payload.jsonRepresentation()
        Task { @MainActor in
            guard self.isEnabled else { return }
            do {
                try data.write(to: self.crashFileURL, options: .atomic)
                self.hasPendingCrash = true
            } catch {
                Log.bg.warning("Failed to write crash report: \(error.localizedDescription)")
            }
        }
    }
}
