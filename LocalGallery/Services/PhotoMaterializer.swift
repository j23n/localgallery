import Foundation
import FileProvider
import Network
import Observation
import os

/// Materialises file-provider placeholders on demand. The viewer asks for a
/// photo's bytes, the materializer either returns immediately (already local)
/// or kicks off a coordinated read that pulls the file down from iCloud /
/// OneDrive / Proton / Drive / Dropbox. Progress flows back through `inFlight`
/// so the UI can show a spinner.
///
/// Coalesces concurrent requests for the same photo ID — fast swipe-back from
/// neighbour to current photo doesn't dispatch a duplicate fetch.
@MainActor
@Observable
final class PhotoMaterializer {
    /// In-flight materialisations keyed by photo ID. UI observes this to know
    /// whether to show a spinner. Not Sendable — values are reference-typed
    /// `Progress` instances.
    private(set) var inFlight: [PhotoFile.ID: Progress] = [:]

    /// Coalesce active tasks by photo ID. Multiple `ensureMaterialized` calls
    /// for the same photo await the same task instead of dispatching duplicates.
    private var activeTasks: [PhotoFile.ID: Task<URL, Error>] = [:]
    /// Per-request token so a superseded task's deferred cleanup can tell it
    /// no longer owns the `activeTasks`/`inFlight` entries for its photo.
    private var requestTokens: [PhotoFile.ID: UUID] = [:]

    /// Whether the current network path is "expensive" (cellular, personal
    /// hotspot). Prefetch — and only prefetch — is gated on it; explicit
    /// taps always go through regardless. `nonisolated(unsafe)` so the
    /// implicitly-nonisolated deinit can cancel the monitor.
    private nonisolated(unsafe) let pathMonitor = NWPathMonitor()
    private var isOnExpensivePath = false

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.isOnExpensivePath = expensive
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    enum MaterializationError: Error, LocalizedError {
        case providerError(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .providerError(let s): return s
            case .timeout: return "Download timed out."
            }
        }
    }

    /// Returns a URL whose bytes are guaranteed readable. Local photos
    /// short-circuit; placeholders are coordinated-read into existence.
    /// Throws on failure so the caller can surface a retry UI.
    @discardableResult
    func ensureMaterialized(_ photo: PhotoFile) async throws -> URL {
        // Fast path: already local.
        if photo.locality == .local {
            return photo.url
        }
        let probe = FileProviderDetector.probe(photo.url)
        if probe.status == .local {
            return photo.url
        }

        // Coalesce — return the existing task if one is already running.
        if let existing = activeTasks[photo.id] {
            return try await existing.value
        }

        let progress = Progress(totalUnitCount: 100)
        inFlight[photo.id] = progress
        let token = UUID()
        requestTokens[photo.id] = token

        let task = Task<URL, Error> { [weak self] in
            defer {
                // Token-checked cleanup: after a `cancel()` + re-request, the
                // *old* task's (uncancellable) coordinated read can finish
                // late — it must not wipe the new task's entries or the
                // second request loses coalescing and its spinner.
                if self?.requestTokens[photo.id] == token {
                    self?.inFlight[photo.id] = nil
                    self?.activeTasks[photo.id] = nil
                    self?.requestTokens[photo.id] = nil
                }
            }
            do {
                try await Self.coordinatedRead(at: photo.url, progress: progress)
                progress.completedUnitCount = progress.totalUnitCount
                return photo.url
            } catch {
                Log.scan.error("Materialize failed for \(Log.r.filename(photo.url.lastPathComponent)): \(Log.r.error(error))")
                throw MaterializationError.providerError(error.localizedDescription)
            }
        }
        activeTasks[photo.id] = task
        return try await task.value
    }

    /// Cancel an in-flight materialisation. Currently a best-effort: the
    /// underlying file coordinator can't be cancelled mid-read, so this just
    /// drops the task reference. The provider will finish whatever it started.
    func cancel(_ photoID: PhotoFile.ID) {
        activeTasks[photoID]?.cancel()
        activeTasks[photoID] = nil
        inFlight[photoID] = nil
        // Invalidate the cancelled task's token so its late cleanup can't
        // touch entries belonging to a subsequent request.
        requestTokens[photoID] = nil
    }

    /// Best-effort prefetch of adjacent photos (`[N-1, N+1]`). Skips items
    /// already local, already in flight, or non-file-provider. When
    /// `allowCellular` is false (the "Use Cellular Data" setting), prefetch
    /// is suppressed on expensive network paths.
    func prefetch(_ photos: [PhotoFile], allowCellular: Bool = true) {
        guard allowCellular || !isOnExpensivePath else { return }
        for photo in photos {
            guard activeTasks[photo.id] == nil else { continue }
            if photo.locality == .local { continue }
            Task { try? await self.ensureMaterialized(photo) }
        }
    }

    // MARK: - Coordinated read

    /// Trigger the file-provider download via `NSFileCoordinator`. The
    /// coordinator's `.forUploading` option blocks until the file is fully
    /// materialised — this is the universal fallback that works for every
    /// file provider (iCloud, OneDrive, Proton, Drive, Dropbox). Runs on a
    /// global queue because the coordinator blocks the calling thread.
    nonisolated private static func coordinatedRead(at url: URL, progress: Progress) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let coordinator = NSFileCoordinator()
                var coordError: NSError?
                coordinator.coordinate(
                    readingItemAt: url,
                    options: [.forUploading],
                    error: &coordError
                ) { _ in
                    // Accessor block returns once the file is fully present
                    // on disk. We don't need to read its bytes; we just
                    // needed the materialisation side-effect.
                }
                if let coordError {
                    continuation.resume(throwing: coordError)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
