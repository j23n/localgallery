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

struct PhotoMoveResult: Sendable {
    var moved: [UUID: PhotoFile]
    var failed: [UUID]
}

enum PhotoMovePrompt {
    static func title(for photos: [PhotoFile]) -> String {
        if photos.count == 1 {
            return photos[0].isVideo ? "Move Video?" : "Move Photo?"
        }
        let videos = photos.filter(\.isVideo).count
        if videos == photos.count {
            return "Move \(photos.count) Videos?"
        }
        if videos == 0 {
            return "Move \(photos.count) Photos?"
        }
        return "Move \(photos.count) Items?"
    }

    static func message(for photos: [PhotoFile], destination: PhotoFolder) -> String {
        let dest = destination.name
        if photos.count == 1 {
            return photos[0].isVideo
                ? "This moves the video and its sidecar into “\(dest)”."
                : "This moves the photo and its sidecar into “\(dest)”."
        }
        return "This moves the files and their sidecars into “\(dest)”."
    }
}

extension GalleryStore {
    /// Move `photos` into `destination` on disk (image/video + sidecars +
    /// Live Photo pair). Identity follows the new path. Photos already in
    /// that folder are skipped, not renamed.
    func movePhotos(_ photos: [PhotoFile], to destination: PhotoFolder) async -> PhotoMoveResult {
        let unique = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = Array(unique.values)
        guard !list.isEmpty else {
            return PhotoMoveResult(moved: [:], failed: [])
        }

        isMutatingDisk = true
        defer { isMutatingDisk = false }

        let destURL = destination.url
        let outcomes: [(UUID, PhotoFile?)] = await Task.detached(priority: .userInitiated) {
            list.map { photo in
                do {
                    let moved = try PhotoDiskMove.relocate(photo, to: destURL)
                    return (photo.id, moved)
                } catch {
                    return (photo.id, nil)
                }
            }
        }.value

        var moved: [UUID: PhotoFile] = [:]
        var failed: [UUID] = []
        for (id, photo) in outcomes {
            if let photo {
                if photo.id != id { moved[id] = photo }
            } else {
                failed.append(id)
            }
        }
        if !failed.isEmpty {
            Log.fs.warning("Failed to move \(failed.count) of \(list.count) photos")
        }
        if !moved.isEmpty {
            Log.fs.info("Moved \(moved.count) photos to \(Log.r.path(destURL))")
            apply(.photosRelocated(
                from: Set(moved.keys),
                to: Array(moved.values),
                destFolderID: destination.id
            ))
            for (old, photo) in moved {
                sidecarCache.relocate(from: old, to: photo.id)
            }
            people.remapFeaturedPhotoIDs(moved.mapValues(\.id))
            lastSidecarManifest.removeAll { moved.keys.contains($0.photoID) }
            persistLibraryCache()
            memories.forceRegenerate()
            exportWidgetSnapshot()
            if let root = bookmarks.activeURL {
                libraryMonitor.sync(root: root, tree: rootFolder)
            }
        }
        return PhotoMoveResult(moved: moved, failed: failed)
    }

    /// Create a subdirectory of `parent` on disk and insert it into the
    /// live tree. `nil` if the name is unusable or the create fails.
    func createFolder(named name: String, in parent: PhotoFolder) -> PhotoFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\0") else { return nil }
        let url = parent.url.appendingPathComponent(trimmed, isDirectory: true)
        isMutatingDisk = true
        defer { isMutatingDisk = false }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.fs.warning("Failed to create folder \(Log.r.path(url)): \(Log.r.error(error))")
            return nil
        }
        let created = PhotoFolder(
            id: PhotoFolder.stableID(for: url),
            url: url,
            name: trimmed,
            subfolders: [],
            photos: [],
            coverPhotoURL: nil,
            totalPhotoCount: 0,
            dateModified: clock.now(),
            dateCreated: clock.now()
        )
        if let root = rootFolder {
            rootFolder = root.inserting(created, inParent: parent.id)
            persistLibraryCache()
            if let bookmark = bookmarks.activeURL {
                libraryMonitor.sync(root: bookmark, tree: rootFolder)
            }
        }
        return created
    }
}

/// Coordinated `moveItem` for a photo and every file that belongs to it.
enum PhotoDiskMove {
    /// Relocate `photo` into `directory`. Returns the original photo when
    /// it is already there (no rename-in-place). Throws only if the
    /// primary file cannot be moved.
    nonisolated static func relocate(_ photo: PhotoFile, to directory: URL) throws -> PhotoFile {
        let here = photo.url.deletingLastPathComponent().standardizedFileURL.path
        let there = directory.standardizedFileURL.path
        if here == there { return photo }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let names = uniqueNames(for: photo, in: directory)
        let newURL = directory.appendingPathComponent(names.photo)
        let newLive = names.live.map { directory.appendingPathComponent($0) }

        try moveIfPresent(photo.url, to: newURL)
        try? moveIfPresent(photo.sidecarURL, to: PhotoFile.canonicalSidecarURL(for: newURL))
        if let from = photo.altSidecarURL, let to = PhotoFile.altSidecarURL(for: newURL) {
            try? moveIfPresent(from, to: to)
        }
        if let live = photo.livePhotoVideoURL, let dest = newLive {
            try? moveIfPresent(live, to: dest)
            try? moveIfPresent(
                PhotoFile.canonicalSidecarURL(for: live),
                to: PhotoFile.canonicalSidecarURL(for: dest)
            )
            if let from = PhotoFile.altSidecarURL(for: live),
               let to = PhotoFile.altSidecarURL(for: dest) {
                try? moveIfPresent(from, to: to)
            }
        }
        return photo.relocated(to: newURL, livePhotoVideoURL: newLive)
    }

    nonisolated static func uniqueNames(
        for photo: PhotoFile,
        in directory: URL
    ) -> (photo: String, live: String?) {
        let photoName = photo.url.lastPathComponent
        let liveName = photo.livePhotoVideoURL?.lastPathComponent
        if !isTaken(photoName, live: liveName, in: directory) {
            return (photoName, liveName)
        }
        let ns = photoName as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 2
        while true {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let liveNext = liveName.map { restem($0, newStem: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n)") }
            if !isTaken(next, live: liveNext, in: directory) {
                return (next, liveNext)
            }
            n += 1
        }
    }

    nonisolated private static func restem(_ filename: String, newStem: String) -> String {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? newStem : "\(newStem).\(ext)"
    }

    nonisolated private static func isTaken(_ name: String, live: String?, in directory: URL) -> Bool {
        exists(directory.appendingPathComponent(name))
            || (live.map { exists(directory.appendingPathComponent($0)) } ?? false)
    }

    nonisolated private static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        if fm.fileExists(atPath: url.path + ".xmp") { return true }
        if let alt = PhotoFile.altSidecarURL(for: url), fm.fileExists(atPath: alt.path) { return true }
        return false
    }

    nonisolated static func moveIfPresent(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        if src.standardizedFileURL.path == dest.standardizedFileURL.path { return }

        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: src,
            options: .forMoving,
            writingItemAt: dest,
            options: .forReplacing,
            error: &coordError
        ) { from, to in
            do {
                try fm.moveItem(at: from, to: to)
            } catch {
                moveError = error
            }
        }
        if let moveError { throw moveError }
        if coordError != nil {
            try fm.moveItem(at: src, to: dest)
        }
    }
}
