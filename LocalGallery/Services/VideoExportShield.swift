import BackgroundTasks
import Foundation

/// Keeps the slideshow video export alive when the user backgrounds the app
/// mid-render. `CollectionsView.startRender` still owns the render task —
/// the shield only asks the system to track it as a
/// `BGContinuedProcessingTask` (live system progress UI + continued runtime)
/// and forwards the system's expiration/cancel back into the render. When
/// the system declines the request, the render runs unshielded — exactly the
/// pre-iOS-26 behaviour, where backgrounding suspends the encode.
///
/// Single-slot by design: the rendering overlay in `CollectionsView` already
/// serialises exports to one at a time. The identifier must stay listed in
/// `BGTaskSchedulerPermittedIdentifiers` (project.yml), and registration
/// happens in `AppDelegate.didFinishLaunchingWithOptions` alongside the
/// refresh tasks.
@available(iOS 26.0, *)
@MainActor
final class VideoExportShield {
    static let shared = VideoExportShield()

    nonisolated static let taskIdentifier = "com.j23n.localgallery.app.videoExport"

    /// The system task, once delivered. Submission → delivery is async, so
    /// a fast render can finish first; see `pendingOutcome`.
    private var task: BGContinuedProcessingTask?
    /// Cancels the in-flight render. Non-nil exactly while an export is
    /// shielded; doubles as the "is an export in flight" flag.
    private var onExpiration: (@MainActor () -> Void)?
    /// Set when `end(success:)` arrives before the system delivered the
    /// task — `adopt` then completes the task immediately.
    private var pendingOutcome: Bool?
    /// True between a successful submit and the task's delivery.
    private var awaitingTask = false
    /// Last reported render progress (0…1), replayed onto a late-arriving task.
    private var fraction: Double = 0

    /// Ask the system to track the export that is about to start. Failure is
    /// non-fatal — the render proceeds in-app either way.
    func begin(title: String, onExpiration: @escaping @MainActor () -> Void) {
        self.onExpiration = onExpiration
        pendingOutcome = nil
        fraction = 0
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: title,
            subtitle: "Rendering slideshow video"
        )
        // The render starts immediately in-app regardless of the shield, so
        // a queued (deferred) launch would have nothing left to do.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            awaitingTask = true
        } catch {
            Log.bg.info("Continued-processing submit declined: \(Log.r.error(error))")
            self.onExpiration = nil
        }
    }

    /// Mirror render progress into the system task UI.
    func report(progress: Double) {
        fraction = progress
        task?.progress.completedUnitCount = Int64((progress * 100).rounded())
    }

    /// The render finished (or failed / was cancelled). Completes the system
    /// task, or arms `pendingOutcome` if it hasn't been delivered yet.
    func end(success: Bool) {
        onExpiration = nil
        if let task {
            task.setTaskCompleted(success: success)
            self.task = nil
        } else if awaitingTask {
            pendingOutcome = success
        }
    }

    /// Launch-handler target, called when the system delivers the task.
    func adopt(_ task: BGContinuedProcessingTask) {
        guard awaitingTask else {
            // Stale delivery with no export in flight.
            task.setTaskCompleted(success: false)
            return
        }
        awaitingTask = false
        if let outcome = pendingOutcome {
            // Render already finished while the delivery was in flight.
            pendingOutcome = nil
            task.setTaskCompleted(success: outcome)
            return
        }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64((fraction * 100).rounded())
        task.expirationHandler = {
            Task { @MainActor in
                Self.shared.expire()
            }
        }
        self.task = task
    }

    /// System pulled the runtime (or the user cancelled from the system UI):
    /// cancel the render. Its completion path calls `end(success:)`, which
    /// reports task completion.
    private func expire() {
        Log.bg.warning("Video export continued-processing task expired")
        let handler = onExpiration
        onExpiration = nil
        handler?()
    }
}
