/// Counting semaphore for bounding TaskGroup / ad-hoc task parallelism.
/// Used to gate concurrent ImageIO decodes (`ThumbnailService`), sidecar
/// fetches (`SidecarSyncService`), and metadata reads (`EnrichmentService`)
/// so fast scrolling or a 25k-photo enrichment can't exhaust the IOSurface
/// pool or saturate file-provider I/O.
///
/// Always pair `acquire()`/`release()` — typically `await sem.acquire()`,
/// `defer`-less because `release()` is async; call it on both the success
/// and error paths. `acquire()` is cancellation-aware: a cancelled waiter
/// is resumed (and treated as acquired) so it cannot hang the TaskGroup
/// and a paired `release()` stays balanced.
actor AsyncSemaphore {
    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []
    /// IDs whose cancel handler ran before the waiter was appended.
    private var cancelledIDs: Set<UUID> = []

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        // Already cancelled: take a slot so a paired `release()` is balanced
        // (ThumbnailService and EnrichmentService both release after acquire,
        // including on the cancellation path).
        if Task.isCancelled {
            active += 1
            return
        }
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelledIDs.remove(id) != nil {
                    active += 1
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.noteCancel(id) }
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            active -= 1
        }
    }

    /// Resume a cancelled waiter without leaving it in the queue. Treated as
    /// acquired so the cancelled task's `release()` does not underflow.
    private func noteCancel(_ id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: idx).continuation.resume()
            active += 1
        } else {
            cancelledIDs.insert(id)
        }
    }
}
