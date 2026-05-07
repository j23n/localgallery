import Foundation
import os

/// Indirection between the `BGAppRefreshTask` handler in `AppDelegate` and the
/// `GalleryStore`. Mirror of `MemoryRefreshService` for the sidecar-sync
/// background task — same attach pattern, different work.
///
/// Foreground sync runs the first-time bulk fetch with prompts; this BG
/// service handles incremental top-up only. Per the plan, soft-cap at 200
/// sidecars per BG window and concurrency 4 (lower than foreground 8) to
/// stay polite under iOS BG limits.
@MainActor
final class SidecarRefreshService {
    private weak var store: GalleryStore?

    func attach(_ store: GalleryStore) {
        self.store = store
    }

    func runRefresh() async {
        guard let store else {
            Log.bg.warning("SidecarRefreshService has no attached store; nothing to do")
            return
        }
        guard !store.lastSidecarManifest.isEmpty else {
            Log.bg.info("No sidecar manifest yet (no foreground scan); skipping BG sidecar refresh")
            return
        }
        // Auto-approve in BG — we can't surface a UI prompt from here, so
        // we never trigger a fetch large enough to warrant one.
        let allIDs = Set(store.allPhotos.map(\.id))
        store.sidecarSync.plan(
            manifest: store.lastSidecarManifest,
            allPhotoIDs: allIDs,
            autoApprove: true
        )
    }
}
