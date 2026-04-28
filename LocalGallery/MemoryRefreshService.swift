import Foundation
import os

/// Indirection between the `BGAppRefreshTask` handler in `AppDelegate` and the
/// `GalleryStore` that owns memory state. Lets the BG handler call a stable
/// API without reaching into a global singleton on the manager.
///
/// The manager is `attach`ed by the `WindowGroup` once SwiftUI builds the scene.
/// On a true background-only launch the scene may never build, so the manager
/// stays nil and `runDailyRefresh()` no-ops — same behavior as the previous
/// `GalleryStore.shared` weak-singleton pattern. The next foreground entry
/// runs the same generation via the foreground catch-up path.
@MainActor
final class MemoryRefreshService {
    private weak var manager: GalleryStore?

    func attach(_ manager: GalleryStore) {
        self.manager = manager
    }

    func runDailyRefresh() async {
        guard let manager else {
            Log.bg.warning("MemoryRefreshService has no attached manager (background-only launch); nothing to do")
            return
        }
        await manager.runScheduledMemoryRefresh()
    }
}
