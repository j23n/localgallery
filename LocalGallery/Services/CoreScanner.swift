import Foundation
import os
import os.lock

/// The app's side of the Rust scanner: the provider probe the core calls back
/// into, and the bridge that turns a `ScanOutcomeRecord` into the app's own
/// `PhotoFile` / `PhotoFolder` values.
///
/// Replaces `FolderScanner`. Scan *policy* — light/full/auto resolution, the
/// 48-hour promotion, request dedupe, the two-phase ordering, and the
/// sidecar-sync / memories / widget steps that follow — is untouched and still
/// lives in `GalleryStore+Scanning.swift`. This type walks nothing and decides
/// nothing; it hands the core a root and hands the Store back a result in the
/// shape it already consumed.
///
/// One instance per Store. It holds no scan state between calls: the cache goes
/// in with each request and the outcome comes straight back out, exactly as
/// `FolderScanner.scan(cachedPhotos:…)` did.
final class CoreScanner: Sendable {

    /// What one pass produced. Field-for-field the old `FolderScanner.Result`,
    /// so `runScanPass` reads the same.
    struct Result: Sendable {
        let rootFolder: PhotoFolder?
        let flatPhotos: [PhotoFile]
        let needsEnrichment: Bool
        let sidecarManifest: [SidecarCandidate]
        /// URLs present in the scan but not in `cachedPhotos`.
        let addedURLs: [URL]
        /// URLs present in `cachedPhotos` but absent from the scan.
        let removedURLs: [URL]
        /// URLs whose `fileSize` or `fileModificationDate` changed since the
        /// cache. Disjoint from `addedURLs`.
        let modifiedURLs: [URL]
        /// Standardized paths of directories whose listing threw a *transient*
        /// error (`PermissionDenied`, other I/O). Photos under them are absent
        /// from `flatPhotos`/`removedURLs` — the Store carries the cached
        /// entries forward so a provider hiccup doesn't wipe a subtree's tags
        /// and enrichment. `NotFound` is not listed here: those photos appear
        /// in `removedURLs`, and a missing root arrives as `rootFolder == nil`.
        let failedDirectoryPaths: [String]
        /// The pass produced no outcome at all: the core threw instead of
        /// answering — a cancelled walk, or an unreadable snapshot.
        ///
        /// **This is not "the scan found nothing".** The two have the same
        /// shape — empty photos, no tree — and opposite meanings, and the Store
        /// publishes one of them. An unreadable *directory* is data and arrives
        /// through `failedDirectoryPaths` with the rest of the library intact;
        /// this flag says the value carries no information about the library,
        /// so `runScanPass` returns before it can reach `apply(_:)`.
        let didNotComplete: Bool

        /// A pass that never produced an answer. Every field is empty *and*
        /// `didNotComplete` is set, so a caller that ignores the flag still
        /// cannot mistake it for a scan of an empty folder — it will publish
        /// an empty library, which is exactly what the flag exists to stop.
        static let incomplete = Result(
            rootFolder: nil, flatPhotos: [], needsEnrichment: false,
            sidecarManifest: [], addedURLs: [], removedURLs: [],
            modifiedURLs: [], failedDirectoryPaths: [], didNotComplete: true
        )
    }

    private let session: ScannerSession
    private let providerProbe = CoreProviderProbe()

    /// The probe this scanner resolved the tree kind on. Exposed so
    /// `CoreScannerBridgeTests` can assert *which URL* the answer came from —
    /// the thing that was wrong before and that no other observable shows.
    var providerProbeForTesting: CoreProviderProbe { providerProbe }

    init() {
        session = ScannerSession(probe: providerProbe)
    }

    /// Walk `rootURL` and produce the tree, the flat list, and the diff.
    ///
    /// - Parameters:
    ///   - cachedPhotos: URL → previous-scan `PhotoFile`. Carries EXIF / tags /
    ///     GPS / locality forward.
    ///   - cachedSidecarManifest: photoID → previous-scan `SidecarCandidate`.
    ///     A hit here is what lets a light scan skip the `.xmp` provider probe
    ///     for an unchanged photo — the single most expensive thing a scan does
    ///     on a provider-backed library.
    ///   - reuseCached: light scan when true; see the blind spot documented on
    ///     `gallery_scan::scan`.
    ///   - onProgress: cumulative photo count, fired from the core's scan
    ///     thread every 500 photos and once at the end. Safe to hop to the main
    ///     actor inside.
    func scan(
        at rootURL: URL,
        cachedPhotos: [URL: PhotoFile] = [:],
        cachedSidecarManifest: [UUID: SidecarCandidate] = [:],
        reuseCached: Bool = false,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> Result {
        // Resolved from the root, once per scan, before any batch runs. Per
        // scan rather than per process because the user can pick a new folder
        // mid-session and an answer cached from the old one would make the new
        // one's placeholders invisible; from the *root* rather than from
        // whichever directory the first batch happens to land in, because that
        // directory is an implementation detail of the traversal order.
        providerProbe.resolveTreeKind(root: rootURL)
        let session = self.session

        // A scan whose Task was cancelled before the FFI call started must not
        // start: `cancel()` names the run in flight, and with none in flight it
        // is deliberately a no-op rather than an ambush on the next run.
        if Task.isCancelled { return .incomplete }

        // The detached task below does not inherit cancellation — that is the
        // point of detaching, and it is why the flag has to be reachable from
        // another thread. `onCancel` hands it to the core, which stops the walk
        // at its next directory boundary and answers `.cancelled`.
        let result = await withTaskCancellationHandler {
            await Self.run(
                session: session, rootURL: rootURL, cachedPhotos: cachedPhotos,
                cachedSidecarManifest: cachedSidecarManifest, reuseCached: reuseCached,
                onProgress: onProgress
            )
        } onCancel: {
            session.cancel()
        }

        // A cancel that lands between the core's last directory boundary and
        // its return produces a *complete* outcome for a scan the caller no
        // longer wants. Discard it: the caller cancelled because the state it
        // scanned against is gone, and publishing a result it did not ask for
        // is the failure mode this whole flag exists to prevent. Losing a
        // finished scan is the cheap direction.
        return Task.isCancelled ? .incomplete : result
    }

    private static func run(
        session: ScannerSession,
        rootURL: URL,
        cachedPhotos: [URL: PhotoFile],
        cachedSidecarManifest: [UUID: SidecarCandidate],
        reuseCached: Bool,
        onProgress: (@Sendable (Int) -> Void)?
    ) async -> Result {
        return await Task.detached(priority: .userInitiated) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let request = ScanRequest(
                reuseCached: reuseCached,
                cachedPhotos: cachedPhotos.values.map(Self.record(of:)),
                cachedSidecarManifest: cachedSidecarManifest.values.map(Self.row(of:))
            )
            let marshalledAt = CFAbsoluteTimeGetCurrent()

            let outcome: ScanOutcomeRecord
            do {
                outcome = try session.scan(
                    root: rootURL.path,
                    request: request,
                    progress: onProgress.map(ProgressBridge.init)
                )
            } catch {
                // A missing root is data, not an error: empty `folders`, no
                // failed-directory entry, `rootFolder == nil`. An unlistable
                // root (permission/provider) still arrives as
                // `failedDirectoryPaths` with an empty tree. Reaching here
                // means the core produced no answer at all — a cancelled walk
                // today — and an empty answer is indistinguishable from "the
                // library is now empty". `.incomplete` is how the Store tells
                // them apart.
                Log.scan.error("core scan failed: \(Log.r.error(error))")
                return .incomplete
            }
            let scannedAt = CFAbsoluteTimeGetCurrent()
            let result = Self.bridge(outcome)
            let builtAt = CFAbsoluteTimeGetCurrent()

            // The core does not own logging, so the one place an unreadable
            // directory becomes visible to a human is here. It matters: every
            // photo under such a directory is being carried forward on trust,
            // and a subtree that stays unreadable across scans is a real
            // problem wearing a "no changes" costume.
            if !result.failedDirectoryPaths.isEmpty {
                let listed = result.failedDirectoryPaths.prefix(5)
                    .map { Log.r.path($0) }
                    .joined(separator: ", ")
                Log.scan.warning("""
                    \(result.failedDirectoryPaths.count) unreadable \
                    director\(result.failedDirectoryPaths.count == 1 ? "y" : "ies"): \(listed)\
                    \(result.failedDirectoryPaths.count > 5 ? ", …" : "")
                    """)
            }
            if outcome.timings.probeMismatches > 0 {
                Log.scan.error("""
                    \(outcome.timings.probeMismatches) provider probe batches answered the wrong \
                    number of rows and were discarded — those directories were scanned as plain \
                    local storage
                    """)
            }

            // Same shape as the line `_plans/06-performance-baseline.md`
            // measures the acceptance gates from, so the harness keeps working
            // across the port. `core` is time inside Rust; `in`/`out` are the
            // two record marshals, which is the number that decides whether the
            // FFI payload strategy needs revisiting.
            let ms = { (a: CFAbsoluteTime, b: CFAbsoluteTime) in String(format: "%.0f", (b - a) * 1000) }
            let t = outcome.timings
            Log.scan.info("""
                Scan totals: \(outcome.flatPhotos.count) files in \(t.folders) folders, \
                total=\(ms(startedAt, builtAt))ms core=\(t.totalMillis)ms list=\(t.listMillis)ms \
                probe=\(t.probeMillis)ms probed=\(t.probedPaths) batches=\(t.probeBatches) \
                hits=\(t.cacheHits) slow=\(t.slowPath) \
                in=\(ms(startedAt, marshalledAt))ms out=\(ms(scannedAt, builtAt))ms \
                ffi=\(ms(marshalledAt, scannedAt))ms reuseCached=\(reuseCached)
                """)
            return result
        }.value
    }

    /// Ask an in-flight walk to stop.
    ///
    /// `scan(at:…)` already wires this to its own `Task`'s cancellation, so
    /// cancelling the Store's scan task is enough; this stays for a caller that
    /// holds the scanner but not the task.
    func cancel() {
        session.cancel()
    }

    // MARK: - Progress

    /// Bridges the core's foreign trait to a plain `@Sendable` closure. Holds
    /// nothing but the closure, so it cannot capture the Store.
    private final class ProgressBridge: ScanProgressListener {
        private let handler: @Sendable (Int) -> Void
        init(_ handler: @escaping @Sendable (Int) -> Void) { self.handler = handler }
        func onProgress(discovered: UInt32) { handler(Int(discovered)) }
    }

    // MARK: - Bridging out

    private static func bridge(_ outcome: ScanOutcomeRecord) -> Result {
        let photos = outcome.flatPhotos.map(photo(from:))
        return Result(
            rootFolder: folderTree(outcome.folders, photos: photos),
            flatPhotos: photos,
            needsEnrichment: outcome.needsEnrichment,
            sidecarManifest: outcome.sidecarManifest.map(candidate(from:)),
            addedURLs: outcome.addedPaths.map(fileURL(_:)),
            removedURLs: outcome.removedPaths.map(fileURL(_:)),
            modifiedURLs: outcome.modifiedPaths.map(fileURL(_:)),
            failedDirectoryPaths: outcome.failedDirectoryPaths,
            didNotComplete: false
        )
    }

    /// A file URL whose `path` is byte-for-byte the string it was built from.
    ///
    /// **Not** `URL(fileURLWithPath:)`, which DECOMPOSES its input
    /// (`PathNormalizationTests`). An externally-created NFC filename would
    /// come back NFD, `PhotoFile.stableID` hashes `standardized.path`, and the
    /// photo would land under a different id than the core just derived for it
    /// — a silent identity split on exactly the files that arrive from other
    /// systems. Percent-encoding round-trips the scalars intact and measures
    /// the same (~1 µs/path over a 20k library).
    static func fileURL(_ path: String) -> URL {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "file://" + encoded) else {
            return URL(fileURLWithPath: path)
        }
        return url
    }

    private static func photo(from record: ScanPhoto) -> PhotoFile {
        PhotoFile(
            id: UUID(uuidString: record.id) ?? PhotoFile.stableID(for: fileURL(record.path)),
            url: fileURL(record.path),
            filename: record.filename,
            fileSize: record.fileSize,
            dateTaken: record.dateTaken.map(Date.init(timeIntervalSinceReferenceDate:)),
            dateFromMetadata: record.dateFromMetadata,
            isVideo: record.isVideo,
            livePhotoVideoURL: record.livePhotoVideoPath.map(fileURL(_:)),
            hierarchicalTags: record.hierarchicalTags.map {
                HierarchicalTag(fullPath: $0.fullPath, namespace: $0.namespace, displayName: $0.displayName)
            },
            countryCode: record.countryCode,
            enrichedFileDate: record.enrichedFileDate.map(Date.init(timeIntervalSinceReferenceDate:)),
            fileModificationDate: record.fileModificationDate.map(Date.init(timeIntervalSinceReferenceDate:)),
            gpsLatitude: record.gpsLatitude,
            gpsLongitude: record.gpsLongitude,
            faceRegions: record.faceRegions.map {
                FaceRegion(name: $0.name, centerX: $0.centerX, centerY: $0.centerY,
                           width: $0.width, height: $0.height)
            },
            locality: {
                switch record.locality {
                case .local: return .local
                case .remote(let downloaded): return .remote(downloaded: downloaded)
                }
            }()
        )
    }

    /// Rebuild the recursive tree from the core's flat node list.
    ///
    /// The core sends folders flat, each carrying a parent index and a
    /// `(photoStart, photoCount)` slice of `flatPhotos`, because `PhotoFolder`
    /// owns its photos by value and shipping both shapes would put every photo
    /// on the wire twice. Nodes always precede their children, so one reverse
    /// pass assembles the tree with no repeated work.
    private static func folderTree(_ nodes: [ScanFolderNode], photos: [PhotoFile]) -> PhotoFolder? {
        guard !nodes.isEmpty else { return nil }
        var childrenByParent: [Int: [Int]] = [:]
        for (index, node) in nodes.enumerated() {
            guard let parent = node.parentIndex else { continue }
            childrenByParent[Int(parent), default: []].append(index)
        }
        var built: [Int: PhotoFolder] = [:]
        for index in nodes.indices.reversed() {
            let node = nodes[index]
            let start = Int(node.photoStart)
            let end = min(start + Int(node.photoCount), photos.count)
            built[index] = PhotoFolder(
                id: UUID(uuidString: node.id) ?? PhotoFolder.stableID(for: fileURL(node.path)),
                url: fileURL(node.path),
                name: node.name,
                subfolders: (childrenByParent[index] ?? []).compactMap { built[$0] },
                photos: start < end ? Array(photos[start..<end]) : [],
                coverPhotoURL: node.coverPhotoPath.map(fileURL(_:)),
                totalPhotoCount: Int(node.totalPhotoCount),
                dateModified: node.dateModified.map(Date.init(timeIntervalSinceReferenceDate:)),
                dateCreated: node.dateCreated.map(Date.init(timeIntervalSinceReferenceDate:))
            )
        }
        return built[0]
    }

    private static func candidate(from row: ScanSidecarRow) -> SidecarCandidate {
        SidecarCandidate(
            photoID: UUID(uuidString: row.photoId) ?? PhotoFile.stableID(
                for: fileURL(String(row.sidecarPath.dropLast(".xmp".count)))
            ),
            sidecarURL: fileURL(row.sidecarPath),
            currentVersion: FileProviderDetector.ContentVersion(
                contentIdentifier: row.currentVersion.contentIdentifier,
                modificationDate: row.currentVersion.modificationDate
                    .map(Date.init(timeIntervalSinceReferenceDate:)),
                size: row.currentVersion.size
            ),
            downloadStatus: FileProviderDetector.DownloadStatus(rawValue: row.downloadStatus) ?? .local
        )
    }

    // MARK: - Bridging in

    static func record(of photo: PhotoFile) -> ScanPhoto {
        ScanPhoto(
            id: photo.id.uuidString,
            path: photo.url.path,
            filename: photo.filename,
            fileSize: photo.fileSize,
            dateTaken: photo.dateTaken?.timeIntervalSinceReferenceDate,
            dateFromMetadata: photo.dateFromMetadata,
            isVideo: photo.isVideo,
            livePhotoVideoPath: photo.livePhotoVideoURL?.path,
            hierarchicalTags: photo.hierarchicalTags.map {
                ScanTag(fullPath: $0.fullPath, namespace: $0.namespace, displayName: $0.displayName)
            },
            countryCode: photo.countryCode,
            enrichedFileDate: photo.enrichedFileDate?.timeIntervalSinceReferenceDate,
            fileModificationDate: photo.fileModificationDate?.timeIntervalSinceReferenceDate,
            gpsLatitude: photo.gpsLatitude,
            gpsLongitude: photo.gpsLongitude,
            faceRegions: photo.faceRegions.map {
                ScanRegion(name: $0.name, centerX: $0.centerX, centerY: $0.centerY,
                           width: $0.width, height: $0.height)
            },
            locality: {
                switch photo.locality {
                case .local: return .local
                case .remote(let downloaded): return .remote(downloaded: downloaded)
                }
            }()
        )
    }

    static func row(of candidate: SidecarCandidate) -> ScanSidecarRow {
        ScanSidecarRow(
            photoId: candidate.photoID.uuidString,
            sidecarPath: candidate.sidecarURL.path,
            currentVersion: ScanContentVersion(
                contentIdentifier: candidate.currentVersion.contentIdentifier,
                modificationDate: candidate.currentVersion.modificationDate?
                    .timeIntervalSinceReferenceDate,
                size: candidate.currentVersion.size
            ),
            downloadStatus: candidate.downloadStatus.rawValue
        )
    }
}

// MARK: - The provider probe

/// The one thing the core cannot do for itself: read the `URLResourceKey`s that
/// say whether a file is provider-backed, whether its bytes are here, and what
/// its content identifier is.
///
/// # Why this exists, and why it fans out
///
/// `FileProviderDetector.probe(_:)` is a single `resourceValues(forKeys:)` with
/// seven ubiquitous-item keys — one blocking XPC round trip to `fileproviderd`,
/// **~11 ms**, whatever the file. Run serially over the ~37k photos and sidecars
/// of a 20k-photo library that was 403 s of a 406 s cold scan
/// (`_plans/06-performance-baseline.md` Finding 1). The scan is latency-bound,
/// not CPU-bound: `sample` showed the thread parked in `mach_msg2_trap`.
///
/// # What actually fixed it, and what did not
///
/// Finding 1 proposed fanning the probes out across a bounded task group and
/// expected 406 s → 30–60 s. **Measured, that does nothing.** At width 16 over
/// the 20k library the scan took *512 s* — slower than serial. `sample` showed
/// all 16 threads parked in `mach_msg2_trap` inside `resourceValues`, and the
/// arithmetic is unambiguous: each probe went from ~11 ms to ~220 ms, exactly
/// 16× plus contention overhead. Throughput was flat, so the round trip is
/// serialised somewhere neither the app nor the thread count can reach.
///
/// What works is asking **fewer times**. `contentsOfDirectory(at:
/// includingPropertiesForKeys:)` fetches the provider keys for a whole
/// directory in one call and hands back URLs carrying the cached values, so a
/// per-file `resourceValues` on one of *those* URLs is a memory read rather
/// than a round trip. That turns ~37k round trips into ~100 — one per
/// directory — and it is why this type takes a batch instead of a path.
///
/// (`FolderScanner` had a comment saying this prefetch was broken on iOS 26 +
/// security-scoped bookmarks. That was observed for plain stat keys —
/// `fileSize`, `contentModificationDate` — which the scanner no longer asks
/// Foundation for at all; the core reads those through `read_dir`. The
/// ubiquitous-item keys are a different provider path, and they do cache.)
///
/// The fan-out is kept underneath, because it is free once the values are
/// cached and it still helps on the fallback path where a URL was not in the
/// prefetch. **Determinism is preserved by construction**: results are written
/// into positional slots, so the answers come back in the order the core asked
/// for them however the threads interleaved.
final class CoreProviderProbe: ProviderProbe {

    /// How many `resourceValues` reads are in flight at once.
    ///
    /// Benchmarked at 1 / 16 against the 20k fixture library on the simulator;
    /// with the directory prefetch in place the reads are cache hits and the
    /// width stops mattering (see `_plans/06-performance-baseline.md`). Kept at
    /// 16 for the uncached fallback, and overridable at runtime so the
    /// measurement can be repeated without a rebuild:
    ///
    ///     xcrun simctl spawn booted defaults write \
    ///       com.j23n.localgallery.app coreProbeFanOutWidth -int 32
    static let fanOutWidth: Int = {
        let configured = UserDefaults.standard.integer(forKey: "coreProbeFanOutWidth")
        return configured > 0 ? min(configured, 64) : 16
    }()

    /// Below this a batch is not worth a thread hop — most directories in a
    /// real library hold a handful of files.
    private static let fanOutThreshold = 4

    private static let queue = DispatchQueue(
        label: "com.j23n.localgallery.provider-probe",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Positional result slots, written from the stripe threads.
    ///
    /// `@unchecked Sendable` with an explicit lock: the stripes touch disjoint
    /// indices, which is safe but not something the compiler can see, and a
    /// lock costs ~20 ns against a ~20 ms probe.
    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [VfsProviderAttrs?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func set(_ value: VfsProviderAttrs, at index: Int) {
            lock.lock(); values[index] = value; lock.unlock()
        }
        func take() -> [VfsProviderAttrs] {
            lock.lock(); defer { lock.unlock() }
            // An unwritten slot cannot happen — the stripes tile the array —
            // but the type says it can, and "plain local file" is the same
            // answer a failed probe gives.
            return values.map {
                $0 ?? VfsProviderAttrs(isFileProvider: false, isPlaceholder: false,
                                       contentVersion: nil, intendedSize: nil)
            }
        }
    }

    func probe(paths: [String]) -> [VfsProviderAttrs] {
        guard !paths.isEmpty else { return [] }
        // Unresolved reads as ubiquitous: the expensive keys are the ones that
        // find placeholders, and skipping them on a tree that might be
        // provider-backed loses photos' `.remote` state silently. See
        // `resolveTreeKind(root:)`.
        let ubiquitous = treeIsUbiquitous.withLock { $0 } ?? true
        let urls = paths.map(CoreScanner.fileURL)

        guard paths.count >= Self.fanOutThreshold else {
            return urls.map { Self.probeOne($0, ubiquitous: ubiquitous) }
        }
        let width = min(Self.fanOutWidth, urls.count)
        let slots = Slots(count: urls.count)
        let group = DispatchGroup()
        for stripe in 0..<width {
            Self.queue.async(group: group) {
                var index = stripe
                while index < urls.count {
                    slots.set(Self.probeOne(urls[index], ubiquitous: ubiquitous), at: index)
                    index += width
                }
            }
        }
        group.wait()
        return slots.take()
    }

    /// Whether the tree being scanned is an iCloud (ubiquitous) one.
    ///
    /// When it is false the per-file probe drops the three ubiquitous keys —
    /// the expensive ones — and rests on `totalFileSize > fileSize`, which is
    /// the branch every non-Apple provider already took, so placeholder
    /// detection on Dropbox / OneDrive / Drive is unaffected. On a genuinely
    /// ubiquitous tree nothing changes: the full seven-key read happens as
    /// before, and the scan is as slow as it always was. That is the honest
    /// trade — the saving is entirely "stop asking a local file 37,000 times
    /// whether it is in the cloud".
    private let treeIsUbiquitous = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// The resolved answer, or `nil` before a scan has asked for one.
    ///
    /// Exposed only so `CoreScannerBridgeTests` can pin the fail-closed rule:
    /// the alternative is asserting on a log line, and getting this wrong is
    /// invisible in every other observable — the scan simply becomes fast and
    /// stops noticing placeholders.
    var resolvedTreeIsUbiquitous: Bool? { treeIsUbiquitous.withLock { $0 } }

    /// Decide, once per scan, whether this tree gets the expensive keys.
    ///
    /// # Two things here are deliberate and both were wrong before
    ///
    /// **The question is asked of the scan root**, not of whatever directory
    /// the first probe batch happens to land in. Which directory that is
    /// depends on traversal order and on which files a light scan decided to
    /// rebuild; letting it decide a library-wide policy made the policy
    /// effectively random.
    ///
    /// **A read that *threw* means "yes"**, not "no" — see
    /// [`treeIsUbiquitous(_:)`], which is where that rule lives and where both
    /// of its branches are testable.
    ///
    /// # The limitation this does not fix
    ///
    /// One answer covers the whole tree. A **mixed** library — a local root
    /// with an iCloud Drive folder symlinked or nested inside it — resolves to
    /// its root's kind, and the ubiquitous subtree then gets the cheap probe.
    /// Its placeholders are still found when the provider populates
    /// `totalFileSize` (all the third-party ones do, and iCloud does too); what
    /// is lost is the `.downloading` / `.stale` distinction, which nothing in
    /// the app reads today. A per-directory answer is the real fix and costs
    /// one `resourceValues` per directory — cheap, but it is a behaviour change
    /// to the probe's cost model that belongs with the Phase-4 work, not with a
    /// bug fix.
    func resolveTreeKind(root: URL) {
        let read: UbiquityRead
        do {
            read = .answered(
                try root.resourceValues(forKeys: FileProviderDetector.ubiquitousKeys)
                    .isUbiquitousItem
            )
        } catch {
            Log.scan.warning("""
                Provider probe: could not read the root's ubiquity — \
                \(Log.r.path(root)): \(Log.r.error(error)); reading all seven keys
                """)
            read = .unreadable
        }
        let resolved = Self.treeIsUbiquitous(read)
        Log.scan.info("Provider probe: tree is ubiquitous = \(resolved) — \(resolved ? "reading all seven keys" : "skipping the three expensive ones")")
        treeIsUbiquitous.withLock { $0 = resolved }
    }

    /// What one `isUbiquitousItem` read said.
    enum UbiquityRead: Equatable {
        /// `resourceValues` threw. Nothing was learned.
        case unreadable
        /// It answered. `nil` means the key was not populated.
        case answered(Bool?)
    }

    /// The rule, isolated so both of its branches can be tested — the failing
    /// one cannot be provoked through the public entry point at all.
    ///
    /// # The two "no answer" cases are not the same, and that is the whole rule
    ///
    /// **A read that threw is unknown, and unknown means yes.** A permission
    /// blip, a provider that has not mounted, a bookmark whose scope was not
    /// started: none of those are "this is local storage", and answering "not
    /// ubiquitous" to them drops the only keys that can see an iCloud
    /// placeholder. Every undownloaded photo would then read as `.local` — no
    /// cloud badge, `ensureMaterialized` never fires, an empty frame in the
    /// viewer. Being slow is the recoverable failure of the two.
    ///
    /// **A read that succeeded with the key absent is a no.** On iOS
    /// `isUbiquitousItem` is simply *not populated* for anything outside iCloud
    /// Drive — measured on the simulator, a plain local directory answers `nil`,
    /// never `false`. Treating that absence as "unknown" too would send every
    /// scan down the seven-key path and undo the whole 406 s → 2.3 s win
    /// (`_plans/06` Finding 1). It is the ordinary case, not a failure.
    static func treeIsUbiquitous(_ read: UbiquityRead) -> Bool {
        switch read {
        case .unreadable:
            return true
        case .answered(let isUbiquitous):
            return isUbiquitous ?? false
        }
    }

    /// One file's provider attributes. A failed read reports "plain local
    /// file", which is what the baseline's `try?` did — a probe that throws
    /// must not make a photo disappear.
    private static func probeOne(_ url: URL, ubiquitous: Bool) -> VfsProviderAttrs {
        let result = FileProviderDetector.probe(url, includeUbiquitousKeys: ubiquitous)
        return VfsProviderAttrs(
            isFileProvider: result.isFileProvider,
            isPlaceholder: result.status != .local,
            contentVersion: result.version.contentIdentifier,
            // `totalFileSize ?? fileSize`, which is exactly what the baseline
            // wrote into `ContentVersion.size`. A placeholder's `stat` size is
            // a stub, and the sidecar cache compares on this field.
            intendedSize: result.version.size
        )
    }
}
