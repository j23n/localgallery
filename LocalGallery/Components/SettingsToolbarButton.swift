import SwiftUI

/// Gear button used by the three top-level toolbars (Folders, Photos,
/// Collections). Presents the Settings sheet via the binding the call site
/// already owns; overlays a small red dot when a crash payload is pending so
/// the user notices the in-Settings banner without us pushing a full
/// notification.
///
/// The badge is gated by both `crashReportingEnabled` (master switch) and
/// `hasPendingCrash` (a payload is on disk). `hasPendingCrash` is
/// `@Observable`, so the overlay re-evaluates automatically when MetricKit
/// delivers a payload mid-session or when the user taps Dismiss.
struct SettingsToolbarButton: View {
    @Binding var isPresented: Bool
    @AppStorage("crashReportingEnabled") private var crashReportingEnabled = false
    var crashService = CrashDiagnosticsService.shared

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "gear")
                .overlay(alignment: .topTrailing) {
                    if crashReportingEnabled, crashService.hasPendingCrash {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                    }
                }
        }
    }
}
