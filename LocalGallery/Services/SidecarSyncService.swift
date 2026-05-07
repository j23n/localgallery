import Foundation
import Observation
import os

/// Diffs a freshly-scanned sidecar manifest against `SidecarCacheStore`,
/// fetches the deltas through `NSFileCoordinator`, parses each `.xmp`, and
/// writes the result back to the cache. Surfaces a banner-friendly progress
/// state and a prompt when the fetch pile crosses a size threshold.
@MainActor
@Observable
final class SidecarSyncService {
    /// Above either threshold the user gets an explicit prompt before we
    /// kick off the fetch. Below it we sync silently.
    nonisolated static let promptThresholdCount = 5_000
    nonisolated static let promptThresholdBytes: Int64 = 50_000_000

    /// Foreground concurrency. Plan calls out 8; can be tuned down per
    /// provider via debug toggle if rate-limit telemetry warrants.
    nonisolated static let foregroundConcurrency = 8

    enum SyncState: Equatable, Sendable {
        case idle
        case awaitingPrompt(count: Int, bytes: Int64)
        case syncing(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int)
    }

    private(set) var state: SyncState = .idle

    private let cache: SidecarCacheStore
    /// In-flight fetch task. Settings UI's "Cancel" button calls `cancel()`
    /// which propagates to the TaskGroup.
    private var activeTask: Task<Void, Never>?
    /// Fired on the main actor after a sync run completes (success or
    /// failure). Used by `GalleryStore` to re-merge fresh sidecar data into
    /// live `allPhotos` so tags/country codes surface without a rescan.
    var onFinished: (@MainActor () -> Void)?

    init(cache: SidecarCacheStore) {
        self.cache = cache
    }

    // MARK: - Diff buckets

    private struct DiffResult {
        var needsFetch: [FolderScanner.SidecarCandidate]
        var orphans: Set<UUID>
        var upToDate: Int
    }

    private func diff(
        manifest: [FolderScanner.SidecarCandidate],
        knownPhotoIDs: Set<UUID>
    ) -> DiffResult {
        var needsFetch: [FolderScanner.SidecarCandidate] = []
        var upToDate = 0
        let manifestIDs = Set(manifest.map(\.photoID))

        for candidate in manifest {
            if let cached = cache.get(candidate.photoID),
               FileProviderDetector.ContentVersion.sameContent(cached.version, candidate.currentVersion) {
                upToDate += 1
            } else {
                needsFetch.append(candidate)
            }
        }

        // Orphans: cached entries whose photo no longer exists in the library.
        let orphans = knownPhotoIDs.subtracting(manifestIDs)
        return DiffResult(needsFetch: needsFetch, orphans: orphans, upToDate: upToDate)
    }

    // MARK: - Drive a sync run

    /// Diff the manifest against the cache. If the fetch pile is small,
    /// kick off the sync immediately and return. If it crosses a threshold,
    /// move into `.awaitingPrompt` and wait for `confirmPrompt(_:)`.
    func plan(
        manifest: [FolderScanner.SidecarCandidate],
        allPhotoIDs: Set<UUID>,
        autoApprove: Bool
    ) {
        // Always GC orphans regardless of fetch decisions.
        cache.gc(keeping: allPhotoIDs)

        let result = diff(manifest: manifest, knownPhotoIDs: cache.allPhotoIDs)
        let totalBytes = result.needsFetch.reduce(Int64(0)) { $0 + ($1.currentVersion.size ?? 0) }
        Log.cache.info("Sidecar diff: \(result.needsFetch.count) to fetch, \(result.upToDate) up to date")

        guard !result.needsFetch.isEmpty else {
            state = .idle
            return
        }

        let needsPrompt = !autoApprove
            && (result.needsFetch.count >= Self.promptThresholdCount
                || totalBytes >= Self.promptThresholdBytes)

        if needsPrompt {
            state = .awaitingPrompt(count: result.needsFetch.count, bytes: totalBytes)
        } else {
            beginFetch(result.needsFetch)
        }
    }

    /// User responded to the threshold prompt.
    func confirmPrompt(_ approved: Bool, manifest: [FolderScanner.SidecarCandidate]) {
        guard case .awaitingPrompt = state else { return }
        guard approved else {
            state = .idle
            return
        }
        let result = diff(manifest: manifest, knownPhotoIDs: cache.allPhotoIDs)
        beginFetch(result.needsFetch)
    }

    func cancel() {
        activeTask?.cancel()
    }

    // MARK: - Fetch loop

    private func beginFetch(_ candidates: [FolderScanner.SidecarCandidate]) {
        let total = candidates.count
        guard total > 0 else { state = .idle; return }
        state = .syncing(done: 0, total: total)
        let cache = self.cache
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await Self.runFetch(
                candidates: candidates,
                cache: cache,
                progress: { @MainActor [weak self] done in
                    guard case .syncing = self?.state else { return }
                    self?.state = .syncing(done: done, total: total)
                },
                done: { @MainActor [weak self] succeeded, failed in
                    self?.state = .finished(succeeded: succeeded, failed: failed)
                    self?.activeTask = nil
                    self?.onFinished?()
                }
            )
        }
    }

    /// Foreground worker — `Task.detached` parallel TaskGroup with concurrency
    /// 8. Cancels propagate from `activeTask.cancel()`.
    nonisolated private static func runFetch(
        candidates: [FolderScanner.SidecarCandidate],
        cache: SidecarCacheStore,
        progress: @MainActor @escaping (Int) -> Void,
        done: @MainActor @escaping (Int, Int) -> Void
    ) async {
        let limiter = AsyncSemaphore(limit: foregroundConcurrency)
        var doneCount = 0
        var succeeded = 0
        var failed = 0

        await withTaskGroup(of: (UUID, SidecarCacheStore.CachedSidecar?).self) { group in
            for candidate in candidates {
                if Task.isCancelled { break }
                await limiter.acquire()
                group.addTask {
                    defer { Task { await limiter.release() } }
                    let result = await fetchOne(candidate)
                    return (candidate.photoID, result)
                }
            }

            for await (photoID, entry) in group {
                doneCount += 1
                if let entry {
                    succeeded += 1
                    await MainActor.run { cache.put(photoID, entry) }
                } else {
                    failed += 1
                }
                if doneCount % 50 == 0 || doneCount == candidates.count {
                    let snapshot = doneCount
                    await progress(snapshot)
                }
            }
        }

        await done(succeeded, failed)
    }

    /// Coordinated read + parse for a single sidecar. Returns nil on failure
    /// (provider error, parse error, file vanished mid-fetch).
    nonisolated private static func fetchOne(
        _ candidate: FolderScanner.SidecarCandidate
    ) async -> SidecarCacheStore.CachedSidecar? {
        let url = candidate.sidecarURL
        do {
            let data = try await coordinatedSidecarRead(at: url)
            let parsed = MetadataReader.parseXMPBytes(data)

            // Deduplicate hierarchical tags (mirrors readImageMetadata).
            var seen = Set<String>()
            let tags = parsed.rawTags.compactMap { raw -> HierarchicalTag? in
                let key = raw.lowercased()
                guard !seen.contains(key) else { return nil }
                seen.insert(key)
                return HierarchicalTag(raw: raw)
            }

            return SidecarCacheStore.CachedSidecar(
                version: candidate.currentVersion,
                hierarchicalTags: tags,
                countryCode: parsed.countryCode,
                dateTaken: nil,
                gpsLatitude: nil,
                gpsLongitude: nil,
                faceRegions: parsed.faceRegions
            )
        } catch {
            Log.cache.error("Sidecar fetch failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func coordinatedSidecarRead(at url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let coordinator = NSFileCoordinator()
                var coordError: NSError?
                var readData: Data?
                var readError: Error?
                coordinator.coordinate(
                    readingItemAt: url,
                    options: [.forUploading],
                    error: &coordError
                ) { effectiveURL in
                    do {
                        readData = try Data(contentsOf: effectiveURL)
                    } catch {
                        readError = error
                    }
                }
                if let coordError {
                    continuation.resume(throwing: coordError)
                } else if let readError {
                    continuation.resume(throwing: readError)
                } else if let readData {
                    continuation.resume(returning: readData)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}

// MARK: - Async semaphore

/// Tiny actor-backed counting semaphore for bounding TaskGroup parallelism.
/// The pattern mirrors `ThumbnailService.DecodeLimiter` but lives here to
/// avoid a cross-service dependency.
private actor AsyncSemaphore {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            active -= 1
        }
    }
}

