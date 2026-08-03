import Foundation
import Observation
import os

/// On-device face detection, clustering and naming: owns the Rust core's
/// `FaceSession` and feeds its results back through the *existing* sidecar
/// pipeline.
///
/// A sibling of `TaggingService` in every structural respect — session held
/// across runs, `cancelRequested` covering the window before a run exists,
/// off-actor open/release, root-scoped runs, the shared
/// `SidecarRefreshCoalescer` — and different in exactly one: the core's face
/// surface has calls that write to disk *without* being a run. Naming a
/// cluster, un-naming it, ignoring it and renaming a person all rewrite
/// sidecars, and all of them are refused by the core while a run is in flight.
/// So `isRunning` gates the review UI's buttons, not just its progress row.
///
/// ## How results surface
///
/// Exactly as tagging's do, and for the same reason: the core writes
/// `People/<Name>` keywords and `mwg-rs:RegionInfo` regions into `.xmp` files
/// the last scan never saw, so nothing in the app knows about them until a
/// **light rescan** rebuilds the sidecar manifest → `SidecarSyncService` →
/// `reapplySidecarMerges()` → tags/indexes/widget. `PeopleStore` then shows the
/// new person through the ordinary People machinery, with a face-region cover
/// crop, with no reader changes anywhere.
///
/// A run triggers that refresh from `onSidecarsWritten` (the auto-tag pass);
/// a naming action triggers it directly, because its whole point is that the
/// person appears now.
@Observable
@MainActor
final class FaceService {
    /// Minimum spacing between the rescans a run's sidecar batches trigger.
    /// Matches tagging's — the two are the same kind of interruption.
    static let refreshInterval: TimeInterval = 30

    /// How many faces an unlabeled cluster needs before it is worth asking the
    /// user about.
    ///
    /// Three. One- and two-face clusters are overwhelmingly the tail of any
    /// clustering pass — a passer-by, a photo on a wall, a bad crop — and
    /// putting them in the review queue turns a 20-card screen into a
    /// 400-card one nobody finishes. Three faces is the smallest group that
    /// says "this person recurs". Nothing is lost by waiting: a cluster grows
    /// as more photos are scanned and appears the moment it crosses the bar,
    /// and a cluster that never does is still reachable through
    /// `allClusters`.
    static let reviewMinimumFaces = 3

    /// Live progress of a run. `nil` when idle.
    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// What a finished run did. An app-facing restatement of the FFI's
    /// `FaceRunSummary`, carrying `FaceServiceError` rather than `FaceFailure`
    /// so Settings has one error type to render.
    struct Summary: Equatable, Sendable {
        var processed = 0
        var photosWithFaces = 0
        var facesFound = 0
        var cacheHits = 0
        var skipped = 0
        var failed = 0
        var facesAssigned = 0
        var clustersCreated = 0
        var facesAutoTagged = 0
        var sidecarsWritten = 0
        var cancelled = false
        var failure: FaceServiceError?
    }

    /// One face as the UI crops it: a photo plus the region within it.
    ///
    /// `region` is a `FaceRegion` — the same normalized centre/extent value the
    /// sidecar reader produces — so `PersonThumbnailView` renders one of these
    /// with no new code at all.
    struct Face: Equatable, Sendable, Identifiable {
        var url: URL
        var region: FaceRegion
        var quality: Double
        /// Stable within a cluster listing: a photo can hold two faces of the
        /// same person, so the path alone is not unique.
        var id: String { "\(url.path)#\(region.centerX),\(region.centerY)" }
    }

    /// One cluster, as the review grid renders it.
    struct Cluster: Equatable, Sendable, Identifiable {
        var id: Int64
        var size: Int
        var state: ClusterState
        /// The person's name when `state == .named`.
        var name: String?
        /// Up to four crops, best quality first, one per photo where possible.
        var exemplars: [Face]
    }

    // MARK: - Observed state

    private(set) var isRunning = false
    private(set) var progress: Progress?
    private(set) var lastSummary: Summary?
    private(set) var lastError: FaceServiceError?
    /// Every cluster the core knows about, refreshed by `refreshClusters()`
    /// after each run and after each naming action.
    private(set) var allClusters: [Cluster] = []

    /// Faces can run: a pack is installed and it ships face models.
    var isAvailable: Bool { installedPack?()?.hasFaces == true }

    /// Unlabeled clusters big enough to be worth reviewing, biggest first.
    ///
    /// The entry point on the People screen appears exactly when this is
    /// non-empty.
    var reviewableClusters: [Cluster] {
        allClusters
            .filter { $0.state == .unlabeled && $0.size >= Self.reviewMinimumFaces }
            .sorted { ($0.size, $1.id) > ($1.size, $0.id) }
    }

    /// Named clusters, for the "already reviewed" half of the screen.
    var namedClusters: [Cluster] {
        allClusters.filter { $0.state == .named }.sorted { $0.size > $1.size }
    }

    // MARK: - Injected

    @ObservationIgnored private let cacheDatabaseURL: URL
    /// The installed pack, discovered and verified once by `TaggingService`.
    /// Reading it from there rather than repeating the search keeps a Settings
    /// appearance from SHA-256-ing a 40 MB ONNX twice.
    @ObservationIgnored var installedPack: (@MainActor () -> TaggingService.PackStatus?)?
    /// Supplies the photos a run should consider. Set by `GalleryStore`.
    @ObservationIgnored var eligiblePhotos: (@MainActor () -> [PhotoFile])?
    /// The library root a run is confined to. Same reason as tagging's: the
    /// core's cache DB outlives any one root.
    @ObservationIgnored var libraryRoot: (@MainActor () -> URL?)?
    /// Called when freshly written sidecars need to be pulled into the app.
    /// `GalleryStore` wires this to a light rescan.
    @ObservationIgnored var onSidecarsWritten: (@MainActor () async -> Void)? {
        get { refresh.onRefresh }
        set { refresh.onRefresh = newValue }
    }

    @ObservationIgnored private var session: FaceSession?
    /// Which pack `session` was opened against, so a pack change reopens it.
    @ObservationIgnored private var sessionPackDirectory: URL?
    @ObservationIgnored private let refresh = SidecarRefreshCoalescer(interval: refreshInterval)
    @ObservationIgnored var refreshTask: Task<Void, Never>? { refresh.task }
    /// `cancel()` arrived before the core had a run to cancel.
    @ObservationIgnored private var cancelRequested = false

    init(cacheDatabaseURL: URL) {
        self.cacheDatabaseURL = cacheDatabaseURL
    }

    // MARK: - Running

    /// Enqueue every eligible photo and start a run.
    ///
    /// No-op when a run is already in flight.
    func startScan() async {
        guard !isRunning else { return }
        guard let pack = installedPack?(), pack.hasFaces else {
            lastError = .noFaceModels
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

        let session: FaceSession
        do {
            session = try await openSession(packDirectory: pack.directory)
        } catch {
            isRunning = false
            progress = nil
            lastError = FaceServiceError(error)
            Log.ml.error("Face session failed to open: \(Log.r.error(error))")
            return
        }

        do {
            let inserted = try await Self.enqueue(paths, into: session)
            Log.ml.info("Enqueued \(paths.count) photos for faces (\(inserted) new)")
        } catch {
            isRunning = false
            progress = nil
            lastError = FaceServiceError(error)
            Log.ml.error("Face enqueue failed: \(Log.r.error(error))")
            return
        }

        // Loading two ONNX models and enqueueing a 20k-photo library both take
        // long enough for the user to reach Cancel, and until `start` there is
        // no run for `session.cancel()` to reach — the core clears its own
        // cancel flag inside `start` anyway. So the request is honoured here,
        // by not starting.
        if cancelRequested {
            cancelRequested = false
            isRunning = false
            progress = nil
            lastSummary = Summary(cancelled: true)
            Log.ml.info("Face scan cancelled before the run started")
            return
        }

        let bridge = FaceProgressBridge(
            progress: { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.progress = Progress(done: done, total: total)
                }
            },
            sidecarsWritten: { [weak self] count in
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
            lastError = FaceServiceError(error)
            Log.ml.error("Face run failed to start: \(Log.r.error(error))")
        }
    }

    /// Ask the core to stop. `onFinished` still fires, with `cancelled` set.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        session?.cancel()
    }

    /// One `onSidecarsWritten` batch from the core's auto-tag pass. Internal so
    /// tests can drive the coalescing without staging a whole run.
    func noteSidecarsWritten(_ count: Int) {
        Log.ml.debug("\(count) face sidecars written")
        refresh.note()
    }

    private func finish(_ summary: Summary) async {
        isRunning = false
        cancelRequested = false
        progress = nil
        lastSummary = summary
        if let failure = summary.failure {
            lastError = failure
            Log.ml.error("Face run failed: \(String(describing: failure))")
        } else {
            Log.ml.info(
                "Face run: \(summary.processed) processed, \(summary.facesFound) faces, \(summary.clustersCreated) new clusters, \(summary.facesAutoTagged) auto-tagged, \(summary.sidecarsWritten) sidecars, \(summary.failed) failed, cancelled=\(summary.cancelled)"
            )
        }
        await refreshClusters()
        // Always refresh on finish, even when nothing was written this batch —
        // an earlier batch's rescan may have been coalesced away.
        refresh.schedule()
        await refresh.task?.value
    }

    // MARK: - Review

    /// Re-read the cluster list from the core.
    ///
    /// Cheap enough to call after every mutation: the exemplar query is capped
    /// per cluster in SQL, so this is bounded by the cluster count rather than
    /// by the face count.
    func refreshClusters() async {
        guard let pack = installedPack?(), pack.hasFaces else {
            allClusters = []
            return
        }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            allClusters = try await Self.readClusters(from: session)
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("Reading face clusters failed: \(Log.r.error(error))")
        }
    }

    /// Every face of one cluster, best first. For the cluster-detail screen.
    func faces(inCluster id: Int64) async -> [Face] {
        guard let pack = installedPack?(), pack.hasFaces else { return [] }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            return try await Task.detached(priority: .userInitiated) {
                try session.clusterFaces(clusterId: id).map(Face.init)
            }.value
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("Reading cluster \(id) failed: \(Log.r.error(error))")
            return []
        }
    }

    /// Name a cluster: the core writes `People/<Name>` + regions to every
    /// affected photo's sidecar, then the app rescans so the person appears.
    @discardableResult
    func name(cluster id: Int64, as name: String) async -> Bool {
        await mutate("naming cluster \(id)") { try $0.nameCluster(clusterId: id, name: name) }
    }

    /// Take a cluster's name off and retract it from the sidecars it reached.
    @discardableResult
    func unname(cluster id: Int64) async -> Bool {
        await mutate("un-naming cluster \(id)") { try $0.unnameCluster(clusterId: id) }
    }

    /// Dismiss a cluster as "not a person".
    @discardableResult
    func ignore(cluster id: Int64) async -> Bool {
        await mutate("ignoring cluster \(id)") { try $0.ignoreCluster(clusterId: id) }
    }

    /// Rename a person everywhere the core has written them.
    @discardableResult
    func rename(person old: String, to new: String) async -> Bool {
        await mutate("renaming \(Log.r.person(old))") {
            try $0.renamePerson(old: old, new: new)
        }
    }

    /// Rebuild the partition of every unlabeled face.
    ///
    /// Unlabeled cluster ids do not survive this, so the cluster list is
    /// re-read rather than patched.
    func recluster() async {
        guard !isRunning, let pack = installedPack?(), pack.hasFaces else {
            if isRunning { lastError = .alreadyRunning }
            return
        }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            let summary = try await Task.detached(priority: .userInitiated) {
                try session.recluster()
            }.value
            Log.ml.info(
                "Re-clustered \(summary.faces) faces: \(summary.clustersBefore) → \(summary.clustersAfter) clusters"
            )
            lastError = nil
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("Re-cluster failed: \(Log.r.error(error))")
        }
        await refreshClusters()
    }

    /// The shape every naming action shares: refuse mid-run, call the core off
    /// the actor, refresh the cluster list, and pull the new sidecars in.
    ///
    /// The core refuses these calls while a run is in flight (it will not
    /// re-derive a sidecar from a cluster table a run is mutating), so this
    /// checks first and reports it as a typed error rather than letting the
    /// user press a button that silently does nothing.
    private func mutate(
        _ what: String,
        _ body: @escaping @Sendable (FaceSession) throws -> SidecarWriteReport
    ) async -> Bool {
        guard !isRunning else {
            lastError = .alreadyRunning
            return false
        }
        guard let pack = installedPack?(), pack.hasFaces else {
            lastError = .noFaceModels
            return false
        }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            let report = try await Task.detached(priority: .userInitiated) {
                () -> Result<SidecarWriteReport, FaceServiceError> in
                do {
                    return .success(try body(session))
                } catch {
                    return .failure(FaceServiceError(error))
                }
            }.value.get()
            lastError = nil
            Log.ml.info(
                "\(what): \(report.written) written, \(report.unchanged) unchanged, \(report.failed) failed"
            )
            for path in report.failedPaths {
                Log.ml.error("Sidecar write failed: \(Log.r.path(URL(fileURLWithPath: path)))")
            }
            await refreshClusters()
            // Unconditional: the point of a naming action is that the person
            // shows up now, and `written == 0` still happens on a re-name to
            // the same value, where a refresh is harmless.
            refresh.schedule()
            await refresh.task?.value
            return report.failed == 0
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("\(what) failed: \(Log.r.error(error))")
            return false
        }
    }

    // MARK: - Eligibility

    /// The photos a run should consider.
    ///
    /// Deliberately the *same* rule as tagging's, called through rather than
    /// restated: a face run reads the same bytes, decodes with the same
    /// decoder, and writes a sidecar next to the same file, so a photo either
    /// pass can process is a photo the other can too. If the two ever need to
    /// diverge, this is the one place that says so.
    nonisolated static func isEligible(_ photo: PhotoFile) -> Bool {
        TaggingService.isEligible(photo)
    }

    // MARK: - Off-actor plumbing

    /// Drop the open session — a pack import is replacing the models it holds.
    func invalidateSession() async {
        await releaseSession()
        allClusters = []
    }

    private func openSession(packDirectory: URL) async throws -> FaceSession {
        if let session, sessionPackDirectory == packDirectory { return session }
        if session != nil { await releaseSession() }

        let cacheURL = cacheDatabaseURL
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let opened = try await Task.detached(priority: .userInitiated) {
            () -> Result<FaceSession, FaceServiceError> in
            do {
                return .success(try FaceSession(
                    cacheDbPath: cacheURL.path,
                    modelPackDir: packDirectory.path
                ))
            } catch {
                return .failure(FaceServiceError(error))
            }
        }.value.get()
        session = opened
        sessionPackDirectory = packDirectory
        return opened
    }

    /// Stop any in-flight run and release the session without blocking the main
    /// actor — the core joins its run thread on `Drop`, and that thread can be
    /// a whole inference away from noticing.
    private func releaseSession() async {
        guard let session else { return }
        session.cancel()
        await Task.detached(priority: .userInitiated) {
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
        _ paths: [String], into session: FaceSession
    ) async throws -> Int {
        try await Task.detached(priority: .utility) { () -> Result<Int, FaceServiceError> in
            do {
                return .success(Int(try session.enqueue(paths: paths)))
            } catch {
                return .failure(FaceServiceError(error))
            }
        }.value.get()
    }

    private nonisolated static func readClusters(
        from session: FaceSession
    ) async throws -> [Cluster] {
        try await Task.detached(priority: .userInitiated) { () -> Result<[Cluster], FaceServiceError> in
            do {
                return .success(try session.clusters().map(Cluster.init))
            } catch {
                return .failure(FaceServiceError(error))
            }
        }.value.get()
    }
}

// MARK: - FFI value conversion

extension FaceService.Face {
    init(_ ref: FaceRef) {
        self.init(
            url: URL(fileURLWithPath: ref.path),
            // The core hands back MWG geometry precisely so this is a
            // relabelling and not a conversion. `name` is nil: a face in an
            // unlabeled cluster has no person, and the crop does not need one.
            region: FaceRegion(
                name: nil,
                centerX: ref.centerX,
                centerY: ref.centerY,
                width: ref.width,
                height: ref.height
            ),
            quality: Double(ref.quality)
        )
    }
}

extension FaceService.Cluster {
    init(_ summary: ClusterSummary) {
        self.init(
            id: summary.id,
            size: Int(summary.size),
            state: summary.state,
            name: summary.name,
            exemplars: summary.exemplars.map(FaceService.Face.init)
        )
    }
}

// MARK: - Progress bridge

/// Forwards the core's worker-thread callbacks to the main actor.
///
/// `Sendable` without `@unchecked`: the only stored state is three immutable
/// `@Sendable` closures, so there is nothing to race.
private final class FaceProgressBridge: FaceProgressListener, Sendable {
    private let progressHandler: @Sendable (Int, Int) -> Void
    private let sidecarsHandler: @Sendable (Int) -> Void
    private let finishedHandler: @Sendable (FaceService.Summary) -> Void

    init(
        progress: @escaping @Sendable (Int, Int) -> Void,
        sidecarsWritten: @escaping @Sendable (Int) -> Void,
        finished: @escaping @Sendable (FaceService.Summary) -> Void
    ) {
        self.progressHandler = progress
        self.sidecarsHandler = sidecarsWritten
        self.finishedHandler = finished
    }

    func onProgress(done: UInt32, total: UInt32) {
        progressHandler(Int(done), Int(total))
    }

    /// Detections landed in the cache. Nothing on disk changed, so there is
    /// nothing for the app to re-read — this is why the two path callbacks are
    /// separate.
    func onPhotosWithFaces(paths: [String]) {}

    func onSidecarsWritten(paths: [String]) {
        // Only the count crosses: the app re-reads the sidecars through the
        // scanner anyway, so the paths would be dead weight on the main actor.
        sidecarsHandler(paths.count)
    }

    func onFinished(summary: FaceRunSummary) {
        finishedHandler(FaceService.Summary(
            processed: Int(summary.processed),
            photosWithFaces: Int(summary.photosWithFaces),
            facesFound: Int(summary.facesFound),
            cacheHits: Int(summary.cacheHits),
            skipped: Int(summary.skipped),
            failed: Int(summary.failed),
            facesAssigned: Int(summary.facesAssigned),
            clustersCreated: Int(summary.clustersCreated),
            facesAutoTagged: Int(summary.facesAutoTagged),
            sidecarsWritten: Int(summary.sidecarsWritten),
            cancelled: summary.cancelled,
            failure: summary.failure.map(FaceServiceError.init)
        ))
    }
}

// MARK: - Errors

/// App-facing face failure.
///
/// A flattening of the FFI's `FaceError` down to the cases the UI
/// distinguishes, plus `noFaceModels`, which this layer detects before it ever
/// opens a session. The detail strings are for logs and the Settings error
/// line; the *case* is what code switches on.
enum FaceServiceError: Error, Sendable, Equatable {
    /// No pack installed, or the installed one is tagging-only.
    case noFaceModels
    case pack(String)
    case cache(String)
    case inference(String)
    case io(String)
    case sidecar(String)
    /// The name the user typed cannot be a person's name. Shown next to the
    /// field, not as a banner.
    case invalidName(String)
    /// The cluster is gone — a re-cluster pass rebuilt the partition under a
    /// list the screen was still holding.
    case clusterGone
    case alreadyRunning
    case cancelled

    init(_ error: any Error) {
        // Already classified. The off-actor helpers hand back
        // `Result<_, FaceServiceError>` and their callers re-wrap whatever
        // `get()` throws.
        if let classified = error as? FaceServiceError {
            self = classified
            return
        }
        guard let e = error as? FaceError else {
            self = .io(error.localizedDescription)
            return
        }
        switch e {
        case .ModelsUnavailable:
            self = .noFaceModels
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
        case .InvalidName(_, let reason):
            self = .invalidName(reason)
        case .ClusterNotFound:
            self = .clusterGone
        case .Cancelled:
            self = .cancelled
        case .AlreadyRunning:
            self = .alreadyRunning
        }
    }

    init(_ failure: FaceFailure) {
        switch failure {
        case .pack: self = .pack("model pack could not be used")
        case .cacheDb: self = .cache("cache database error")
        case .inference: self = .inference("face detection failed")
        case .io: self = .io("file access failed")
        case .sidecar: self = .sidecar("sidecar write failed")
        case .cancelled: self = .cancelled
        }
    }

    /// One line, safe to show in Settings or the review screen.
    var message: String {
        switch self {
        case .noFaceModels: return "The installed model pack has no face models."
        case .pack(let d): return "Model pack problem: \(d)"
        case .cache(let d): return "Face cache problem: \(d)"
        case .inference(let d): return "Face detection failed: \(d)"
        case .io(let d): return "File error: \(d)"
        case .sidecar(let d): return "Sidecar write failed: \(d)"
        case .invalidName(let d): return "That name can't be used: \(d)"
        case .clusterGone: return "That group no longer exists — pull to refresh."
        case .alreadyRunning: return "A face scan is running."
        case .cancelled: return "The face scan was cancelled."
        }
    }
}
