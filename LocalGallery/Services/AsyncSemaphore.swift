/// Counting semaphore for bounding TaskGroup / ad-hoc task parallelism.
/// Used to gate concurrent ImageIO decodes (`ThumbnailService`), sidecar
/// fetches (`SidecarSyncService`), and metadata reads (`EnrichmentService`)
/// so fast scrolling or a 25k-photo enrichment can't exhaust the IOSurface
/// pool or saturate file-provider I/O.
///
/// Always pair `acquire()`/`release()` — typically `await sem.acquire()`,
/// `defer`-less because `release()` is async; call it on both the success
/// and error paths.
actor AsyncSemaphore {
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
