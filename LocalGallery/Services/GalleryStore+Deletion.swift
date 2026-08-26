import Foundation
import os

/// Outcome of a user-initiated delete. Sidecars that were already missing
/// do not count as failures — only a photo whose *primary* file could not
/// be removed stays in the library.
struct PhotoDeleteResult: Sendable {
    var deletedIDs: Set<UUID>
    var failed: [UUID]
}

/// Confirmation copy for the delete alert. Shared by the grid select bar
/// and the viewer hamburger so both surfaces ask the same question.
enum PhotoDeletePrompt {
    static func title(for photos: [PhotoFile]) -> String {
        if photos.count == 1 {
            return photos[0].isVideo ? "Delete Video?" : "Delete Photo?"
        }
        let videos = photos.filter(\.isVideo).count
        if videos == photos.count {
            return "Delete \(photos.count) Videos?"
        }
        if videos == 0 {
            return "Delete \(photos.count) Photos?"
        }
        return "Delete \(photos.count) Items?"
    }

    static func message(for photos: [PhotoFile]) -> String {
        if photos.count == 1 {
            return photos[0].isVideo
                ? "This permanently deletes the video and its sidecar from disk."
                : "This permanently deletes the photo and its sidecar from disk."
        }
        return "This permanently deletes the files and their sidecars from disk."
    }
}

extension GalleryStore {
    /// Delete `photos` from disk (image/video + both sidecar spellings +
    /// Live Photo pair) and drop the ones that actually went from the
    /// in-memory library. Always call this behind a confirmation alert.
    func deletePhotos(_ photos: [PhotoFile]) async -> PhotoDeleteResult {
        let unique = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = Array(unique.values)
        guard !list.isEmpty else {
            return PhotoDeleteResult(deletedIDs: [], failed: [])
        }

        isMutatingDisk = true
        defer { isMutatingDisk = false }

        let outcomes: [(UUID, Bool)] = await Task.detached(priority: .userInitiated) {
            list.map { photo in
                do {
                    try PhotoDiskDelete.remove(photo)
                    return (photo.id, true)
                } catch {
                    return (photo.id, false)
                }
            }
        }.value

        var deletedIDs = Set<UUID>()
        var failed: [UUID] = []
        for (id, ok) in outcomes {
            if ok { deletedIDs.insert(id) } else { failed.append(id) }
        }
        if !failed.isEmpty {
            Log.fs.warning("Failed to delete \(failed.count) of \(list.count) photos")
        }
        if !deletedIDs.isEmpty {
            Log.fs.info("Deleted \(deletedIDs.count) photos (and sidecars)")
            apply(.photosRemoved(deletedIDs))
            sidecarCache.gc(keeping: Set(allPhotos.map(\.id)))
            lastSidecarManifest.removeAll { deletedIDs.contains($0.photoID) }
            persistLibraryCache()
            memories.forceRegenerate()
            exportWidgetSnapshot()
        }
        return PhotoDeleteResult(deletedIDs: deletedIDs, failed: failed)
    }
}

/// Coordinated `removeItem` for a photo and every file that belongs to it.
/// Missing companions (no sidecar, unpaired Live Photo movie) are success.
enum PhotoDiskDelete {
    nonisolated static func remove(_ photo: PhotoFile) throws {
        try removeIfPresent(photo.url)
        for url in photo.onDiskURLs where url != photo.url {
            try? removeIfPresent(url)
        }
    }

    nonisolated static func removeIfPresent(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        var coordError: NSError?
        var removeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordError
        ) { coordinated in
            do {
                try fm.removeItem(at: coordinated)
            } catch {
                removeError = error
            }
        }
        if let removeError { throw removeError }
        if coordError != nil {
            try fm.removeItem(at: url)
        }
    }
}
