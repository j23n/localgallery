import Darwin
import Foundation

/// Watches the library folder while the app is foregrounded and turns disk
/// mutations into a light silent rescan.
///
/// Scans already run on launch, foreground, pull-to-refresh, Settings, and
/// tagging sidecar writes. Syncthing / Files deletions while Collections is
/// on screen never hit any of those, so the rail stayed stale until the next
/// foreground. This is the missing signal.
///
/// Two observers, one coalescer:
///   - vnode sources on **directories only** (the root plus every folder in
///     the last published tree). Watching each JPEG would exhaust the fd
///     table on a 20k library and fire on every write Syncthing does.
///   - `NSFilePresenter` on the bookmarked root, which is what still fires
///     when a file-provider remounts a folder `open(O_EVTONLY)` could not.
///
/// The coalescer is **not** the tagging/faces 30 s instance. That window is a
/// budget for interrupting the user with a rescan of sidecar writes; a
/// deletion has to land in about a second or the user is looking at a ghost.
@MainActor
final class LibraryRootMonitor {
    /// Tight enough that a Files deletion appears while Collections is still
    /// on screen; wide enough that a Syncthing burst is one rescan, not one
    /// per file.
    static let refreshInterval: TimeInterval = 1.5

    /// Separate from the tagging/faces coalescer — see the type comment.
    let coalescer: SidecarRefreshCoalescer

    /// False after `stop()` so a presenter callback that was already queued
    /// cannot restart a watch we just tore down for backgrounding.
    private var isWatching = false

    /// Dedicated queue so presenter callbacks are not MainActor. The
    /// presenter hops; this queue only serialises the NSFilePresenter
    /// contract that all callbacks arrive on `presentedItemOperationQueue`.
    private let presenterQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LocalGallery.LibraryRootPresenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// Vnode callbacks are hopped to MainActor before `coalescer.note()`.
    /// Keeping them off main means a Syncthing burst does not land as N
    /// main-queue blocks; the coalescer is what bounds the rescan.
    private let vnodeQueue = DispatchQueue(label: "LocalGallery.LibraryRootMonitor.vnode")

    /// `nonisolated(unsafe)` so the implicit-nonisolated deinit can uninstall
    /// the presenter and cancel sources. Mutations happen only from
    /// `@MainActor` methods, so deinit observes a stable last-written value.
    private nonisolated(unsafe) var presenter: LibraryRootPresenter?
    private nonisolated(unsafe) var vnodeSources: [any DispatchSourceFileSystemObject] = []

    init() {
        self.coalescer = SidecarRefreshCoalescer(interval: Self.refreshInterval)
    }

    deinit {
        // `@MainActor` deinit is nonisolated, so we cannot call `stop()`.
        // Presenter removal and `DispatchSource.cancel()` are thread-safe;
        // the cancel handler is what closes the fd.
        Self.uninstall(presenter: presenter, sources: vnodeSources)
    }

    /// Thumbnail cells that fail because the source file is gone. Already
    /// coalesced: a scrolling grid can fire this once per missing cell.
    func noteSourceMissing() {
        coalescer.note()
    }

    /// Stop previous sources, then watch `root` plus every folder in `tree`.
    /// Idempotent. `tree` may be nil (root gone / unlistable) — we still
    /// present on the bookmark URL so a remount can fire.
    func sync(root: URL, tree: PhotoFolder?) {
        stop()
        let urls = Self.watchURLs(root: root, tree: tree)
        isWatching = true
        startPresenter(on: root)
        for url in urls {
            startVnode(on: url)
        }
        Log.fs.info("Watching \(self.vnodeSources.count) directories (of \(urls.count) in tree)")
    }

    func stop() {
        guard isWatching || presenter != nil || !vnodeSources.isEmpty else { return }
        let count = vnodeSources.count
        isWatching = false
        Log.fs.info("Stopped library watcher (\(count) directories)")
        Self.uninstall(presenter: presenter, sources: vnodeSources)
        presenter = nil
        vnodeSources = []
    }

    /// Root plus every folder URL in the last published tree, de-duplicated.
    /// Directories only — photo files are not watched.
    nonisolated static func watchURLs(root: URL, tree: PhotoFolder?) -> [URL] {
        var ordered: [URL] = [root]
        if let tree {
            ordered.append(contentsOf: tree.directoryURLs())
        }
        var seen = Set<String>()
        return ordered.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    // MARK: - Presenter

    private func startPresenter(on root: URL) {
        let onEvent: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePresentedEvent()
            }
        }
        let presenter = LibraryRootPresenter(
            url: root,
            queue: presenterQueue,
            onEvent: onEvent
        )
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    private func handlePresentedEvent() {
        guard isWatching else { return }
        Log.fs.debug("NSFilePresenter event")
        coalescer.note()
    }

    // MARK: - Vnodes

    private func startVnode(on url: URL) {
        // O_EVTONLY is the kqueue-watch open: we never read the directory,
        // we just want vnode notifications. `open` failing is the folder
        // gone case — skip this path; the presenter still covers remount.
        let fd = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return open(ptr, O_EVTONLY)
        }
        guard fd >= 0 else {
            Log.fs.debug("open(O_EVTONLY) failed for \(Log.r.path(url)); skipping vnode")
            return
        }

        let mask: DispatchSource.FileSystemEvent = [
            .write, .delete, .rename, .extend, .attrib, .link
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: mask,
            queue: vnodeQueue
        )
        // Hop via a Sendable raw value: `DispatchSource.FileSystemEvent` is
        // not Sendable, and this handler runs on `vnodeQueue`, which is not
        // MainActor. `UInt` is, and that is all the OptionSet is.
        source.setEventHandler { [unowned source] in
            let raw = source.data.rawValue
            Task { @MainActor [weak self] in
                self?.handleVnode(
                    url: url,
                    events: DispatchSource.FileSystemEvent(rawValue: raw)
                )
            }
        }
        // The source does not dup the fd. Closing it anywhere else leaks or
        // double-closes; cancel is the one owner.
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        vnodeSources.append(source)
    }

    private func handleVnode(url: URL, events: DispatchSource.FileSystemEvent) {
        guard isWatching else { return }
        Log.fs.debug("vnode \(Self.describe(events)) \(Log.r.path(url))")
        coalescer.note()
    }

    nonisolated private static func describe(_ events: DispatchSource.FileSystemEvent) -> String {
        var names: [String] = []
        if events.contains(.write) { names.append("write") }
        if events.contains(.delete) { names.append("delete") }
        if events.contains(.rename) { names.append("rename") }
        if events.contains(.extend) { names.append("extend") }
        if events.contains(.attrib) { names.append("attrib") }
        if events.contains(.link) { names.append("link") }
        if events.contains(.revoke) { names.append("revoke") }
        return names.isEmpty ? "unknown" : names.joined(separator: "|")
    }

    nonisolated private static func uninstall(
        presenter: LibraryRootPresenter?,
        sources: [any DispatchSourceFileSystemObject]
    ) {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        for source in sources {
            source.cancel()
        }
    }
}

// MARK: - Presenter

/// NSFilePresenter callbacks arrive on `presentedItemOperationQueue`, which
/// is not the main actor. Do not mark this `@MainActor` — hop instead.
///
/// Stored state is the presented URL, the serial queue the system calls us
/// on, and a `@Sendable` hop. Nothing here is isolated, so the hop is the
/// only way `coalescer.note()` (MainActor) runs.
private final class LibraryRootPresenter: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onEvent: @Sendable () -> Void

    init(url: URL, queue: OperationQueue, onEvent: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.presentedItemOperationQueue = queue
        self.onEvent = onEvent
        super.init()
    }

    func presentedItemDidChange() {
        onEvent()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        onEvent()
    }

    func presentedSubitemDidAppear(at _: URL) {
        onEvent()
    }

    func presentedSubitemDidChange(at _: URL) {
        onEvent()
    }

    func presentedSubitem(at _: URL, didMoveTo _: URL) {
        onEvent()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
        onEvent()
    }

    func accommodatePresentedSubitemDeletion(at _: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
        onEvent()
    }
}
