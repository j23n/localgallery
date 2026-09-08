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
/// cluster, un-naming it, ignoring it, rejecting it, merging two, splitting one
/// and renaming a person all rewrite sidecars, and all of them are refused by
/// the core while
/// a run is in flight. So `isRunning` gates the review UI's buttons, not just
/// its progress row.
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
    /// A run triggers that refresh from `onSidecarsWritten` (per-photo stamps
    /// and the auto-tag pass), coalesced to 30 s; a naming action triggers
    /// it directly, because its whole point is that the person appears now.
@Observable
@MainActor
final class FaceService {
    /// Minimum spacing between the rescans a run's sidecar batches trigger.
    /// Matches tagging's — the two are the same kind of interruption.
    static let refreshInterval: TimeInterval = 30

    /// How many faces an unlabeled cluster needs before review shows it.
    ///
    /// One. A Publish pass that becomes source of truth has to see every
    /// leftover face — a singleton is still a yes/no. The tail is noisy
    /// (a passer-by, a poster) and that is what Ignore is for.
    static let reviewMinimumFaces = 1

    /// Live progress of a run. `nil` when idle.
    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
        var startedAt: Date
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
        /// "X / Y" or "X / Y · ~M:SS" once throughput is known.
        var countText: String {
            ProgressETA.countText(processed: done, total: total, startedAt: startedAt)
        }
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
        /// The core's handle on this face, opaque here and handed straight back
        /// to `split(cluster:faces:)`. A photo can hold two faces of the same
        /// person, so neither the path nor the rectangle identifies one.
        var key: String
        var id: String { key }
    }

    /// Two clusters the core thinks are the same person.
    ///
    /// Ids only, joined against `allClusters` where it is rendered — the core
    /// deliberately does not re-send the exemplars the app already holds.
    struct Proposal: Equatable, Hashable, Sendable, Identifiable {
        var a: Int64
        var b: Int64
        var similarity: Double
        var id: String { "\(a)-\(b)" }
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
    /// after each run (including a no-op one), after each naming action, and
    /// at launch so Collections does not depend on Settings having run.
    private(set) var allClusters: [Cluster] = []
    /// Outstanding merge suggestions, strongest first. Read alongside
    /// `allClusters` because the review screen renders them together and a
    /// proposal naming a cluster that list no longer has is not renderable.
    private(set) var mergeProposals: [Proposal] = []

    /// Faces can run: a pack is installed and it ships face models.
    var isAvailable: Bool { installedPack?()?.hasFaces == true }

    /// Biggest first, id breaking the tie.
    ///
    /// `sorted(by:)` is not a stable sort, so size alone lets two equal-sized
    /// clusters swap places on every re-read — a list that shuffles under the
    /// user's finger between one refresh and the next.
    nonisolated static func biggestFirst(_ a: Cluster, _ b: Cluster) -> Bool {
        (a.size, b.id) > (b.size, a.id)
    }

    /// Unlabeled clusters waiting for a name or Ignore, biggest first.
    ///
    /// The People section on Collections (and the People list) appears when
    /// this is non-empty, even if nobody has been named yet.
    var reviewableClusters: [Cluster] {
        allClusters
            .filter { $0.state == .unlabeled && $0.size >= Self.reviewMinimumFaces }
            .sorted(by: Self.biggestFirst)
    }

    /// Named clusters, for the "already reviewed" half of the screen.
    ///
    /// Id breaks the size tie: `sorted(by:)` is not stable, so two clusters of
    /// the same size could swap places on every re-read and shuffle the list
    /// under the user's finger.
    var namedClusters: [Cluster] {
        allClusters.filter { $0.state == .named }.sorted(by: Self.biggestFirst)
    }

    /// Whether *any* core engine is busy.
    ///
    /// Naming is refused while a face run is in flight, and has to be refused
    /// while a **tagging** run is too: the two engines share one cache file and
    /// one sidecar per photo, so a naming landing mid-tagging-run has the two
    /// of them read-modify-writing the same `.xmp`. The core's own guard only
    /// covers its own session — this is the app-side half that makes the
    /// exclusion mutual.
    var isCoreBusy: Bool { isRunning || (otherEngineIsRunning?() ?? false) }

    // MARK: - Injected

    @ObservationIgnored private let cacheDatabaseURL: URL
    /// The installed pack, discovered and verified once by `TaggingService`.
    /// Reading it from there rather than repeating the search keeps a Settings
    /// appearance from SHA-256-ing a 40 MB ONNX twice.
    @ObservationIgnored var installedPack: (@MainActor () -> TaggingService.PackStatus?)?
    /// Makes sure somebody has looked for an installed pack at least once.
    ///
    /// `installedPack` reads `TaggingService.pack`, which stays `nil` until
    /// `refreshAvailability()` runs — and its only caller used to be Settings'
    /// `.task`. On a cold launch where the user never opened Settings, the
    /// People screen therefore asked "is a pack installed?", was told no, and
    /// the whole review entry point failed to appear. Every faces surface funnels
    /// through `refreshClusters()`/`startScan()`, so those ask here first.
    @ObservationIgnored var ensurePackChecked: (@MainActor () async -> Void)?
    /// Whether tagging or the unified analysis run is in flight. Naming has to
    /// wait: the engines share one cache file and one sidecar per photo. See
    /// `isCoreBusy`. Analysis is included so a Places write cannot collide with
    /// a name. `startScan` itself does not consult this — analysis calls it
    /// while the flag is already true.
    @ObservationIgnored var otherEngineIsRunning: (@MainActor () -> Bool)?
    /// Supplies the photos a run should consider. Set by `GalleryStore`.
    @ObservationIgnored var eligiblePhotos: (@MainActor () -> [PhotoFile])?
    /// The library root a run is confined to. Same reason as tagging's: the
    /// core's cache DB outlives any one root.
    @ObservationIgnored var libraryRoot: (@MainActor () -> URL?)?
    /// A person's name changed in the sidecars, `(old, new)`. `GalleryStore`
    /// wires this to the per-person state keyed by tag path — the hidden set,
    /// the pins, the cover photos, the "me" person, the contact links — none of
    /// which the rescan can migrate on its own, because by the time it lands a
    /// renamed person is indistinguishable from a new one.
    @ObservationIgnored var onPersonRenamed: (@MainActor (String, String) -> Void)?
    /// Called when freshly written sidecars need to be pulled into the app.
    /// `GalleryStore` wires this to a light rescan.
    @ObservationIgnored var onSidecarsWritten: (@MainActor () async -> Void)? {
        get { refresh.onRefresh }
        set { refresh.onRefresh = newValue }
    }
    /// Paths this run just finished (detections, empty scans, cache hits).
    /// `LibraryAnalysis` records them into the live Scan Activity journal.
    @ObservationIgnored var onPhotosRecorded: (@MainActor ([String]) -> Void)?
    /// Per-photo detections of the last finished run (score, quality,
    /// Joined vs Seeded). Scan Activity detail only — not a library field.
    @ObservationIgnored var onLastRunDiagnostics: (@MainActor ([String: [FacePhotoDiagnostic]]) -> Void)?

    @ObservationIgnored private var session: FaceSession?
    /// Which pack `session` was opened against, so a pack change reopens it.
    @ObservationIgnored private var sessionPackDirectory: URL?
    /// The in-flight `openSession`, and the pack it is opening.
    ///
    /// Two callers reaching `openSession` at once (Settings pressing "Tag
    /// Library Now" while the People screen's `.task` refreshes clusters) each
    /// built their own `FaceSession`: two ONNX loads, two SQLite connections,
    /// and — the part that actually breaks — two run locks, so `cancel()` went
    /// to whichever session `self.session` happened to end up holding while the
    /// *other* one owned the run.
    ///
    /// Keyed by directory so the "is this the open I wanted?" question is
    /// answered from the slot itself. Answering it from `sessionPackDirectory`
    /// instead cannot work: the waiter can resume before the opener has
    /// assigned it.
    @ObservationIgnored private var opening: (directory: URL, task: Task<FaceSession, any Error>)?
    /// Coalesces + drains the rescans this service's writes trigger. Injected,
    /// and **shared with `TaggingService`**: the 30 s window is a budget for
    /// interrupting the user with a rescan, and two engines each spending it
    /// separately is two rescans, which is what the window exists to prevent.
    @ObservationIgnored private let refresh: SidecarRefreshCoalescer
    @ObservationIgnored var refreshTask: Task<Void, Never>? { refresh.task }
    /// `cancel()` arrived before the core had a run to cancel.
    @ObservationIgnored private var cancelRequested = false
    /// How many `FaceSession`s this service has actually built.
    ///
    /// Not observed state and not shown anywhere: it exists because "two
    /// concurrent callers share one session" — the whole point of `opening` —
    /// is otherwise unobservable from outside the service.
    @ObservationIgnored private(set) var sessionsOpened = 0

    init(cacheDatabaseURL: URL, refresh: SidecarRefreshCoalescer) {
        self.cacheDatabaseURL = cacheDatabaseURL
        self.refresh = refresh
    }

    // MARK: - Running

    /// Enqueue every eligible photo and start a run.
    ///
    /// No-op when a run is already in flight.
    func startScan() async {
        guard !isRunning else { return }
        await ensurePackChecked?()
        guard let pack = installedPack?(), pack.hasFaces else {
            lastError = .noFaceModels
            return
        }
        let photos = (eligiblePhotos?() ?? []).filter(Self.isEligible)
        guard !photos.isEmpty else {
            lastSummary = Summary()
            // Clusters already in the cache still need to reach the UI.
            // Settings "Scan Photos" with nothing new used to return here
            // and leave Review New People empty until a later run that
            // actually started.
            await refreshClusters()
            return
        }
        let paths = photos.map(\.url.standardizedFileURL.path)
        let rootPrefix = libraryRoot?()?.standardizedFileURL.path

        isRunning = true
        cancelRequested = false
        progress = Progress(done: 0, total: 0, startedAt: Date())
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
            progress = nil
            lastError = FaceServiceError(error)
            Log.ml.error("Face enqueue failed: \(Log.r.error(error))")
            await releaseSession()
            isRunning = false
            return
        }

        // Loading two ONNX models and enqueueing a 20k-photo library both take
        // long enough for the user to reach Cancel, and until `start` there is
        // no run for `session.cancel()` to reach — the core clears its own
        // cancel flag inside `start` anyway. So the request is honoured here,
        // by not starting.
        if cancelRequested {
            cancelRequested = false
            progress = nil
            lastSummary = Summary(cancelled: true)
            Log.ml.info("Face scan cancelled before the run started")
            await releaseSession()
            isRunning = false
            return
        }

        let bridge = FaceProgressBridge(
            progress: { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.publishProgress(done: done, total: total)
                }
            },
            photosScanned: { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.notePhotosScanned(paths)
                }
            },
            sidecarsWritten: { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.noteSidecarsWritten(paths)
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
            progress = nil
            lastError = FaceServiceError(error)
            Log.ml.error("Face run failed to start: \(Log.r.error(error))")
            await releaseSession()
            isRunning = false
        }
    }

    /// Force-scan one photo without touching the rest of the queue.
    func startOne(_ photo: PhotoFile) async {
        guard !isRunning else { return }
        guard Self.isEligible(photo) else { return }
        await ensurePackChecked?()
        guard let pack = installedPack?(), pack.hasFaces else {
            lastError = .noFaceModels
            return
        }
        let path = photo.url.standardizedFileURL.path
        let rootPrefix = libraryRoot?()?.standardizedFileURL.path

        isRunning = true
        cancelRequested = false
        progress = Progress(done: 0, total: 1, startedAt: Date())
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
        if cancelRequested {
            cancelRequested = false
            progress = nil
            lastSummary = Summary(cancelled: true)
            await releaseSession()
            isRunning = false
            return
        }

        let bridge = FaceProgressBridge(
            progress: { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.publishProgress(done: done, total: total)
                }
            },
            photosScanned: { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.notePhotosScanned(paths)
                }
            },
            sidecarsWritten: { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.noteSidecarsWritten(paths)
                }
            },
            finished: { [weak self] summary in
                Task { @MainActor [weak self] in
                    await self?.finish(summary)
                }
            }
        )
        do {
            try session.startOne(progress: bridge, path: path, rootPrefix: rootPrefix)
        } catch {
            progress = nil
            lastError = FaceServiceError(error)
            Log.ml.error("Face one-photo run failed to start: \(Log.r.error(error))")
            await releaseSession()
            isRunning = false
        }
    }

    /// Ask the core to stop. `onFinished` still fires, with `cancelled` set.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        session?.cancel()
    }

    /// Drop every face-queue row so the next run re-detects the library.
    ///
    /// Detections and clusters stay; `reset_queue` sets `force_next` so the
    /// `face_scans` skip is ignored. Same recovery shape as tagging.
    func resetQueue() async {
        guard !isRunning else { return }
        await ensurePackChecked?()
        guard let pack = installedPack?(), pack.hasFaces else {
            lastError = .noFaceModels
            return
        }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            try session.resetQueue()
            lastSummary = nil
            lastError = nil
            Log.ml.info("Face queue reset")
            await releaseSession()
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("Face queue reset failed: \(Log.r.error(error))")
        }
    }

    /// One `onSidecarsWritten` batch. Internal so tests can drive the
    /// coalescing without staging a whole run.
    func noteSidecarsWritten(_ count: Int) {
        Log.ml.debug("\(count) face sidecars written")
        refresh.note()
    }

    /// Disk changed: 30 s rescan cooldown, and the journal picks up the
    /// new sidecar bytes (replacing the earlier "we scanned this" row).
    func noteSidecarsWritten(_ paths: [String]) {
        noteSidecarsWritten(paths.count)
        onPhotosRecorded?(paths)
    }

    /// A scan batch: journal only. A stamp or named write may follow and
    /// replace the row; a no-op cache hit stays as "we looked at this file".
    func notePhotosScanned(_ paths: [String]) {
        onPhotosRecorded?(paths)
    }

    /// Keep `startedAt` across ticks so the ETA is elapsed-since-start, not
    /// elapsed-since-last-callback.
    private func publishProgress(done: Int, total: Int) {
        let startedAt = progress?.startedAt ?? Date()
        progress = Progress(done: done, total: total, startedAt: startedAt)
    }

    private func finish(_ summary: Summary) async {
        cancelRequested = false
        progress = nil
        lastSummary = summary
        pullLastRunDiagnostics()
        if let failure = summary.failure {
            lastError = failure
            Log.ml.error("Face run failed: \(String(describing: failure))")
        } else {
            Log.ml.info(
                "Face run: \(summary.processed) processed, \(summary.facesFound) faces, \(summary.clustersCreated) new clusters, \(summary.facesAutoTagged) auto-tagged, \(summary.sidecarsWritten) sidecars, \(summary.failed) failed, cancelled=\(summary.cancelled)"
            )
        }
        // Always refresh on finish, even when nothing was written this batch —
        // an earlier batch's rescan may have been coalesced away. Scheduled
        // before the first `await` in this method, so nothing can observe
        // `isRunning == false` while the rescan this run owes still has no
        // task to wait on.
        refresh.schedule()
        await refreshClusters()
        await refresh.task?.value
        // Drop the detector + embedder sessions before Places starts, and
        // before LibraryAnalysis's extra `refreshClusters` reopens a short
        // one. `isRunning` stays true until then so the next phase waits.
        await releaseSession()
        isRunning = false
    }

    /// Pull the last run's per-photo assign journal before the session
    /// is released. Requires a core rebuild (`takeLastRunPhotos`).
    private func pullLastRunDiagnostics() {
        guard let session else { return }
        let records = session.takeLastRunPhotos()
        guard !records.isEmpty else { return }
        var byPath: [String: [FacePhotoDiagnostic]] = [:]
        byPath.reserveCapacity(records.count)
        for record in records {
            byPath[record.path] = record.faces.map { face in
                let assignment: FacePhotoDiagnostic.Assignment?
                switch face.assignment {
                case .joined: assignment = .joined
                case .seeded: assignment = .seeded
                case .none: assignment = nil
                }
                return FacePhotoDiagnostic(
                    score: face.score,
                    quality: face.quality,
                    clusterID: face.clusterId,
                    assignment: assignment,
                    label: face.label
                )
            }
        }
        onLastRunDiagnostics?(byPath)
    }

    // MARK: - Review

    /// Re-read the cluster list from the core.
    ///
    /// Cheap enough to call after every mutation: the exemplar query is capped
    /// per cluster in SQL, so this is bounded by the cluster count rather than
    /// by the face count.
    func refreshClusters() async {
        // The one place a cold launch can discover that faces exist at all.
        await ensurePackChecked?()
        guard let pack = installedPack?(), pack.hasFaces else {
            allClusters = []
            mergeProposals = []
            return
        }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            // REMOVE AFTER: named-keyword-resync. Delete this call and the helper.
            await resyncNamedKeywordsOnce(session)
            // REMOVE AFTER: face-decision-resync. Delete this call and the helper.
            await resyncFaceDecisionsOnce(session)
            let review = try await Self.readReview(from: session)
            allClusters = review.clusters
            mergeProposals = review.proposals
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("Reading face clusters failed: \(Log.r.error(error))")
        }
    }

    /// REMOVE AFTER: named-keyword-resync. Delete with `named_keyword_resync.rs`.
    ///
    /// Quiet on purpose: a background repair must not steal `lastError` from
    /// a naming the user just tried. A run in flight skips — the run itself
    /// does the same pass.
    private func resyncNamedKeywordsOnce(_ session: FaceSession) async {
        guard !isCoreBusy else { return }
        let root = libraryRoot?()?.standardizedFileURL.path
        do {
            let report = try await Task.detached(priority: .utility) {
                try session.resyncNamedKeywordsOnce(rootPrefix: root)
            }.value
            if report.written == 0 && report.failed == 0 { return }
            Log.ml.info(
                "named-keyword-resync: \(report.written) written, \(report.unchanged) unchanged, \(report.skipped) skipped, \(report.failed) failed"
            )
            if report.written > 0 {
                refresh.schedule()
            }
        } catch {
            Log.ml.error("named-keyword-resync failed: \(Log.r.error(error))")
        }
    }

    /// REMOVE AFTER: face-decision-resync. Delete with `face_decision_resync.rs`.
    private func resyncFaceDecisionsOnce(_ session: FaceSession) async {
        guard !isCoreBusy else { return }
        let root = libraryRoot?()?.standardizedFileURL.path
        do {
            let report = try await Task.detached(priority: .utility) {
                try session.resyncFaceDecisionsOnce(rootPrefix: root)
            }.value
            if report.written == 0 && report.failed == 0 { return }
            Log.ml.info(
                "face-decision-resync: \(report.written) written, \(report.unchanged) unchanged, \(report.skipped) skipped, \(report.failed) failed"
            )
            if report.written > 0 {
                refresh.schedule()
            }
        } catch {
            Log.ml.error("face-decision-resync failed: \(Log.r.error(error))")
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
        await mutate("naming cluster \(id)") { session, root in
            try session.nameCluster(clusterId: id, name: name, rootPrefix: root)
        }
    }

    /// Take a cluster's name off and retract it from the sidecars it reached.
    @discardableResult
    func unname(cluster id: Int64) async -> Bool {
        await mutate("un-naming cluster \(id)") { session, root in
            try session.unnameCluster(clusterId: id, rootPrefix: root)
        }
    }

    /// Ignore a cluster (passer-by / poster). They are faces, just not
    /// someone this library is naming.
    @discardableResult
    func ignore(cluster id: Int64) async -> Bool {
        await mutate("ignoring cluster \(id)") { session, root in
            try session.ignoreCluster(clusterId: id, rootPrefix: root)
        }
    }

    /// Reject a cluster as "not a person" / "not a face".
    @discardableResult
    func reject(cluster id: Int64) async -> Bool {
        await mutate("rejecting cluster \(id)") { session, root in
            try session.rejectCluster(clusterId: id, rootPrefix: root)
        }
    }

    /// Rename a person everywhere the core has written them.
    ///
    /// `onPersonRenamed` runs between the core's success and the rescan: the
    /// app's own per-person state is keyed by tag path, and a rescan that
    /// published the new path before that state moved would show the person
    /// un-pinned, un-hidden and without their cover photo for the length of it.
    @discardableResult
    func rename(person old: String, to new: String) async -> Bool {
        await mutate("renaming \(Log.r.person(old))") { session, root in
            try session.renamePerson(old: old, new: new, rootPrefix: root)
        } afterWrite: { [weak self] in
            self?.onPersonRenamed?(old, new)
        }
    }

    /// Fold one cluster into another. `into` survives; `from` disappears.
    ///
    /// The direction is the caller's decision — see `PeopleReviewView` for the
    /// policy (the named group survives; between two named ones the bigger).
    /// The core only carries it out.
    @discardableResult
    func merge(into: Int64, from: Int64) async -> Bool {
        await merge(into: into, absorbing: [from])
    }

    /// Fold `absorbing` into `into` in one pass: one cache update, one
    /// sidecar rewrite, one cluster refresh, one library rescan.
    ///
    /// Pairwise looping used to re-derive the growing union and wait for a
    /// light rescan after every absorbed group — minutes for a 12-group
    /// suggestion. An empty list is a no-op success so a confirmation that
    /// somehow named nobody does not look like a failure.
    @discardableResult
    func merge(into survivor: Int64, absorbing: [Int64]) async -> Bool {
        guard !absorbing.isEmpty else { return true }
        let listed = absorbing.map(String.init).joined(separator: ", ")
        return await mutate("merging cluster(s) \(listed) into \(survivor)") { session, root in
            try session.mergeClustersMany(into: survivor, from: absorbing, rootPrefix: root)
        }
    }

    /// Move faces out of a cluster and into a new one.
    ///
    /// A selection the core no longer recognises is counted, not fatal: this
    /// screen can be open across a run that deleted a face, and losing the
    /// whole gesture over one stale crop would be the worse answer.
    @discardableResult
    func split(cluster id: Int64, faces: [String]) async -> Bool {
        await mutate("splitting cluster \(id)") { session, root in
            let result = try session.splitCluster(clusterId: id, faceKeys: faces, rootPrefix: root)
            if result.ignoredKeys > 0 {
                Log.ml.info("Split of cluster \(id) skipped \(result.ignoredKeys) faces the core no longer has")
            }
            return result.report
        }
    }

    /// Mark detections as not faces: they leave their group and are rejected,
    /// so the next clustering pass does not offer them again.
    ///
    /// A whole-cluster rejection is `reject(cluster:)` (the core refuses to
    /// split a group into nothing). Otherwise the faces are split out and
    /// that new group is rejected in one go.
    @discardableResult
    func reject(cluster id: Int64, faces keys: [String]) async -> Bool {
        await dismiss(cluster: id, faces: keys, as: .rejected)
    }

    /// Ignore selected faces (passer-by / poster): split them out and ignore
    /// the new group so they are not offered again.
    @discardableResult
    func ignore(cluster id: Int64, faces keys: [String]) async -> Bool {
        await dismiss(cluster: id, faces: keys, as: .ignored)
    }

    private enum Dismissal {
        case ignored
        case rejected
    }

    private func dismiss(cluster id: Int64, faces keys: [String], as kind: Dismissal) async -> Bool {
        guard !keys.isEmpty else { return false }
        let verb = kind == .rejected ? "rejecting" : "ignoring"
        return await mutate("\(verb) \(keys.count) faces from cluster \(id)") { session, root in
            let existing = try session.clusterFaces(clusterId: id)
            let known = Set(existing.map(\.faceKey))
            let wanted = keys.filter { known.contains($0) }
            let target: Int64
            if wanted.isEmpty || wanted.count >= existing.count {
                target = id
            } else {
                target = try session.splitCluster(
                    clusterId: id, faceKeys: wanted, rootPrefix: root
                ).newClusterId
            }
            switch kind {
            case .ignored:
                return try session.ignoreCluster(clusterId: target, rootPrefix: root)
            case .rejected:
                return try session.rejectCluster(clusterId: target, rootPrefix: root)
            }
        }
    }

    /// Forget one merge suggestion — the user said these two are not the same
    /// person. Writes nothing to disk, so it does not go through `mutate`.
    func dismissProposal(_ proposal: Proposal) async {
        guard !isCoreBusy else {
            lastError = .alreadyRunning
            return
        }
        guard let pack = installedPack?(), pack.hasFaces else { return }
        do {
            let session = try await openSession(packDirectory: pack.directory)
            let (a, b) = (proposal.a, proposal.b)
            try await Task.detached(priority: .userInitiated) { () -> Result<Void, FaceServiceError> in
                do {
                    return .success(try session.dismissMergeProposal(a: a, b: b))
                } catch {
                    return .failure(FaceServiceError(error))
                }
            }.value.get()
            mergeProposals.removeAll { $0 == proposal }
            lastError = nil
        } catch {
            lastError = FaceServiceError(error)
            Log.ml.error("Dismissing a merge suggestion failed: \(Log.r.error(error))")
        }
    }

    /// Rebuild the partition of every unlabeled face.
    ///
    /// Unlabeled cluster ids do not survive this, so the cluster list is
    /// re-read rather than patched.
    func recluster() async {
        guard !isCoreBusy, let pack = installedPack?(), pack.hasFaces else {
            if isCoreBusy { lastError = .alreadyRunning }
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

    /// How many failed sidecar paths one naming action puts in the log.
    ///
    /// A rename can touch every photo of a person, and a permissions problem
    /// fails all of them — so "log each failure" is thousands of main-actor
    /// `os_log` calls describing one cause. The core itself hands back counts
    /// for exactly this reason; a short sample plus the total is what a reader
    /// of the log actually needs.
    static let loggedFailurePathLimit = 20

    /// The shape every naming action shares: refuse while the core is busy,
    /// call it off the actor, refresh the cluster list, and pull the new
    /// sidecars in.
    ///
    /// The core refuses these calls while a face run is in flight (it will not
    /// re-derive a sidecar from a cluster table a run is mutating), so this
    /// checks first and reports it as a typed error rather than letting the
    /// user press a button that silently does nothing. It checks the *tagging*
    /// run too — see `isCoreBusy`; the core cannot, because that run belongs to
    /// a different session.
    ///
    /// `body` is handed the root prefix as well as the session: the cache DB
    /// outlives any one library root, so a naming that did not say which root
    /// it meant would try to write sidecars outside the app's security scope.
    private func mutate(
        _ what: String,
        _ body: @escaping @Sendable (FaceSession, String?) throws -> SidecarWriteReport,
        afterWrite: (@MainActor () -> Void)? = nil
    ) async -> Bool {
        guard !isCoreBusy else {
            lastError = .alreadyRunning
            return false
        }
        guard let pack = installedPack?(), pack.hasFaces else {
            lastError = .noFaceModels
            return false
        }
        let rootPrefix = libraryRoot?()?.standardizedFileURL.path
        do {
            let session = try await openSession(packDirectory: pack.directory)
            let report = try await Task.detached(priority: .userInitiated) {
                () -> Result<SidecarWriteReport, FaceServiceError> in
                do {
                    return .success(try body(session, rootPrefix))
                } catch {
                    return .failure(FaceServiceError(error))
                }
            }.value.get()
            // Before the refresh below, not after: whatever app-side state this
            // write invalidates has to move while the library still describes
            // the old world.
            afterWrite?()
            Log.ml.info(
                "\(what): \(report.written) written, \(report.unchanged) unchanged, \(report.skipped) skipped, \(report.failed) failed"
            )
            for path in report.failedPaths.prefix(Self.loggedFailurePathLimit) {
                Log.ml.error("Sidecar write failed: \(Log.r.path(URL(fileURLWithPath: path)))")
            }
            if report.failedPaths.count > Self.loggedFailurePathLimit {
                Log.ml.error(
                    "…and \(report.failedPaths.count - Self.loggedFailurePathLimit) more sidecar writes failed"
                )
            }
            // A partial failure is still a failure the user has to be told
            // about: the core reports it in the count, not by throwing, and
            // clearing `lastError` unconditionally used to swallow it whole —
            // the review screen showed nothing and stayed open with no
            // explanation.
            lastError = report.failed > 0 ? .sidecarWritesFailed(Int(report.failed)) : nil
            await refreshClusters()
            // A light library walk is only owed when bytes on disk changed.
            // Unnamed-into-unnamed writes nothing, and a re-name to the same
            // value is already showing the person — waiting for a rescan
            // after those is what made a 12-group merge take minutes.
            if report.written > 0 {
                refresh.schedule()
                await refresh.task?.value
            }
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

    /// Drop idle ONNX sessions. No-op during a run.
    func unloadSession() async {
        guard !isRunning else { return }
        await releaseSession()
    }

    /// The open session for `packDirectory`, opening one if there is none.
    ///
    /// The open is memoized as a `Task` so concurrent callers await the *same*
    /// one. Without that, two callers both saw `session == nil`, both built a
    /// session, and the second overwrote `self.session` — leaving the first
    /// session holding the run that `cancel()` could no longer reach, two ONNX
    /// model loads, and two connections to one SQLite file.
    private func openSession(packDirectory: URL) async throws -> FaceSession {
        if let session, sessionPackDirectory == packDirectory { return session }
        if let opening, opening.directory == packDirectory {
            return try await opening.task.value
        }
        if session != nil { await releaseSession() }

        let cacheURL = cacheDatabaseURL
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let task = Task { @MainActor () -> FaceSession in
            try await Task.detached(priority: .userInitiated) {
                () -> Result<FaceSession, FaceServiceError> in
                do {
                    return .success(try FaceSession.withHeicDecoder(
                        cacheDbPath: cacheURL.path,
                        modelPackDir: packDirectory.path,
                        decoder: ImageIOHeicDecoder.shared
                    ))
                } catch {
                    return .failure(FaceServiceError(error))
                }
            }.value.get()
        }
        opening = (packDirectory, task)
        // Only clear the slot if it is still ours — a pack change mid-open
        // replaces it, and that open owns its own cleanup.
        defer { if opening?.task == task { opening = nil } }
        let opened = try await task.value
        sessionsOpened += 1
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

    /// The two reads the review screen needs, in one crossing.
    ///
    /// Together rather than separately because a proposal is a pair of cluster
    /// ids and nothing else: read against a different snapshot of the cluster
    /// list, it can name a group that list does not have.
    private nonisolated static func readReview(
        from session: FaceSession
    ) async throws -> (clusters: [Cluster], proposals: [Proposal]) {
        try await Task.detached(priority: .userInitiated) {
            () -> Result<(clusters: [Cluster], proposals: [Proposal]), FaceServiceError> in
            do {
                return .success((
                    clusters: try session.clusters().map(Cluster.init),
                    proposals: try session.mergeProposals().map(Proposal.init)
                ))
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
            url: CoreScanner.fileURL(ref.path),
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
            quality: Double(ref.quality),
            key: ref.faceKey
        )
    }
}

extension FaceService.Proposal {
    init(_ proposal: MergeProposal) {
        self.init(a: proposal.a, b: proposal.b, similarity: Double(proposal.similarity))
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
/// `Sendable` without `@unchecked`: the only stored state is four immutable
/// `@Sendable` closures, so there is nothing to race.
private final class FaceProgressBridge: FaceProgressListener, Sendable {
    private let progressHandler: @Sendable (Int, Int) -> Void
    private let scannedHandler: @Sendable ([String]) -> Void
    private let sidecarsHandler: @Sendable ([String]) -> Void
    private let finishedHandler: @Sendable (FaceService.Summary) -> Void

    init(
        progress: @escaping @Sendable (Int, Int) -> Void,
        photosScanned: @escaping @Sendable ([String]) -> Void,
        sidecarsWritten: @escaping @Sendable ([String]) -> Void,
        finished: @escaping @Sendable (FaceService.Summary) -> Void
    ) {
        self.progressHandler = progress
        self.scannedHandler = photosScanned
        self.sidecarsHandler = sidecarsWritten
        self.finishedHandler = finished
    }

    func onProgress(done: UInt32, total: UInt32) {
        progressHandler(Int(done), Int(total))
    }

    func onPhotosWithFaces(paths: [String]) {
        scannedHandler(paths)
    }

    func onSidecarsWritten(paths: [String]) {
        sidecarsHandler(paths)
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
    /// Some — possibly all — of a naming action's sidecar writes failed.
    ///
    /// Its own case because the core reports this in a *count* rather than by
    /// throwing: the action partly succeeded, and the review screen has to say
    /// so instead of dismissing as though nothing went wrong.
    case sidecarWritesFailed(Int)
    /// The name the user typed cannot be a person's name. Shown next to the
    /// field, not as a banner.
    case invalidName(String)
    /// The cluster is gone — a re-cluster pass rebuilt the partition under a
    /// list the screen was still holding.
    case clusterGone
    /// The merge or split named something the core no longer recognises. Same
    /// cause as `clusterGone` and a different sentence, because the user is
    /// looking at a selection they made rather than at a list.
    case staleSelection
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
        // The three ways an edit can name something the core no longer has: a
        // cluster that was rebuilt, a face that was deleted, a pair that has
        // already been merged. All of them mean the screen is stale, which is
        // the one thing the user can act on.
        case .InvalidMerge, .InvalidSplit, .InvalidFaceKey:
            self = .staleSelection
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
        case .sidecarWritesFailed(let n):
            return n == 1
                ? "1 photo's sidecar could not be written."
                : "\(n) photos' sidecars could not be written."
        case .invalidName(let d): return "That name can't be used: \(d)"
        case .clusterGone: return "That group no longer exists — pull to refresh."
        case .staleSelection: return "That selection is out of date — pull to refresh and try again."
        case .alreadyRunning: return "A scan is running — try again when it finishes."
        case .cancelled: return "The face scan was cancelled."
        }
    }
}
