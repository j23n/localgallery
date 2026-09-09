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

    /// BGAppRefresh hard caps — honoured even when the caller auto-approves,
    /// because a background task cannot surface a prompt and must stay
    /// inside the system budget.
    nonisolated static let backgroundMaxCount = 200
    nonisolated static let backgroundConcurrency = 4
    nonisolated static let backgroundMaxTotalBytes: Int64 = 10_000_000
    nonisolated static let backgroundMaxFileBytes: Int64 = 1_048_576

    /// How long a coordinated sidecar read may block before the fetch
    /// treats it as a failure and moves on. Provider hangs must not pin
    /// a `BGAppRefreshTask` until the system expires it.
    nonisolated static let fileReadTimeout: Duration = .seconds(15)

    enum SyncState: Equatable, Sendable {
        case idle
        case awaitingPrompt(count: Int, bytes: Int64)
        case syncing(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int)
    }

    /// Foreground vs background fetch policy. Limits attach to the policy,
    /// not to `autoApprove` — auto-approval only skips the UI prompt.
    enum SyncPolicy: Equatable, Sendable {
        case foreground
        case background

        var concurrency: Int {
            switch self {
            case .foreground: return SidecarSyncService.foregroundConcurrency
            case .background: return SidecarSyncService.backgroundConcurrency
            }
        }

        var maxCount: Int? {
            switch self {
            case .foreground: return nil
            case .background: return SidecarSyncService.backgroundMaxCount
            }
        }

        var maxTotalBytes: Int64? {
            switch self {
            case .foreground: return nil
            case .background: return SidecarSyncService.backgroundMaxTotalBytes
            }
        }

        var maxFileBytes: Int64? {
            switch self {
            case .foreground: return nil
            case .background: return SidecarSyncService.backgroundMaxFileBytes
            }
        }
    }

    /// How complete the sidecar listing that produced `manifest` was.
    /// Cache retraction is only safe after a successful complete listing;
    /// a failed directory or provider error must not look like deletion.
    struct Listing: Equatable, Sendable {
        var isComplete: Bool
        /// Photo IDs whose sidecar file was observed gone (re-probe).
        var confirmedGone: Set<UUID>

        static let complete = Listing(isComplete: true, confirmedGone: [])
        /// Fail-safe: preserve cache entries that are merely missing from
        /// this manifest — used when the walk was partial or unknown.
        static let incomplete = Listing(isComplete: false, confirmedGone: [])

        static func from(failedDirectoryPaths: [String]) -> Listing {
            Listing(isComplete: failedDirectoryPaths.isEmpty, confirmedGone: [])
        }
    }

    enum ReadError: Error, Equatable {
        case timeout
    }

    private(set) var state: SyncState = .idle

    private let cache: SidecarCacheStore
    /// In-flight fetch task. Settings UI's "Cancel" button calls `cancel()`
    /// which propagates to the TaskGroup. BG expiration cancels this too.
    private var activeTask: Task<Void, Never>?
    /// Fired on the main actor after a sync run completes (success or
    /// failure). Used by `GalleryStore` to re-merge fresh sidecar data into
    /// live `allPhotos` so tags/country codes surface without a rescan.
    var onFinished: (@MainActor () -> Void)?

    init(cache: SidecarCacheStore) {
        self.cache = cache
    }

    // MARK: - Diff buckets

    struct DiffResult: Equatable, Sendable {
        var needsFetch: [SidecarCandidate]
        var orphans: Set<UUID>
        var upToDate: Int
    }

    /// Diff the manifest against the cache. `orphans` are cached photo IDs
    /// that do not appear in the manifest — sidecar deleted, or a listing
    /// gap. Callers must not treat them as deletions unless `Listing` says
    /// the walk was complete.
    func diff(
        manifest: [SidecarCandidate],
        knownPhotoIDs: Set<UUID>
    ) -> DiffResult {
        var needsFetch: [SidecarCandidate] = []
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

        let orphans = knownPhotoIDs.subtracting(manifestIDs)
        return DiffResult(needsFetch: needsFetch, orphans: orphans, upToDate: upToDate)
    }

    /// Apply background hard caps. Oversized files are skipped; files that
    /// would blow the remaining byte budget are skipped so a later smaller
    /// candidate can still fit. Count is a hard stop.
    nonisolated static func applyLimits(
        _ candidates: [SidecarCandidate],
        policy: SyncPolicy
    ) -> [SidecarCandidate] {
        guard policy.maxCount != nil || policy.maxTotalBytes != nil || policy.maxFileBytes != nil else {
            return candidates
        }
        var accepted: [SidecarCandidate] = []
        var total: Int64 = 0
        for candidate in candidates {
            if let maxCount = policy.maxCount, accepted.count >= maxCount { break }
            let size = candidate.currentVersion.size ?? 0
            if let maxFile = policy.maxFileBytes, size > maxFile { continue }
            if let maxTotal = policy.maxTotalBytes, total + size > maxTotal { continue }
            accepted.append(candidate)
            total += size
        }
        return accepted
    }

    /// Drop cache entries that a complete listing (or a confirmed re-probe)
    /// has shown are gone. Incomplete listings only drop photo-orphans and
    /// `confirmedGone` IDs — cache under failed directories stays.
    /// Returns whether any entry was removed, so a fetch-less run can still
    /// re-merge and retract live tags.
    @discardableResult
    func retractCache(
        manifest: [SidecarCandidate],
        allPhotoIDs: Set<UUID>,
        listing: Listing
    ) -> Bool {
        let before = cache.count
        for id in listing.confirmedGone {
            cache.remove(id)
        }
        if listing.isComplete {
            cache.gc(keeping: Set(manifest.map(\.photoID)))
        } else {
            cache.gc(keeping: allPhotoIDs)
        }
        return cache.count != before
    }

    // MARK: - Drive a sync run

    /// Diff the manifest against the cache. If the fetch pile is small,
    /// kick off the sync immediately and return. If it crosses a threshold,
    /// move into `.awaitingPrompt` and wait for `confirmPrompt(_:)`.
    ///
    /// Fire-and-forget: the fetch runs on `activeTask`. Background callers
    /// that must not complete the `BGAppRefreshTask` until the work settles
    /// should use `planAndRun` instead.
    func plan(
        manifest: [SidecarCandidate],
        allPhotoIDs: Set<UUID>,
        autoApprove: Bool,
        policy: SyncPolicy = .foreground,
        listing: Listing = .incomplete
    ) {
        let prepared = prepare(
            manifest: manifest,
            allPhotoIDs: allPhotoIDs,
            autoApprove: autoApprove,
            policy: policy,
            listing: listing
        )
        switch prepared {
        case .idle:
            state = .idle
        case .prompt(let count, let bytes):
            state = .awaitingPrompt(count: count, bytes: bytes)
        case .fetch(let candidates, let policy):
            beginFetch(candidates, policy: policy)
        }
    }

    /// Plan and await the fetch (or return once there is nothing to do, or
    /// a prompt is required). Cancellation of the caller cancels the fetch
    /// and this function returns after in-flight coordinated reads settle
    /// or time out.
    func planAndRun(
        manifest: [SidecarCandidate],
        allPhotoIDs: Set<UUID>,
        autoApprove: Bool,
        policy: SyncPolicy = .foreground,
        listing: Listing = .incomplete
    ) async {
        let prepared = prepare(
            manifest: manifest,
            allPhotoIDs: allPhotoIDs,
            autoApprove: autoApprove,
            policy: policy,
            listing: listing
        )
        switch prepared {
        case .idle:
            state = .idle
        case .prompt(let count, let bytes):
            state = .awaitingPrompt(count: count, bytes: bytes)
        case .fetch(let candidates, let policy):
            await runFetchAndWait(candidates, policy: policy)
        }
    }

    /// User responded to the threshold prompt.
    func confirmPrompt(_ approved: Bool, manifest: [SidecarCandidate], policy: SyncPolicy = .foreground) {
        guard case .awaitingPrompt = state else { return }
        guard approved else {
            state = .idle
            return
        }
        let result = diff(manifest: manifest, knownPhotoIDs: cache.allPhotoIDs)
        beginFetch(Self.applyLimits(result.needsFetch, policy: policy), policy: policy)
    }

    func cancel() {
        activeTask?.cancel()
    }

    // MARK: - Prepare

    private enum Prepared {
        case idle
        case prompt(count: Int, bytes: Int64)
        case fetch([SidecarCandidate], SyncPolicy)
    }

    private func prepare(
        manifest: [SidecarCandidate],
        allPhotoIDs: Set<UUID>,
        autoApprove: Bool,
        policy: SyncPolicy,
        listing: Listing
    ) -> Prepared {
        let retracted = retractCache(manifest: manifest, allPhotoIDs: allPhotoIDs, listing: listing)

        let result = diff(manifest: manifest, knownPhotoIDs: cache.allPhotoIDs)
        let capped = Self.applyLimits(result.needsFetch, policy: policy)
        let totalBytes = capped.reduce(Int64(0)) { $0 + ($1.currentVersion.size ?? 0) }
        Log.cache.info(
            "Sidecar diff: \(result.needsFetch.count) to fetch (\(capped.count) after limits), \(result.upToDate) up to date, \(result.orphans.count) manifest-missing"
        )

        guard !capped.isEmpty else {
            // A listing that only deleted sidecars still has to reach the
            // live photo list — otherwise tags linger until the next fetch.
            if retracted { onFinished?() }
            return .idle
        }

        let needsPrompt = !autoApprove
            && (capped.count >= Self.promptThresholdCount
                || totalBytes >= Self.promptThresholdBytes)

        if needsPrompt {
            return .prompt(count: capped.count, bytes: totalBytes)
        }
        return .fetch(capped, policy)
    }

    // MARK: - Fetch loop

    private func beginFetch(_ candidates: [SidecarCandidate], policy: SyncPolicy) {
        let total = candidates.count
        guard total > 0 else { state = .idle; return }
        activeTask?.cancel()
        let task = Task { [weak self] in
            await self?.performFetch(candidates, policy: policy)
        }
        activeTask = task
    }

    private func runFetchAndWait(_ candidates: [SidecarCandidate], policy: SyncPolicy) async {
        let total = candidates.count
        guard total > 0 else { state = .idle; return }
        activeTask?.cancel()
        let task = Task { [weak self] in
            await self?.performFetch(candidates, policy: policy)
        }
        activeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performFetch(_ candidates: [SidecarCandidate], policy: SyncPolicy) async {
        let total = candidates.count
        state = .syncing(done: 0, total: total)
        let cache = self.cache
        await Self.runFetch(
            candidates: candidates,
            cache: cache,
            policy: policy,
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

    /// Parallel TaskGroup fetch. Cancels propagate from `activeTask.cancel()`.
    nonisolated private static func runFetch(
        candidates: [SidecarCandidate],
        cache: SidecarCacheStore,
        policy: SyncPolicy,
        progress: @MainActor @escaping (Int) -> Void,
        done: @MainActor @escaping (Int, Int) -> Void
    ) async {
        let limiter = AsyncSemaphore(limit: policy.concurrency)
        var doneCount = 0
        var succeeded = 0
        var failed = 0

        await withTaskGroup(of: (UUID, SidecarCacheStore.CachedSidecar?).self) { group in
            for candidate in candidates {
                if Task.isCancelled { break }
                await limiter.acquire()
                if Task.isCancelled {
                    await limiter.release()
                    break
                }
                group.addTask {
                    defer { Task { await limiter.release() } }
                    let result = await fetchOne(candidate, policy: policy)
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
    /// (provider error, parse error, file vanished mid-fetch, timeout, over
    /// the per-file byte cap). An *empty* successful parse is a real result
    /// — tags/country/faces come back empty so the cache can retract.
    nonisolated private static func fetchOne(
        _ candidate: SidecarCandidate,
        policy: SyncPolicy
    ) async -> SidecarCacheStore.CachedSidecar? {
        let url = candidate.sidecarURL
        do {
            let data = try await coordinatedSidecarRead(at: url)
            if let maxFile = policy.maxFileBytes, data.count > maxFile {
                Log.cache.error(
                    "Sidecar over per-file cap for \(Log.r.filename(url.lastPathComponent)): \(data.count) bytes"
                )
                return nil
            }
            // The core owns the XMP parser now — same code the scanner and
            // the enrichment pass run, so a sidecar fetched from a provider
            // and a sidecar read off disk can never disagree.
            let parsed = parseXmpBytes(bytes: data)

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
                faceRegions: parsed.faceRegions.map {
                    FaceRegion(name: $0.name, centerX: $0.centerX, centerY: $0.centerY,
                               width: $0.width, height: $0.height)
                }
            )
        } catch {
            Log.cache.error("Sidecar fetch failed for \(Log.r.filename(url.lastPathComponent)): \(Log.r.error(error))")
            return nil
        }
    }

    /// Race a coordinated read against `fileReadTimeout`. The loser is
    /// abandoned — `NSFileCoordinator` cannot be cancelled — so a hung
    /// provider cannot pin the caller. The continuation is resumed once.
    nonisolated static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = OnceResume(continuation)
            let timeoutTask = Task {
                try await Task.sleep(for: timeout)
                box.resume(throwing: ReadError.timeout)
            }
            Task {
                do {
                    let value = try await operation()
                    timeoutTask.cancel()
                    box.resume(returning: value)
                } catch {
                    timeoutTask.cancel()
                    box.resume(throwing: error)
                }
            }
        }
    }

    nonisolated static func coordinatedSidecarRead(at url: URL) async throws -> Data {
        try await withTimeout(fileReadTimeout) {
            try await coordinatedSidecarReadUnbound(at: url)
        }
    }

    nonisolated private static func coordinatedSidecarReadUnbound(at url: URL) async throws -> Data {
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

/// One-shot resume box so a timeout and a finishing read cannot both
/// resume the same continuation.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}
