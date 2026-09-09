import Foundation
import os

/// Outcome of a user-initiated delete. Sidecars that were already missing
/// do not count as failures. A photo whose *primary* file could not be
/// removed stays in the library. Primary-gone / companion-left is a
/// partial success: the row is dropped, but the leftover files are
/// surfaced so the caller never treats "primary deleted" as a clean wipe.
struct PhotoDeleteResult: Sendable {
    var deletedIDs: Set<UUID>
    var failed: [UUID]
    /// Primary removed, at least one companion still on disk.
    var partialIDs: Set<UUID> = []
    /// Leftover companions (or a half-applied move) need a rescan.
    var needsReconciliation: Bool = false
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
    /// Live Photo pair) and drop the ones whose primary actually left the
    /// in-memory library. Always call this behind a confirmation alert.
    func deletePhotos(_ photos: [PhotoFile]) async -> PhotoDeleteResult {
        let unique = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = Array(unique.values)
        guard !list.isEmpty else {
            return PhotoDeleteResult(deletedIDs: [], failed: [])
        }

        isMutatingDisk = true
        defer { isMutatingDisk = false }

        let attempts: [PhotoDeleteAttempt] = await Task.detached(priority: .userInitiated) {
            list.map { PhotoDiskDelete.execute($0) }
        }.value

        var deletedIDs = Set<UUID>()
        var failed: [UUID] = []
        var partialIDs = Set<UUID>()
        var needsReconciliation = false
        for attempt in attempts {
            switch attempt.verdict {
            case .succeeded:
                deletedIDs.insert(attempt.id)
            case .partial:
                deletedIDs.insert(attempt.id)
                partialIDs.insert(attempt.id)
                needsReconciliation = true
            case .failed, .rolledBack, .needsReconciliation, .skipped:
                failed.append(attempt.id)
            }
        }
        if !failed.isEmpty {
            Log.fs.warning("Failed to delete \(failed.count) of \(list.count) photos")
        }
        if !partialIDs.isEmpty {
            Log.fs.warning("Partial delete for \(partialIDs.count) photos; leftover companions remain")
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
        if needsReconciliation {
            Task { await rescan(kind: .light, silent: true) }
        }
        return PhotoDeleteResult(
            deletedIDs: deletedIDs,
            failed: failed,
            partialIDs: partialIDs,
            needsReconciliation: needsReconciliation
        )
    }
}

/// One file that belongs to a photo on disk.
enum PhotoCompanionRole: String, Sendable, Equatable, CaseIterable {
    case primary
    case sidecar
    case altSidecar
    case livePhoto
    case liveSidecar
    case liveAltSidecar

    var isPrimary: Bool { self == .primary }
}

enum PhotoStepStatus: Sendable, Equatable {
    case succeeded
    case missing
    case failed
}

struct PhotoStepOutcome: Sendable, Equatable {
    var role: PhotoCompanionRole
    var url: URL
    var status: PhotoStepStatus
}

enum PhotoMutationVerdict: Sendable, Equatable {
    case succeeded
    case skipped
    case failed
    case partial
    case rolledBack
    case needsReconciliation
}

struct PhotoDeleteStep: Sendable, Equatable {
    var role: PhotoCompanionRole
    var url: URL
}

struct PhotoDeleteAttempt: Sendable {
    var id: UUID
    var verdict: PhotoMutationVerdict
    var outcomes: [PhotoStepOutcome]
}

/// Coordinated `removeItem` for a photo and every file that belongs to it.
/// Missing companions (no sidecar, unpaired Live Photo movie) are success.
/// A leftover companion after the primary is gone is a *partial* delete —
/// never reported as a clean success.
enum PhotoDiskDelete {
    nonisolated static func plan(for photo: PhotoFile) -> [PhotoDeleteStep] {
        var steps = [PhotoDeleteStep(role: .primary, url: photo.url)]
        steps.append(PhotoDeleteStep(role: .sidecar, url: photo.sidecarURL))
        if let alt = photo.altSidecarURL {
            steps.append(PhotoDeleteStep(role: .altSidecar, url: alt))
        }
        if let live = photo.livePhotoVideoURL {
            steps.append(PhotoDeleteStep(role: .livePhoto, url: live))
            steps.append(PhotoDeleteStep(role: .liveSidecar, url: PhotoFile.canonicalSidecarURL(for: live)))
            if let alt = PhotoFile.altSidecarURL(for: live) {
                steps.append(PhotoDeleteStep(role: .liveAltSidecar, url: alt))
            }
        }
        return steps
    }

    nonisolated static func verdict(for outcomes: [PhotoStepOutcome]) -> PhotoMutationVerdict {
        guard let primary = outcomes.first(where: { $0.role.isPrimary }) else {
            return .failed
        }
        switch primary.status {
        case .failed:
            return .failed
        case .succeeded, .missing:
            let companionFailed = outcomes.contains { !$0.role.isPrimary && $0.status == .failed }
            return companionFailed ? .partial : .succeeded
        }
    }

    nonisolated static func execute(_ photo: PhotoFile) -> PhotoDeleteAttempt {
        let plan = plan(for: photo)
        let outcomes = plan.map { step -> PhotoStepOutcome in
            let existed = FileManager.default.fileExists(atPath: step.url.path)
            do {
                try removeIfPresent(step.url, role: step.role)
                if !existed {
                    return PhotoStepOutcome(role: step.role, url: step.url, status: .missing)
                }
                let leftover = FileManager.default.fileExists(atPath: step.url.path)
                return PhotoStepOutcome(
                    role: step.role,
                    url: step.url,
                    status: leftover ? .failed : .succeeded
                )
            } catch {
                let leftover = FileManager.default.fileExists(atPath: step.url.path)
                if !leftover {
                    return PhotoStepOutcome(
                        role: step.role,
                        url: step.url,
                        status: existed ? .succeeded : .missing
                    )
                }
                return PhotoStepOutcome(role: step.role, url: step.url, status: .failed)
            }
        }
        return PhotoDeleteAttempt(id: photo.id, verdict: verdict(for: outcomes), outcomes: outcomes)
    }

    nonisolated static func remove(_ photo: PhotoFile) throws {
        let attempt = execute(photo)
        switch attempt.verdict {
        case .succeeded: return
        case .partial: throw PhotoDiskMutationError.partialFailure
        case .failed, .rolledBack, .needsReconciliation, .skipped:
            throw PhotoDiskMutationError.primaryFailure
        }
    }

    nonisolated static func removeIfPresent(_ url: URL) throws {
        try removeIfPresent(url, role: .primary)
    }

    nonisolated static func removeIfPresent(_ url: URL, role: PhotoCompanionRole) throws {
        #if DEBUG
        if testFailRoles.contains(role) {
            if FileManager.default.fileExists(atPath: url.path) {
                throw PhotoDiskMutationError.forcedFailure
            }
            return
        }
        #endif
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

    #if DEBUG
    /// Test seam: treat these roles as present-and-undeletable.
    nonisolated(unsafe) static var testFailRoles: Set<PhotoCompanionRole> = []
    #endif
}

enum PhotoDiskMutationError: Error, Equatable {
    case partialFailure
    case primaryFailure
    case forcedFailure
}

struct PhotoMoveResult: Sendable {
    var moved: [UUID: PhotoFile]
    var failed: [UUID]
    /// Primary reached the destination but at least one companion did not,
    /// and rollback could not restore the original layout.
    var partialIDs: Set<UUID> = []
    var needsReconciliation: Bool = false
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
    /// that folder are skipped, not renamed. Companion failure rolls the
    /// primary back when possible; otherwise the library is updated to the
    /// new primary path and a rescan is forced.
    func movePhotos(_ photos: [PhotoFile], to destination: PhotoFolder) async -> PhotoMoveResult {
        let unique = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = Array(unique.values)
        guard !list.isEmpty else {
            return PhotoMoveResult(moved: [:], failed: [])
        }

        isMutatingDisk = true
        defer { isMutatingDisk = false }

        let destURL = destination.url
        let attempts: [PhotoMoveAttempt] = await Task.detached(priority: .userInitiated) {
            list.map { photo in
                PhotoDiskMove.relocate(photo, to: destURL)
            }
        }.value

        var moved: [UUID: PhotoFile] = [:]
        var failed: [UUID] = []
        var partialIDs = Set<UUID>()
        var needsReconciliation = false
        for attempt in attempts {
            switch attempt.verdict {
            case .skipped:
                break
            case .succeeded:
                if let photo = attempt.photo, photo.id != attempt.id {
                    moved[attempt.id] = photo
                }
            case .failed, .rolledBack:
                failed.append(attempt.id)
            case .partial, .needsReconciliation:
                if let photo = attempt.photo {
                    moved[attempt.id] = photo
                }
                partialIDs.insert(attempt.id)
                needsReconciliation = true
            }
        }
        if !failed.isEmpty {
            Log.fs.warning("Failed to move \(failed.count) of \(list.count) photos")
        }
        if !partialIDs.isEmpty {
            Log.fs.warning("Partial move for \(partialIDs.count) photos; forcing reconciliation")
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
        if needsReconciliation {
            Task { await rescan(kind: .light, silent: true) }
        }
        return PhotoMoveResult(
            moved: moved,
            failed: failed,
            partialIDs: partialIDs,
            needsReconciliation: needsReconciliation
        )
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

struct PhotoMoveStep: Sendable, Equatable {
    var role: PhotoCompanionRole
    var from: URL
    var to: URL
}

struct PhotoMoveAttempt: Sendable {
    var id: UUID
    var photo: PhotoFile?
    var verdict: PhotoMutationVerdict
    var outcomes: [PhotoStepOutcome]
}

/// Coordinated `moveItem` for a photo and every file that belongs to it.
enum PhotoDiskMove {
    /// Relocate `photo` into `directory`. Returns the original photo when
    /// it is already there (no rename-in-place). Companion failures roll
    /// completed steps back when possible; otherwise the attempt records
    /// `.needsReconciliation` and the relocated primary (if it landed).
    nonisolated static func relocate(_ photo: PhotoFile, to directory: URL) -> PhotoMoveAttempt {
        let here = photo.url.deletingLastPathComponent().standardizedFileURL.path
        let there = directory.standardizedFileURL.path
        if here == there {
            return PhotoMoveAttempt(id: photo.id, photo: photo, verdict: .skipped, outcomes: [])
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return PhotoMoveAttempt(id: photo.id, photo: nil, verdict: .failed, outcomes: [])
        }

        let names = uniqueNames(for: photo, in: directory)
        let newURL = directory.appendingPathComponent(names.photo)
        let newLive = names.live.map { directory.appendingPathComponent($0) }
        let steps = plan(for: photo, directory: directory, names: names)
        return execute(steps, photo: photo, newURL: newURL, newLive: newLive)
    }

    nonisolated static func plan(
        for photo: PhotoFile,
        directory: URL,
        names: (photo: String, live: String?)
    ) -> [PhotoMoveStep] {
        let newURL = directory.appendingPathComponent(names.photo)
        var steps = [
            PhotoMoveStep(role: .primary, from: photo.url, to: newURL),
            PhotoMoveStep(
                role: .sidecar,
                from: photo.sidecarURL,
                to: PhotoFile.canonicalSidecarURL(for: newURL)
            ),
        ]
        if let from = photo.altSidecarURL, let to = PhotoFile.altSidecarURL(for: newURL) {
            steps.append(PhotoMoveStep(role: .altSidecar, from: from, to: to))
        }
        if let live = photo.livePhotoVideoURL, let dest = names.live.map({ directory.appendingPathComponent($0) }) {
            steps.append(PhotoMoveStep(role: .livePhoto, from: live, to: dest))
            steps.append(PhotoMoveStep(
                role: .liveSidecar,
                from: PhotoFile.canonicalSidecarURL(for: live),
                to: PhotoFile.canonicalSidecarURL(for: dest)
            ))
            if let from = PhotoFile.altSidecarURL(for: live),
               let to = PhotoFile.altSidecarURL(for: dest) {
                steps.append(PhotoMoveStep(role: .liveAltSidecar, from: from, to: to))
            }
        }
        return steps
    }

    nonisolated static func verdict(
        primary: PhotoStepStatus,
        companions: [PhotoStepOutcome],
        rollback: PhotoMutationVerdict?
    ) -> PhotoMutationVerdict {
        switch primary {
        case .failed, .missing:
            return .failed
        case .succeeded:
            let companionFailed = companions.contains { $0.status == .failed }
            guard companionFailed else { return .succeeded }
            return rollback ?? .partial
        }
    }

    nonisolated private static func execute(
        _ steps: [PhotoMoveStep],
        photo: PhotoFile,
        newURL: URL,
        newLive: URL?
    ) -> PhotoMoveAttempt {
        var outcomes: [PhotoStepOutcome] = []
        var completed: [PhotoMoveStep] = []
        var primaryStatus: PhotoStepStatus = .failed

        for step in steps {
            let outcome = perform(step)
            outcomes.append(outcome)
            if step.role.isPrimary {
                primaryStatus = outcome.status
                if outcome.status != .succeeded {
                    break
                }
                completed.append(step)
            } else {
                if outcome.status == .succeeded {
                    completed.append(step)
                }
                if outcome.status == .failed {
                    let rollback = rollback(completed)
                    let verdict = Self.verdict(
                        primary: primaryStatus,
                        companions: outcomes.filter { !$0.role.isPrimary },
                        rollback: rollback
                    )
                    let relocated = (verdict == .needsReconciliation || verdict == .partial)
                        ? photo.relocated(to: newURL, livePhotoVideoURL: newLive)
                        : nil
                    return PhotoMoveAttempt(
                        id: photo.id,
                        photo: relocated,
                        verdict: verdict,
                        outcomes: outcomes
                    )
                }
            }
        }

        let companions = outcomes.filter { !$0.role.isPrimary }
        let verdict = Self.verdict(primary: primaryStatus, companions: companions, rollback: nil)
        let relocated: PhotoFile?
        switch verdict {
        case .succeeded:
            relocated = photo.relocated(to: newURL, livePhotoVideoURL: newLive)
        case .partial, .needsReconciliation:
            relocated = photo.relocated(to: newURL, livePhotoVideoURL: newLive)
        case .failed, .rolledBack, .skipped:
            relocated = nil
        }
        return PhotoMoveAttempt(id: photo.id, photo: relocated, verdict: verdict, outcomes: outcomes)
    }

    nonisolated private static func perform(_ step: PhotoMoveStep) -> PhotoStepOutcome {
        do {
            let existed = FileManager.default.fileExists(atPath: step.from.path)
            try moveIfPresent(step.from, to: step.to, role: step.role)
            if !existed {
                return PhotoStepOutcome(role: step.role, url: step.from, status: .missing)
            }
            let landed = FileManager.default.fileExists(atPath: step.to.path)
            return PhotoStepOutcome(
                role: step.role,
                url: step.from,
                status: landed ? .succeeded : .failed
            )
        } catch {
            return PhotoStepOutcome(role: step.role, url: step.from, status: .failed)
        }
    }

    /// Undo completed steps, dest → source, last-in first. `.rolledBack`
    /// when every completed file is back; `.needsReconciliation` otherwise.
    nonisolated static func rollback(_ completed: [PhotoMoveStep]) -> PhotoMutationVerdict {
        var restored = true
        for step in completed.reversed() {
            #if DEBUG
            if testFailRollback {
                restored = false
                continue
            }
            #endif
            do {
                try moveIfPresent(step.to, to: step.from)
                if FileManager.default.fileExists(atPath: step.to.path)
                    && !FileManager.default.fileExists(atPath: step.from.path) {
                    restored = false
                }
            } catch {
                restored = false
            }
        }
        return restored ? .rolledBack : .needsReconciliation
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
        try moveIfPresent(src, to: dest, role: .primary)
    }

    nonisolated static func moveIfPresent(_ src: URL, to dest: URL, role: PhotoCompanionRole) throws {
        #if DEBUG
        if testFailRoles.contains(role) {
            if FileManager.default.fileExists(atPath: src.path) {
                throw PhotoDiskMutationError.forcedFailure
            }
            return
        }
        #endif
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

    #if DEBUG
    nonisolated(unsafe) static var testFailRoles: Set<PhotoCompanionRole> = []
    nonisolated(unsafe) static var testFailRollback = false
    #endif
}
