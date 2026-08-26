import Foundation
import Observation
import os

/// One user-facing "scan the library" run: tagging, then faces, then reverse
/// geocoding. The three engines stay independent (separate queues, separate
/// cache tables) so a pack without faces still tags, and a photo without GPS
/// still gets objects/scenes; this type is only the button, the progress, and
/// the cancel.
@Observable
@MainActor
final class LibraryAnalysis {
    enum Phase: Equatable, Sendable {
        case tagging
        case faces
        case places
    }

    /// Combined progress across the three phases. The chip uses `phase` plus
    /// this phase's work queue (`done` / `total`), not the whole library.
    struct Progress: Equatable, Sendable {
        var phase: Phase
        var done: Int
        var total: Int
        var overallDone: Int
        var overallTotal: Int
        var startedAt: Date

        var label: String {
            switch phase {
            case .tagging: return "Tagging…"
            case .faces: return "Finding faces…"
            case .places: return "Looking up places…"
            }
        }

        /// One word for the shared progress chip.
        var shortLabel: String {
            switch phase {
            case .tagging: return "Tagging"
            case .faces: return "Faces"
            case .places: return "Places"
            }
        }

        /// "X / Y · ~M:SS" for the current phase's work queue — photos that
        /// still need this pass, not the whole library. `nil` while the
        /// engine is still counting that queue.
        var countText: String? {
            guard total > 0 else { return nil }
            return ProgressETA.countText(
                processed: done,
                total: total,
                startedAt: startedAt
            )
        }

        /// Whole-library fraction, not the current phase. Tagging 16 of
        /// 18,220 while faces and places are still queued is a few percent
        /// of the run, not 16 / 18,220 of "this scan".
        var percentText: String {
            guard overallTotal > 0 else { return "0%" }
            let pct = Int((Double(overallDone) / Double(overallTotal) * 100).rounded(.towardZero))
            return "\(min(pct, 100))%"
        }
    }

    struct Summary: Equatable, Sendable {
        var tagging: TaggingService.Summary?
        var faces: FaceService.Summary?
        var places: GeocodingService.Summary?
        var cancelled = false
    }

    private(set) var isRunning = false
    /// Phases this `start` asked for. The Settings rows use this so a full
    /// Scan Photos does not light up the single-phase force buttons.
    private(set) var activePhases: Set<Phase> = []
    private(set) var progress: Progress?
    private(set) var lastSummary: Summary?
    private(set) var lastError: String?
    /// Live journal of this run (and the last finished one). Settings can
    /// open it while tagging is still writing.
    let activity = ScanActivityLog()

    @ObservationIgnored private let tagging: TaggingService
    @ObservationIgnored private let faces: FaceService
    @ObservationIgnored private let places: GeocodingService
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored var photos: (@MainActor () -> [PhotoFile])?
    /// Light rescan after the run, so Places tags (and any tagging/face
    /// sidecars whose coalesced refresh hasn't fired yet) land in the index.
    @ObservationIgnored var onSidecarsWritten: (@MainActor () async -> Void)?
    /// One Places sidecar just landed. `GalleryStore` wires this to the
    /// shared 30 s coalescer — same cooldown tagging and faces already use.
    @ObservationIgnored var onPlaceWritten: (@MainActor () -> Void)?
    /// Sidecar bytes just landed (or were re-read). The Store unions them
    /// onto the live `PhotoFile` — scans will not, because the image file
    /// itself did not change.
    @ObservationIgnored var onSidecarPaths: (@MainActor ([String]) -> Void)?

    init(tagging: TaggingService, faces: FaceService, places: GeocodingService) {
        self.tagging = tagging
        self.faces = faces
        self.places = places
        tagging.onPhotosRecorded = { [weak self] paths in
            self?.activity.scheduleIngest(paths: paths, phase: .tagging)
            self?.onSidecarPaths?(paths)
        }
        faces.onPhotosRecorded = { [weak self] paths in
            self?.activity.scheduleIngest(paths: paths, phase: .faces)
            self?.onSidecarPaths?(paths)
        }
        places.onPlaceRecorded = { [weak self] url, path, outcome in
            self?.activity.record(.place(url: url, path: path, outcome: outcome))
            if case .written = outcome {
                self?.onPlaceWritten?()
                self?.onSidecarPaths?([url.path])
            }
        }
    }

    func start() async {
        await start(phases: [.tagging, .faces, .places], force: false)
    }

    /// Force one photo through `phases`. Does not reset the library queues.
    func startOne(_ photo: PhotoFile, phases: Set<Phase>) async {
        guard !isRunning else { return }
        await tagging.refreshAvailability()
        let tag = phases.contains(.tagging) && tagging.isAvailable && TaggingService.isEligible(photo)
        let face = phases.contains(.faces) && faces.isAvailable && FaceService.isEligible(photo)
        let place = phases.contains(.places) && GeocodingService.isEligible(photo, force: true)
        guard tag || face || place else { return }

        isRunning = true
        activePhases = phases
        cancelRequested = false
        lastError = nil
        lastSummary = nil
        activity.beginRun()
        let startedAt = Date()
        var summary = Summary()

        if tag {
            publish(.tagging, done: 0, total: 1, overallDone: 0, overallTotal: 1, startedAt: startedAt)
            await tagging.startOne(photo)
            await waitForStart({ self.tagging.isRunning })
            while tagging.isRunning {
                let p = tagging.progress
                publish(
                    .tagging,
                    done: p?.done ?? 0,
                    total: max(p?.total ?? 1, 1),
                    overallDone: p?.done ?? 0,
                    overallTotal: 1,
                    startedAt: startedAt
                )
                try? await Task.sleep(for: .milliseconds(200))
            }
            summary.tagging = tagging.lastSummary
            if let err = tagging.lastError, err != .cancelled {
                lastError = err.message
            }
        }
        if cancelRequested {
            summary.cancelled = true
            await end(summary)
            return
        }
        if face {
            publish(.faces, done: 0, total: 1, overallDone: 0, overallTotal: 1, startedAt: startedAt)
            await faces.startOne(photo)
            await waitForStart({ self.faces.isRunning })
            while faces.isRunning {
                let p = faces.progress
                publish(
                    .faces,
                    done: p?.done ?? 0,
                    total: max(p?.total ?? 1, 1),
                    overallDone: p?.done ?? 0,
                    overallTotal: 1,
                    startedAt: startedAt
                )
                try? await Task.sleep(for: .milliseconds(200))
            }
            summary.faces = faces.lastSummary
            if let err = faces.lastError, err != .cancelled {
                lastError = err.message
            }
        }
        if cancelRequested {
            summary.cancelled = true
            await end(summary)
            return
        }
        if place {
            publish(.places, done: 0, total: 1, overallDone: 0, overallTotal: 1, startedAt: startedAt)
            summary.places = await places.geocode([photo], force: true)
            if let err = places.lastError {
                lastError = err
            }
        }
        summary.cancelled = cancelRequested
            || (summary.tagging?.cancelled ?? false)
            || (summary.faces?.cancelled ?? false)
            || (summary.places?.cancelled ?? false)
        await end(summary)
    }

    /// Run `phases` in the usual order. `force` resets that phase's skip
    /// (queue + sidecar version for tagging, `face_scans` for faces, an
    /// existing `Places/…` city for geocoding) and walks the whole library.
    func start(phases: Set<Phase>, force: Bool) async {
        guard !isRunning else { return }
        await tagging.refreshAvailability()
        if force {
            if phases.contains(.tagging) { await tagging.resetQueue() }
            if phases.contains(.faces) { await faces.resetQueue() }
        }
        let all = photos?() ?? []
        let tagPhotos = phases.contains(.tagging) && tagging.isAvailable
            ? all.filter(TaggingService.isEligible) : []
        let facePhotos = phases.contains(.faces) && faces.isAvailable
            ? all.filter(FaceService.isEligible) : []
        let placePhotos = phases.contains(.places)
            ? all.filter { GeocodingService.isEligible($0, force: force) } : []
        guard !tagPhotos.isEmpty || !facePhotos.isEmpty || !placePhotos.isEmpty else {
            lastSummary = Summary()
            // "Nothing to do" is a scan result, not a UI one: unlabeled
            // groups from an earlier run live in the cache and still need
            // to reach Collections. Face `finish()` is the usual publisher,
            // and this path never starts a run.
            await faces.refreshClusters()
            return
        }

        isRunning = true
        activePhases = phases
        cancelRequested = false
        lastError = nil
        lastSummary = nil
        activity.beginRun()
        let startedAt = Date()
        var overallDone = 0
        var summary = Summary()

        if !tagPhotos.isEmpty, tagging.isAvailable {
            // 0 / 0 until the engine has counted photos that still need tags.
            publish(.tagging, done: 0, total: 0, overallDone: overallDone, overallTotal: 0, startedAt: startedAt)
            await tagging.startTagging()
            await waitForStart({ self.tagging.isRunning })
            while tagging.isRunning {
                let p = tagging.progress
                publish(
                    .tagging,
                    done: p?.done ?? 0,
                    total: p?.total ?? 0,
                    overallDone: overallDone + (p?.done ?? 0),
                    overallTotal: p?.total ?? 0,
                    startedAt: startedAt
                )
                try? await Task.sleep(for: .milliseconds(200))
            }
            summary.tagging = tagging.lastSummary
            overallDone += tagging.lastSummary?.processed ?? 0
            if let err = tagging.lastError, err != .cancelled {
                lastError = err.message
            }
        }

        if cancelRequested {
            summary.cancelled = true
            await end(summary)
            return
        }

        if !facePhotos.isEmpty, faces.isAvailable {
            publish(.faces, done: 0, total: 0, overallDone: overallDone, overallTotal: 0, startedAt: startedAt)
            await faces.startScan()
            await waitForStart({ self.faces.isRunning })
            while faces.isRunning {
                let p = faces.progress
                publish(
                    .faces,
                    done: p?.done ?? 0,
                    total: p?.total ?? 0,
                    overallDone: overallDone + (p?.done ?? 0),
                    overallTotal: p?.total ?? 0,
                    startedAt: startedAt
                )
                try? await Task.sleep(for: .milliseconds(200))
            }
            summary.faces = faces.lastSummary
            overallDone += faces.lastSummary?.processed ?? 0
            if let err = faces.lastError, err != .cancelled {
                lastError = err.message
            }
        }

        if cancelRequested {
            summary.cancelled = true
            await end(summary)
            return
        }

        if !placePhotos.isEmpty {
            publish(.places, done: 0, total: placePhotos.count, overallDone: overallDone, overallTotal: placePhotos.count, startedAt: startedAt)
            async let placeSummary = places.geocode(placePhotos, force: force)
            await waitForStart({ self.places.isRunning })
            while places.isRunning {
                let p = places.progress
                publish(
                    .places,
                    done: p?.done ?? 0,
                    total: p?.total ?? placePhotos.count,
                    overallDone: overallDone + (p?.done ?? 0),
                    overallTotal: p?.total ?? placePhotos.count,
                    startedAt: startedAt
                )
                try? await Task.sleep(for: .milliseconds(200))
            }
            summary.places = await placeSummary
            if let err = places.lastError {
                lastError = err
            }
        }

        summary.cancelled = cancelRequested
            || (summary.tagging?.cancelled ?? false)
            || (summary.faces?.cancelled ?? false)
            || (summary.places?.cancelled ?? false)
        await end(summary)
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        tagging.cancel()
        faces.cancel()
        places.cancel()
    }

    private func end(_ summary: Summary) async {
        // Stay `isRunning` through the cluster refresh and the final light
        // rescan this run owes, so `LibraryRootMonitor` keeps ignoring the
        // sidecar writes that just landed. Flipping the flag first is what
        // let a queued vnode hop start another walk the moment we finished.
        // `defer` so a cancellation mid-refresh cannot leave the flag stuck.
        finish(summary)
        defer {
            isRunning = false
            activePhases = []
            cancelRequested = false
        }
        // A tagging-only or places-only run never hits FaceService.finish(),
        // which is otherwise the publisher for `allClusters`. The face phase
        // already refreshed and dropped its session, so this reopens briefly.
        await faces.refreshClusters()
        await faces.unloadSession()
        await onSidecarsWritten?()
    }

    private func finish(_ summary: Summary) {
        progress = nil
        lastSummary = summary
        Log.ml.info(
            "Library analysis finished cancelled=\(summary.cancelled) tagging=\(summary.tagging?.processed ?? 0) faces=\(summary.faces?.processed ?? 0) places=\(summary.places?.processed ?? 0)"
        )
    }

    private func publish(
        _ phase: Phase,
        done: Int,
        total: Int,
        overallDone: Int,
        overallTotal: Int,
        startedAt: Date
    ) {
        progress = Progress(
            phase: phase,
            done: done,
            total: total,
            overallDone: overallDone,
            overallTotal: overallTotal,
            startedAt: startedAt
        )
    }

    /// `start` returns after spawning the core thread; give that assignment a
    /// moment to land so the wait loop does not see a false idle.
    private func waitForStart(_ running: @MainActor () -> Bool) async {
        for _ in 0..<25 where !running() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
