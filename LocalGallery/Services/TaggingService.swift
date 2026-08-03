import Foundation
import Observation
import os

/// On-device photo tagging: owns the Rust core's `TaggingSession` and feeds
/// its results back into the app through the *existing* sidecar pipeline.
///
/// The core writes `Objects/…` / `Scenes/…` keywords into each photo's `.xmp`
/// sidecar. Nothing reads those tags out of the core — they come back the same
/// way digiKam's do, which is the whole point of Phase 1: the feature is
/// additive and the read path is untouched.
///
/// ## How results surface
///
/// A tagging run creates sidecar files the last scan never saw, so neither
/// `SidecarCacheStore` nor `GalleryStore.lastSidecarManifest` knows about them
/// and `reapplySidecarMerges()` alone would find nothing. The narrowest
/// existing trigger that *does* pick them up is a **light rescan**: it walks
/// the tree (reusing cached `PhotoFile`s, so it costs one stat per file and no
/// EXIF), emits a fresh sidecar manifest that includes the new `.xmp` files,
/// and `performScan` then hands that manifest to `SidecarSyncService` →
/// `onFinished` → `reapplySidecarMerges()` → tags/indexes/widget. See
/// `refreshTaggedPhotos()`.
///
/// Rescans are coalesced (`refreshInterval`) so a 20k-photo run doesn't kick
/// off a tree walk every 32 photos.
@Observable
@MainActor
final class TaggingService {
    /// Minimum spacing between the incremental rescans triggered by
    /// `onPhotosTagged` batches. The run always ends with one final refresh,
    /// so this only controls how soon partial results appear.
    static let refreshInterval: TimeInterval = 30

    /// Live progress of a run. `nil` when idle.
    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// What a finished run did. A Sendable mirror of the FFI's
    /// `TaggingRunSummary` — the generated record isn't `Sendable`, and this
    /// value crosses from a core worker thread to the main actor.
    struct Summary: Equatable, Sendable {
        var processed = 0
        var tagged = 0
        var sidecarsWritten = 0
        var cacheHits = 0
        var skipped = 0
        var failed = 0
        var cancelled = false
        var failure: TaggingServiceError?
    }

    /// The installed model pack, as Settings renders it.
    struct PackStatus: Equatable, Sendable {
        var version: String
        var labelCount: Int
        var directory: URL
    }

    // MARK: - Observed state

    /// The verified model pack, or `nil` when none is installed (or the
    /// installed one failed verification — see `lastError`).
    private(set) var pack: PackStatus?
    private(set) var isRunning = false
    private(set) var progress: Progress?
    private(set) var lastSummary: Summary?
    /// Last failure worth showing the user (import, open, or run).
    private(set) var lastError: TaggingServiceError?
    /// False until `refreshAvailability()` has looked at the disk once, so
    /// Settings can render "Checking…" instead of flashing "No model pack".
    private(set) var hasCheckedForPack = false

    /// Tagging can run.
    var isAvailable: Bool { pack != nil }

    // MARK: - Injected

    @ObservationIgnored private let cacheDatabaseURL: URL
    @ObservationIgnored private let modelPacksDirectory: URL
    /// Supplies the photos a run should consider. Set by `GalleryStore` so the
    /// service never holds a reference back to the Store.
    @ObservationIgnored var eligiblePhotos: (@MainActor () -> [PhotoFile])?
    /// Called when freshly written sidecars need to be pulled into the app.
    /// `GalleryStore` wires this to a light rescan.
    @ObservationIgnored var onSidecarsWritten: (@MainActor () async -> Void)?

    /// Open session. Held across runs: it owns the ONNX sessions and the
    /// SQLite connection, both of which are expensive to build.
    @ObservationIgnored private var session: TaggingSession?
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(cacheDatabaseURL: URL, modelPacksDirectory: URL) {
        self.cacheDatabaseURL = cacheDatabaseURL
        self.modelPacksDirectory = modelPacksDirectory
    }

    // MARK: - Model pack

    /// Look for an installed pack and verify it. Safe to call repeatedly; the
    /// hash verification is the same one the core does at session open, so a
    /// pack that passes here will not fail later for a different reason.
    func refreshAvailability() async {
        defer { hasCheckedForPack = true }
        guard let dir = Self.newestPackDirectory(in: modelPacksDirectory) else {
            pack = nil
            return
        }
        do {
            pack = try await Self.inspect(dir)
            Log.ml.info("Model pack \(self.pack?.version ?? "?") ready (\(self.pack?.labelCount ?? 0) labels)")
        } catch {
            pack = nil
            lastError = TaggingServiceError(error)
            Log.ml.error("Model pack at \(Log.r.path(dir)) rejected: \(Log.r.error(error))")
        }
    }

    /// Copy a user-picked pack directory into `ModelPacks/` and verify it.
    ///
    /// Validation happens *after* the copy, against the installed location, so
    /// a pack that only verifies on the source volume (partial download, lazy
    /// cloud placeholder) is rejected rather than half-installed. A rejected
    /// pack is removed again.
    func importModelPack(from source: URL) async {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Tear the session down first — it holds the old pack's files open,
        // and a replaced pack must not keep tagging under the old version.
        session = nil

        let destination = modelPacksDirectory
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: modelPacksDirectory, withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            lastError = .io(error.localizedDescription)
            Log.ml.error("Model pack copy failed: \(Log.r.error(error))")
            return
        }

        do {
            pack = try await Self.inspect(destination)
            lastError = nil
            hasCheckedForPack = true
            Log.ml.info("Imported model pack \(self.pack?.version ?? "?")")
        } catch {
            try? FileManager.default.removeItem(at: destination)
            pack = nil
            hasCheckedForPack = true
            lastError = TaggingServiceError(error)
            Log.ml.error("Imported model pack rejected: \(Log.r.error(error))")
        }
    }

    /// Newest (by name, descending) subdirectory that looks like a pack.
    ///
    /// Name order rather than mtime: pack directories are named for their
    /// version, and a copy's mtime says when it was installed, not which
    /// version it is.
    private nonisolated static func newestPackDirectory(in root: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && FileManager.default.fileExists(
                        atPath: url.appendingPathComponent("manifest.json").path
                    )
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    /// SHA-256-verify a pack directory off the main actor.
    private nonisolated static func inspect(_ dir: URL) async throws -> PackStatus {
        // `Task.detached`: verification reads (and hashes) the whole ONNX file
        // — tens of MB for a real pack. `PackStatus` is Sendable; the FFI's
        // `ModelPackInfo` is not, so the conversion happens inside.
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PackStatus, TaggingServiceError> in
            do {
                let info = try inspectModelPack(modelPackDir: dir.path)
                return .success(PackStatus(
                    version: info.version,
                    labelCount: Int(info.labelCount),
                    directory: dir
                ))
            } catch {
                return .failure(TaggingServiceError(error))
            }
        }.value
        return try result.get()
    }

    // MARK: - Running

    /// Enqueue every eligible photo and start a run.
    ///
    /// No-op when a run is already in flight or no pack is installed.
    func startTagging() async {
        guard !isRunning, let pack else { return }
        let photos = (eligiblePhotos?() ?? []).filter(Self.isEligible)
        guard !photos.isEmpty else {
            lastSummary = Summary()
            return
        }
        let paths = photos.map(\.url.standardizedFileURL.path)

        isRunning = true
        progress = Progress(done: 0, total: paths.count)
        lastError = nil

        let session: TaggingSession
        do {
            session = try await openSession(packDirectory: pack.directory)
        } catch {
            isRunning = false
            progress = nil
            lastError = TaggingServiceError(error)
            Log.ml.error("Tagging session failed to open: \(Log.r.error(error))")
            return
        }

        do {
            let inserted = try await Self.enqueue(paths, into: session)
            Log.ml.info("Enqueued \(paths.count) photos (\(inserted) new)")
        } catch {
            isRunning = false
            progress = nil
            lastError = TaggingServiceError(error)
            Log.ml.error("Enqueue failed: \(Log.r.error(error))")
            return
        }

        let bridge = ProgressBridge(
            progress: { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.progress = Progress(done: done, total: total)
                }
            },
            tagged: { [weak self] count in
                Task { @MainActor [weak self] in
                    self?.noteSidecarsWritten(count)
                }
            },
            finished: { [weak self] summary in
                Task { @MainActor [weak self] in
                    await self?.finish(summary)
                }
            }
        )

        do {
            try session.start(progress: bridge)
        } catch {
            isRunning = false
            progress = nil
            lastError = TaggingServiceError(error)
            Log.ml.error("Tagging run failed to start: \(Log.r.error(error))")
        }
    }

    /// Ask the core to stop. `onFinished` still fires, with `cancelled` set.
    func cancel() {
        session?.cancel()
    }

    /// Drop every queue row so the next run re-tags the library. Cached
    /// embeddings survive, so a re-tag after a threshold change is cheap.
    func resetQueue() {
        guard !isRunning else { return }
        do {
            try session?.resetQueue()
        } catch {
            lastError = TaggingServiceError(error)
        }
    }

    private func noteSidecarsWritten(_ count: Int) {
        Log.ml.debug("\(count) sidecars written")
        let now = Date()
        if let last = lastRefreshAt, now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastRefreshAt = now
        scheduleRefresh()
    }

    private func finish(_ summary: Summary) async {
        isRunning = false
        progress = nil
        lastSummary = summary
        if let failure = summary.failure {
            lastError = failure
            Log.ml.error("Tagging run failed: \(String(describing: failure))")
        } else {
            Log.ml.info(
                "Tagging run: \(summary.processed) processed, \(summary.tagged) tagged, \(summary.sidecarsWritten) sidecars, \(summary.cacheHits) cache hits, \(summary.failed) failed, cancelled=\(summary.cancelled)"
            )
        }
        // Always refresh on finish, even when nothing was written this batch —
        // an earlier batch's rescan may have been coalesced away.
        lastRefreshAt = Date()
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Coalesce refreshes: a rescan already in flight is left to finish rather
    /// than queued behind another one.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.onSidecarsWritten?()
            self?.refreshTask = nil
        }
    }

    // MARK: - Eligibility

    /// The photos a run should consider.
    ///
    /// Mirrors the enrichment rule — a file-provider placeholder has no bytes
    /// to hash, decode, or write a sidecar next to, and asking the core to try
    /// would burn a retry per photo. Videos are out of scope for v1 (the core
    /// has no frame sampler on iOS).
    nonisolated static func isEligible(_ photo: PhotoFile) -> Bool {
        guard !photo.isVideo else { return false }
        if case .remote(downloaded: false) = photo.locality { return false }
        return true
    }

    // MARK: - Off-actor plumbing

    private func openSession(packDirectory: URL) async throws -> TaggingSession {
        if let session { return session }
        let cacheURL = cacheDatabaseURL
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let opened = try await Task.detached(priority: .userInitiated) {
            () -> Result<TaggingSession, TaggingServiceError> in
            do {
                return .success(try TaggingSession(
                    cacheDbPath: cacheURL.path,
                    modelPackDir: packDirectory.path
                ))
            } catch {
                return .failure(TaggingServiceError(error))
            }
        }.value.get()
        session = opened
        return opened
    }

    private nonisolated static func enqueue(
        _ paths: [String], into session: TaggingSession
    ) async throws -> Int {
        try await Task.detached(priority: .utility) { () -> Result<Int, TaggingServiceError> in
            do {
                return .success(Int(try session.enqueue(paths: paths)))
            } catch {
                return .failure(TaggingServiceError(error))
            }
        }.value.get()
    }
}

// MARK: - Progress bridge

/// Forwards the core's worker-thread callbacks to the main actor.
///
/// `TaggingProgressListener` requires `Sendable`, and this satisfies it
/// honestly rather than with `@unchecked`: the only stored state is three
/// immutable `@Sendable` closures, so there is nothing to race.
private final class ProgressBridge: TaggingProgressListener, Sendable {
    private let progressHandler: @Sendable (Int, Int) -> Void
    private let taggedHandler: @Sendable (Int) -> Void
    private let finishedHandler: @Sendable (TaggingService.Summary) -> Void

    init(
        progress: @escaping @Sendable (Int, Int) -> Void,
        tagged: @escaping @Sendable (Int) -> Void,
        finished: @escaping @Sendable (TaggingService.Summary) -> Void
    ) {
        self.progressHandler = progress
        self.taggedHandler = tagged
        self.finishedHandler = finished
    }

    func onProgress(done: UInt32, total: UInt32) {
        progressHandler(Int(done), Int(total))
    }

    func onPhotosTagged(paths: [String]) {
        // Only the count crosses: the app re-reads the sidecars through the
        // scanner anyway, so the paths would be dead weight on the main actor.
        taggedHandler(paths.count)
    }

    func onFinished(summary: TaggingRunSummary) {
        finishedHandler(TaggingService.Summary(
            processed: Int(summary.processed),
            tagged: Int(summary.tagged),
            sidecarsWritten: Int(summary.sidecarsWritten),
            cacheHits: Int(summary.cacheHits),
            skipped: Int(summary.skipped),
            failed: Int(summary.failed),
            cancelled: summary.cancelled,
            failure: summary.failure.map(TaggingServiceError.init)
        ))
    }
}

// MARK: - Errors

/// App-facing tagging failure.
///
/// A `Sendable` restatement of the FFI's `TaggingError` (the generated enum
/// isn't `Sendable`, and these values cross from core threads to the main
/// actor). The detail strings are for logs and the Settings error line; the
/// *case* is what code switches on.
enum TaggingServiceError: Error, Sendable, Equatable {
    case noModelPack
    case pack(String)
    case cache(String)
    case inference(String)
    case io(String)
    case sidecar(String)
    case alreadyRunning
    case cancelled

    init(_ error: any Error) {
        guard let e = error as? TaggingError else {
            self = .io(error.localizedDescription)
            return
        }
        switch e {
        case .PackFileMissing(let path):
            self = .pack("missing file: \(path)")
        case .PackHashMismatch(let file, _, _):
            self = .pack("\(file) does not match its manifest hash")
        case .PackInvalid(let detail):
            self = .pack(detail)
        case .Cache(let detail):
            self = .cache(detail)
        case .Inference(let detail):
            self = .inference(detail)
        case .Io(_, let detail):
            self = .io(detail)
        case .Sidecar(let detail):
            self = .sidecar(detail)
        case .Cancelled:
            self = .cancelled
        case .AlreadyRunning:
            self = .alreadyRunning
        }
    }

    init(_ failure: TaggingFailure) {
        switch failure {
        case .pack: self = .pack("model pack could not be used")
        case .cacheDb: self = .cache("cache database error")
        case .inference: self = .inference("inference failed")
        case .io: self = .io("file access failed")
        case .sidecar: self = .sidecar("sidecar write failed")
        case .cancelled: self = .cancelled
        }
    }

    /// One line, safe to show in Settings.
    var message: String {
        switch self {
        case .noModelPack: return "No model pack installed."
        case .pack(let d): return "Model pack problem: \(d)"
        case .cache(let d): return "Tagging cache problem: \(d)"
        case .inference(let d): return "Inference failed: \(d)"
        case .io(let d): return "File error: \(d)"
        case .sidecar(let d): return "Sidecar write failed: \(d)"
        case .alreadyRunning: return "Tagging is already running."
        case .cancelled: return "Tagging was cancelled."
        }
    }
}
