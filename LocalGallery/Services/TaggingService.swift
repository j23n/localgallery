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
/// `onFinished` → `reapplySidecarMerges()` → tags/indexes/widget.
///
/// Rescans are coalesced and drained by `SidecarRefreshCoalescer`, which
/// `FaceService` shares — the rules are identical and the drain half is subtle
/// enough that having one copy matters.
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

    /// What a finished run did.
    ///
    /// A small app-facing restatement of the FFI's `TaggingRunSummary` (which
    /// is itself `Sendable`): this one carries `TaggingServiceError` rather
    /// than `TaggingFailure`, so Settings has a single error type to render.
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
    ///
    /// Also the single answer to "is there a pack, and what can it do" for the
    /// whole app: `FaceService` reads `hasFaces` off this rather than
    /// discovering and SHA-256-verifying the same directory a second time.
    struct PackStatus: Equatable, Sendable {
        var version: String
        var labelCount: Int
        /// Whether the pack ships the two face models (manifest schema 2). A
        /// tagging-only pack is valid — this is the cue to hide the faces
        /// controls, not to report a problem.
        var hasFaces: Bool
        var directory: URL
        /// Which of the two locations this pack was resolved from. Settings
        /// shows it, and it is what makes "Remove" removable — only an
        /// imported pack can be deleted.
        var source: PackResolver.Source
    }

    /// Cheap identity of an installed pack: where it is, plus its manifest's
    /// size and mtime.
    ///
    /// Full verification SHA-256s the whole ONNX — 40–150 MB for a real pack,
    /// seconds of work — and Settings' `.task` fires on *every* appearance of
    /// the screen. A pack directory is immutable in practice (import replaces
    /// it wholesale), so a matching fingerprint means the bytes already
    /// verified are still the bytes on disk. The real guarantee is untouched
    /// either way: the core re-verifies every declared hash at session open,
    /// so nothing is ever *used* unverified.
    private struct PackFingerprint: Equatable {
        var directory: URL
        var manifestSize: Int
        var manifestModified: Date
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
    /// Whether this build ships a pack at all.
    ///
    /// It should: `scripts/prepare_pack.sh` stages one and the build fails
    /// loudly without it. So "no pack" means either a build that skipped that
    /// step or a bundled pack that failed verification — neither of which the
    /// user can fix by importing, which is why Settings words the two states
    /// differently.
    private(set) var hasBundledPack = false

    /// Tagging can run.
    var isAvailable: Bool { pack != nil }

    // MARK: - Injected

    @ObservationIgnored private let cacheDatabaseURL: URL
    @ObservationIgnored private let modelPacksDirectory: URL
    /// The pack inside the app bundle, if this build has one.
    @ObservationIgnored private let bundledPackDirectory: URL?
    /// Supplies the photos a run should consider. Set by `GalleryStore` so the
    /// service never holds a reference back to the Store.
    @ObservationIgnored var eligiblePhotos: (@MainActor () -> [PhotoFile])?
    /// The library root a run is confined to.
    ///
    /// The core's cache DB is one file per app, keyed by absolute path, so it
    /// outlives any one library root. Without this a run would pick up rows
    /// enqueued under a folder the user has since switched away from and write
    /// sidecars outside the library on screen.
    @ObservationIgnored var libraryRoot: (@MainActor () -> URL?)?
    /// Called when freshly written sidecars need to be pulled into the app.
    /// `GalleryStore` wires this to a light rescan.
    @ObservationIgnored var onSidecarsWritten: (@MainActor () async -> Void)? {
        get { refresh.onRefresh }
        set { refresh.onRefresh = newValue }
    }
    /// Called before an import replaces the installed pack. `GalleryStore`
    /// wires this to `FaceService`, which holds the *same* pack's face models
    /// open in its own session and would otherwise keep scanning under the
    /// version the user has just replaced.
    @ObservationIgnored var onPackWillChange: (@MainActor () async -> Void)?

    /// Open session. Held across runs: it owns the ONNX sessions and the
    /// SQLite connection, both of which are expensive to build.
    @ObservationIgnored private var session: TaggingSession?
    /// Which pack `session` was opened against, so a pack change reopens it
    /// instead of quietly tagging under the old one.
    @ObservationIgnored private var sessionPackDirectory: URL?
    /// The in-flight `openSession`, and the pack it is opening, so concurrent
    /// callers share one. See `openSession` for what two of them cost, and
    /// `FaceService` for why the slot is keyed by directory.
    @ObservationIgnored private var opening: (directory: URL, task: Task<TaggingSession, any Error>)?
    /// Coalesces + drains the rescans a run's sidecar writes trigger. Injected,
    /// and **shared with `FaceService`**: the interval is a budget for
    /// interrupting the user with a rescan, and two engines each spending it
    /// separately is two rescans, which is what the window exists to prevent.
    @ObservationIgnored private let refresh: SidecarRefreshCoalescer
    /// When a refresh last actually ran. Internal so `TaggingServiceTests`
    /// can assert that a *suppressed* batch does not move it.
    @ObservationIgnored var lastRefreshAt: Date? { refresh.lastRefreshAt }
    /// The in-flight refresh, for callers that need to await it.
    @ObservationIgnored var refreshTask: Task<Void, Never>? { refresh.task }
    /// `cancel()` arrived before the core had a run to cancel.
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var verifiedPack: PackFingerprint?

    init(
        cacheDatabaseURL: URL,
        modelPacksDirectory: URL,
        bundledPackDirectory: URL?,
        refresh: SidecarRefreshCoalescer
    ) {
        self.cacheDatabaseURL = cacheDatabaseURL
        self.modelPacksDirectory = modelPacksDirectory
        self.bundledPackDirectory = bundledPackDirectory
        self.refresh = refresh
    }

    // MARK: - Model pack

    /// Look for an installed pack and verify it.
    ///
    /// Safe (and cheap) to call repeatedly: a pack whose manifest has not
    /// changed since the last successful verification is taken at its word
    /// rather than re-hashed. Pass `force` to re-verify regardless.
    func refreshAvailability(force: Bool = false) async {
        defer { hasCheckedForPack = true }
        let bundled = PackResolver.candidates(in: bundledPackDirectory)
        hasBundledPack = !bundled.isEmpty
        guard let resolved = PackResolver.resolve(
            bundled: bundled,
            imported: PackResolver.candidates(in: modelPacksDirectory)
        ) else {
            pack = nil
            verifiedPack = nil
            return
        }
        let dir = resolved.directory
        let fingerprint = Self.fingerprint(of: dir)
        if !force, pack != nil, let verifiedPack, let fingerprint, verifiedPack == fingerprint {
            return
        }
        do {
            pack = try await Self.inspect(resolved)
            verifiedPack = fingerprint
            Log.ml.info("Model pack \(self.pack?.version ?? "?") ready (\(self.pack?.labelCount ?? 0) labels, \(resolved.source.label.lowercased()))")
        } catch {
            pack = nil
            verifiedPack = nil
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

        // Tear the sessions down first — they hold the old pack's files open,
        // and a replaced pack must not keep tagging (or detecting) under the
        // old version. Off the main actor: releasing a session joins the core's
        // run thread.
        await releaseSession()
        await onPackWillChange?()

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

        verifiedPack = nil
        do {
            _ = try await Self.inspect(
                PackResolver.Resolution(directory: destination, source: .imported)
            )
            lastError = nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = TaggingServiceError(error)
            Log.ml.error("Imported model pack rejected: \(Log.r.error(error))")
            // Whatever was installed before is still installed, so re-resolve
            // rather than leaving the app pack-less over a bad import.
            await refreshAvailability(force: true)
            return
        }
        // *Which* pack is active is the resolver's call, not the import's: a
        // pack older than the bundled one is installed but does not win.
        await refreshAvailability(force: true)
        Log.ml.info("Imported model pack; active pack is \(self.pack?.version ?? "none")")
    }

    /// Delete the imported pack and fall back to whatever else resolves —
    /// normally the one in the app bundle.
    ///
    /// The undo for an import, so it removes the *active* imported pack rather
    /// than every pack ever installed. Refused during a run: the session holds
    /// the directory's files open.
    func removeImportedPack() async {
        guard !isRunning else { return }
        guard let installed = pack, installed.source == .imported else { return }
        // Same reasoning as `importModelPack`: the sessions hold this pack's
        // weights, and faces holds its own copy of them.
        await releaseSession()
        await onPackWillChange?()
        do {
            try FileManager.default.removeItem(at: installed.directory)
        } catch {
            lastError = .io(error.localizedDescription)
            Log.ml.error("Removing the imported model pack failed: \(Log.r.error(error))")
            return
        }
        pack = nil
        verifiedPack = nil
        lastError = nil
        await refreshAvailability(force: true)
        Log.ml.info("Removed the imported model pack; active pack is \(self.pack?.version ?? "none")")
    }

    /// Size + mtime of `dir/manifest.json`, or `nil` when it cannot be read
    /// (in which case nothing is cached and the next check re-verifies).
    private nonisolated static func fingerprint(of dir: URL) -> PackFingerprint? {
        let manifest = dir.appendingPathComponent("manifest.json")
        guard
            let values = try? manifest.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ),
            let size = values.fileSize,
            let modified = values.contentModificationDate
        else { return nil }
        return PackFingerprint(directory: dir, manifestSize: size, manifestModified: modified)
    }

    /// SHA-256-verify a pack directory off the main actor.
    private nonisolated static func inspect(
        _ resolved: PackResolver.Resolution
    ) async throws -> PackStatus {
        // `Task.detached`: verification reads (and hashes) the whole ONNX file
        // — 143 MB for the bundled pack. Once per install, since the
        // fingerprint below is keyed on the manifest's size and mtime.
        let dir = resolved.directory
        let source = resolved.source
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PackStatus, TaggingServiceError> in
            do {
                let info = try inspectModelPack(modelPackDir: dir.path)
                return .success(PackStatus(
                    version: info.version,
                    labelCount: Int(info.labelCount),
                    hasFaces: info.hasFaces,
                    directory: dir,
                    source: source
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
    /// No-op when a run is already in flight.
    func startTagging() async {
        guard !isRunning else { return }
        guard let pack else {
            lastError = .noModelPack
            return
        }
        let photos = (eligiblePhotos?() ?? []).filter(Self.isEligible)
        guard !photos.isEmpty else {
            lastSummary = Summary()
            return
        }
        let paths = photos.map(\.url.standardizedFileURL.path)
        let rootPrefix = libraryRoot?()?.standardizedFileURL.path

        isRunning = true
        cancelRequested = false
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

        // Opening the session and enqueueing a 20k-photo library both take
        // long enough for the user to reach Cancel, and until `start` there is
        // no run for `session.cancel()` to reach — the core clears its own
        // cancel flag inside `start` anyway. So the request is honoured here,
        // by not starting.
        if cancelRequested {
            cancelRequested = false
            isRunning = false
            progress = nil
            lastSummary = Summary(cancelled: true)
            Log.ml.info("Tagging cancelled before the run started")
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
            try session.start(progress: bridge, rootPrefix: rootPrefix)
        } catch {
            isRunning = false
            progress = nil
            lastError = TaggingServiceError(error)
            Log.ml.error("Tagging run failed to start: \(Log.r.error(error))")
        }
    }

    /// Ask the core to stop. `onFinished` still fires, with `cancelled` set.
    ///
    /// Also covers the window before the run exists — see `startTagging`.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        session?.cancel()
    }

    /// Drop every queue row so the next run re-tags the library, and forget
    /// the last run's summary.
    ///
    /// Cached embeddings survive, so a re-tag after a threshold change is
    /// cheap. This is the recovery action for a queue that has got itself
    /// stuck: rows failed out of their retry budget, or paths belonging to a
    /// library root the user has moved away from.
    ///
    /// Opens the session if one isn't already open — the recovery case is
    /// precisely the one where the user has not started a run this launch.
    func resetQueue() async {
        guard !isRunning else { return }
        guard let pack else {
            lastError = .noModelPack
            return
        }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            try session.resetQueue()
            lastSummary = nil
            lastError = nil
            Log.ml.info("Tagging queue reset")
        } catch {
            lastError = TaggingServiceError(error)
            Log.ml.error("Tagging queue reset failed: \(Log.r.error(error))")
        }
    }

    /// One `onPhotosTagged` batch from the core. Internal rather than private
    /// so `TaggingServiceTests` can drive the coalescing rules without having
    /// to stage a whole run.
    func noteSidecarsWritten(_ count: Int) {
        Log.ml.debug("\(count) sidecars written")
        // Deliberately coalesced: a 20k-photo run must not walk the tree every
        // 32 photos. Nothing is lost — `finish` refreshes unconditionally at
        // the end of the run.
        refresh.note()
    }

    private func finish(_ summary: Summary) async {
        isRunning = false
        cancelRequested = false
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
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Refresh now, regardless of the coalescing interval. Internal so tests
    /// can drive it directly; the end-of-run refresh in `finish` takes this
    /// same unconditional path.
    func scheduleRefresh() {
        refresh.schedule()
    }

    // MARK: - Eligibility

    /// The photos a run should consider.
    ///
    /// Mirrors the enrichment rule on placeholders — a file-provider
    /// placeholder has no bytes to hash, decode, or write a sidecar next to,
    /// and asking the core to try would burn a retry per photo. It *diverges*
    /// from enrichment on videos: enrichment reads a video's creation date
    /// happily, but the core has no frame sampler on iOS, so videos are out of
    /// scope for v1.
    nonisolated static func isEligible(_ photo: PhotoFile) -> Bool {
        guard !photo.isVideo else { return false }
        if case .remote(downloaded: false) = photo.locality { return false }
        return true
    }

    // MARK: - Off-actor plumbing

    /// The open session for `packDirectory`, opening one if there is none.
    ///
    /// The open is memoized as a `Task` so concurrent callers await the *same*
    /// one. Without that, two callers both saw `session == nil`, both built a
    /// session, and the second overwrote `self.session` — leaving the first
    /// holding the run that `cancel()` could no longer reach, plus a second
    /// ONNX load and a second connection to one SQLite file.
    private func openSession(packDirectory: URL) async throws -> TaggingSession {
        if let session, sessionPackDirectory == packDirectory { return session }
        if let opening, opening.directory == packDirectory {
            return try await opening.task.value
        }
        // A different pack than the open session's: that session holds the old
        // pack's ONNX weights and stamps its version into every sidecar, so
        // reusing it would tag under a pack the user has replaced.
        if session != nil { await releaseSession() }

        let cacheURL = cacheDatabaseURL
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let task = Task { @MainActor () -> TaggingSession in
            try await Task.detached(priority: .userInitiated) {
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
        }
        opening = (packDirectory, task)
        defer { if opening?.task == task { opening = nil } }
        let opened = try await task.value
        session = opened
        sessionPackDirectory = packDirectory
        return opened
    }

    /// Stop any in-flight run and release the session without blocking the
    /// main actor.
    ///
    /// The core's `TaggingSession` joins its run thread on `Drop`, and that
    /// thread can be a whole inference away from noticing. Dropping the last
    /// reference from a `@MainActor` method therefore freezes the UI for as
    /// long as one photo takes. Instead: cancel, wait for the core's own
    /// `isRunning` to clear **off** the actor, and only then let go — by which
    /// point the join is instant.
    private func releaseSession() async {
        guard let session else { return }
        session.cancel()
        await Task.detached(priority: .userInitiated) {
            // Cancellation is checked per item and once per 256 KiB of a
            // content hash, so this settles in well under a second.
            while session.isRunning() {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }.value
        self.session = nil
        self.sessionPackDirectory = nil
        isRunning = false
        cancelRequested = false
        progress = nil
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
/// A flattening of the FFI's `TaggingError` down to the cases the UI
/// distinguishes, plus `noModelPack`, which only this layer can detect. The
/// detail strings are for logs and the Settings error line; the *case* is what
/// code switches on.
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
        // Already classified. The off-actor helpers hand back
        // `Result<_, TaggingServiceError>` and their callers re-wrap whatever
        // `get()` throws, so without this a pack error arrives at Settings as
        // "File error: The operation couldn't be completed."
        if let classified = error as? TaggingServiceError {
            self = classified
            return
        }
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
