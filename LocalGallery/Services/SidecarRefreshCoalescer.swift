import Foundation

/// Turns a burst of "the core just wrote sidecars" notifications into a bounded
/// number of library rescans.
///
/// Both core-owned writers need this and they need it identically, so it lives
/// here rather than twice: `TaggingService` (a 20k-photo tagging run reports
/// every 32 photos) and `FaceService` (the auto-tag pass at the end of a face
/// run, plus every naming action the user takes).
///
/// Two rules, and the second is the one that is easy to get wrong:
///
/// 1. **Coalesce.** `note()` starts a refresh at most once per `interval`.
///    `lastRefreshAt` records when one actually *ran*, so a steady drip of
///    suppressed batches cannot keep pushing the window out — advancing it on a
///    suppressed batch meant partial results never appeared until the run
///    ended.
/// 2. **Drain, never drop.** A request that arrives while a refresh is in
///    flight is remembered and run afterwards. The obvious
///    `guard task == nil else { return }` loses tags: the in-flight rescan may
///    have walked the tree *before* the sidecars that prompted the new request
///    existed, so its manifest cannot contain them and no later trigger would
///    look again. Draining costs at most one extra tree walk per burst.
@MainActor
final class SidecarRefreshCoalescer {
    /// Minimum spacing between the refreshes `note()` triggers. A run always
    /// ends with an unconditional `schedule()`, so this only controls how soon
    /// partial results appear.
    let interval: TimeInterval

    /// What a refresh *is*. Set by the owning service, which wires it to the
    /// Store's light rescan.
    var onRefresh: (@MainActor () async -> Void)?

    /// When a refresh last actually ran — see rule 1.
    private(set) var lastRefreshAt: Date?
    /// The in-flight drain loop, `nil` when idle. Exposed so a caller (and a
    /// test) can await the refresh it just asked for.
    private(set) var task: Task<Void, Never>?
    /// A refresh asked for while one was already in flight.
    private var pending = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// One batch from the core: refresh unless we did so recently.
    func note() {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < interval {
            return
        }
        schedule()
    }

    /// Refresh regardless of the interval — the end of a run, or a user action
    /// whose result has to appear now.
    func schedule() {
        lastRefreshAt = Date()
        guard task == nil else {
            pending = true
            return
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.pending = false
                await self.onRefresh?()
            } while self.pending
            self.task = nil
        }
    }
}
