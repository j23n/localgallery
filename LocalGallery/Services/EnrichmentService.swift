import Foundation
import os

/// Parallel EXIF / XMP / video-date enrichment for photos that lack
/// `enrichedFileDate`. Pure detached-task work over a `[PhotoFile]`
/// snapshot — the Store handles the gate, observed-state assignment,
/// folder-tree merge, and cache write.
///
/// The reads themselves are the Rust core's (`gallery-meta`), reached through
/// `readImageMetadata` / `readVideoDate`. This file owns the
/// scheduling — the task group, the semaphore, the progress throttle, the
/// placeholder skip — and nothing about parsing.
enum EnrichmentService {

    /// Pick the earlier of creation/modification dates.
    ///
    /// Handles AirDrop and chat-saved files where the original modDate is
    /// preserved but `creationDate` reflects the download time on this volume.
    /// Lived on `MetadataReader` until that type moved into the core; it stays
    /// in Swift because the two dates it compares are read here, from
    /// `URLResourceValues`, and shipping a `min()` across the FFI would be
    /// theatre. The core has its own copy for the scanner path
    /// (`AppleDate::earliest`), pinned to the same behaviour by the scanner
    /// conformance fixture.
    static func earliestFilesystemDate(creation: Date?, modification: Date?) -> Date? {
        switch (creation, modification) {
        case let (c?, m?): return min(c, m)
        case let (c?, nil): return c
        case let (nil, m?): return m
        case (nil, nil): return nil
        }
    }

    /// Resolve the core's zone-less EXIF wall clock in the **device** time
    /// zone.
    ///
    /// EXIF capture dates carry no zone, so `MetadataReader.exifDateFormatter`
    /// had none either and the device zone was the reading. The core cannot
    /// make that call — it has no idea what zone the phone is in — so it hands
    /// back the civil fields and the resolution happens here. Gregorian and
    /// POSIX-locale for the same reason the formatter was: a device set to a
    /// Buddhist or Japanese calendar would otherwise resolve the wrong year.
    static func resolve(_ wallClock: WallClock) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(
            year: Int(wallClock.year), month: Int(wallClock.month), day: Int(wallClock.day),
            hour: Int(wallClock.hour), minute: Int(wallClock.minute), second: Int(wallClock.second)
        ))
    }
    /// Where the blocking half of enrichment runs.
    ///
    /// Everything [`read(_:at:)`] does blocks a thread outright:
    /// `resourceValues` is a syscall (an XPC round trip on a provider-backed
    /// volume), and the two core reads open a file and parse it. Doing that on
    /// a cooperative-pool thread parks one of the very few threads Swift
    /// concurrency has — the pool is sized to the core count, the semaphore
    /// allows 8 in flight, and on a 6-core phone that is most of it. The
    /// symptom is not a slow enrichment, it is a *stalled app*: every other
    /// `await` in the process, including the main actor's own continuations,
    /// waits behind file reads.
    ///
    /// Concurrent, and bounded by the caller's `AsyncSemaphore(8)` rather than
    /// by the queue — the same 8 the sidecar sync uses. `.utility` because
    /// enrichment is background work that must not outrank the thumbnail
    /// decodes the user is actually looking at. Same pattern, and the same
    /// reason, as `CoreProviderProbe`'s queue.
    private static let readQueue = DispatchQueue(
        label: "com.j23n.localgallery.enrichment-read",
        qos: .utility,
        attributes: .concurrent
    )

    /// Run `work` on [`readQueue`] and suspend — rather than block — until it
    /// answers.
    private static func readOffPool<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// The blocking half: filesystem dates plus whatever the core can read out
    /// of the file. Synchronous on purpose — it is called through
    /// [`readOffPool`], which is the only place that decides where it runs.
    private static func read(_ photo: PhotoFile, at idx: Int) -> EnrichedResult {
        // One resourceValues call covers both the staleness marker (modDate)
        // and the filesystem-date fallback.
        let attrs = try? photo.url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let modDate = attrs?.contentModificationDate
        let filesystemFallback = earliestFilesystemDate(
            creation: attrs?.creationDate,
            modification: attrs?.contentModificationDate
        )

        if photo.isVideo {
            // Videos: prefer the embedded capture date over filesystem dates,
            // which often reflect the download/AirDrop time rather than when
            // the video was actually recorded.
            //
            // The core reads `moov/udta/©day` itself rather than opening an
            // `AVURLAsset`, and only the `ftyp`/`moov` boxes are pulled off
            // disk — a 4 GB `mdat` is never touched. Behaviour is pinned to
            // AVFoundation's by the metadata conformance fixture, quirks
            // included (QuickTime brand only, zone-less `©day` as UTC).
            var dateTaken = photo.dateTaken
            var dateFromMetadata = false
            if let unixSeconds = readVideoDate(path: photo.url.path) {
                dateTaken = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
                dateFromMetadata = true
            } else if dateTaken == nil {
                dateTaken = filesystemFallback
            }
            return EnrichedResult(
                index: idx,
                dateTaken: dateTaken,
                dateFromMetadata: dateFromMetadata,
                hierarchicalTags: photo.hierarchicalTags,
                countryCode: photo.countryCode,
                gpsLatitude: photo.gpsLatitude,
                gpsLongitude: photo.gpsLongitude,
                enrichedFileDate: modDate ?? Date(),
                faceRegions: photo.faceRegions
            )
        }

        // EXIF + embedded XMP + `.xmp` sidecar, merged by the core. The
        // per-field precedence between the two sources is documented at the
        // merge site in `gallery_meta::media`, which is now its only copy.
        let metadata = readImageMetadata(path: photo.url.path)
        let tags = metadata.hierarchicalTags.map {
            HierarchicalTag(fullPath: $0.fullPath, namespace: $0.namespace,
                            displayName: $0.displayName)
        }
        let regions = metadata.faceRegions.map {
            FaceRegion(name: $0.name, centerX: $0.centerX, centerY: $0.centerY,
                       width: $0.width, height: $0.height)
        }

        var dateTaken = photo.dateTaken
        var dateFromMetadata = false
        if let date = metadata.captureWallClock.flatMap(resolve) {
            dateTaken = date
            dateFromMetadata = true
        } else if dateTaken == nil {
            dateTaken = filesystemFallback
        }

        return EnrichedResult(
            index: idx,
            dateTaken: dateTaken,
            dateFromMetadata: dateFromMetadata,
            hierarchicalTags: tags.isEmpty ? photo.hierarchicalTags : tags,
            countryCode: metadata.countryCode ?? photo.countryCode,
            gpsLatitude: metadata.gpsLatitude ?? photo.gpsLatitude,
            gpsLongitude: metadata.gpsLongitude ?? photo.gpsLongitude,
            enrichedFileDate: modDate ?? Date(),
            faceRegions: regions.isEmpty ? photo.faceRegions : regions
        )
    }

    /// Per-photo enrichment payload. The detached task collects these in
    /// parallel via a TaskGroup and the orchestrator merges them back into
    /// the photo array.
    struct EnrichedResult: Sendable {
        let index: Int
        let dateTaken: Date?
        let dateFromMetadata: Bool
        let hierarchicalTags: [HierarchicalTag]
        let countryCode: String?
        let gpsLatitude: Double?
        let gpsLongitude: Double?
        let enrichedFileDate: Date?
        let faceRegions: [FaceRegion]
    }

    /// Enrich every photo whose `enrichedFileDate` is nil. Returns the same
    /// array with stale entries replaced; entries already enriched are
    /// passed through unchanged. Cooperative — the caller's cancellation is
    /// forwarded into the detached task, and each child task checks
    /// `Task.isCancelled` before reading.
    ///
    /// `onProgress` is invoked from the detached task as each photo finishes
    /// (in TaskGroup completion order, not necessarily input order). The first
    /// argument is the cumulative completed count, the second is the total
    /// stale count discovered up-front. Use it to drive a progress bar; hop
    /// to the main actor inside the closure if you need to publish state.
    static func enrich(
        photos: [PhotoFile],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [PhotoFile] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Detached for the .background priority, with the caller's
        // cancellation forwarded explicitly (a bare `Task.detached` would
        // swallow it and the per-photo `Task.isCancelled` checks would
        // never trip).
        let work = Task.detached(priority: .background) { () -> [PhotoFile] in
            var result = photos
            let staleIndices = result.indices.filter { result[$0].enrichedFileDate == nil }
            let staleTotal = staleIndices.count
            onProgress?(0, staleTotal)

            // Bound the concurrent CGImageSource / sidecar reads — executor
            // width caps CPU parallelism anyway, but on provider-backed
            // volumes a free-for-all saturates I/O. Same gate the sidecar
            // sync (8) and thumbnail decodes (4) use.
            let limiter = AsyncSemaphore(limit: 8)

            // Enrich stale photos in parallel via TaskGroup. Pre-extract
            // `photo` outside the addTask closure so the closure captures
            // only `let` values — Swift 6's sending check rejects captures
            // of the surrounding mutable `result` var. `FileManager.default`
            // is referenced inline inside the closure for the same reason.
            let batchResults: [EnrichedResult] = await withTaskGroup(of: EnrichedResult?.self) { group in
                for idx in staleIndices {
                    let photo = result[idx]
                    group.addTask {
                        guard !Task.isCancelled else { return nil }

                        // Non-downloaded placeholders have no bytes —
                        // CGImageSource/AVAsset would read nothing. Skip the
                        // read but still mark them enriched-for-now; the
                        // locality transition (scanner full-scan probe, or
                        // `ensureMaterialized` in the Store) clears
                        // `enrichedFileDate` when the download lands so the
                        // real EXIF pass happens then. Tags/GPS for
                        // placeholders come from the sidecar cache instead.
                        if case .remote(downloaded: false) = photo.locality {
                            return EnrichedResult(
                                index: idx,
                                dateTaken: photo.dateTaken,
                                dateFromMetadata: photo.dateFromMetadata,
                                hierarchicalTags: photo.hierarchicalTags,
                                countryCode: photo.countryCode,
                                gpsLatitude: photo.gpsLatitude,
                                gpsLongitude: photo.gpsLongitude,
                                enrichedFileDate: photo.fileModificationDate ?? Date(),
                                faceRegions: photo.faceRegions
                            )
                        }

                        await limiter.acquire()
                        defer { Task { await limiter.release() } }
                        // Re-checked after the wait: on a 25k-photo library a
                        // task can sit in the semaphore queue for minutes, and
                        // the check before it says nothing about now.
                        guard !Task.isCancelled else { return nil }

                        // Everything below is blocking — `resourceValues` is a
                        // syscall and the two core reads open and parse a file
                        // — so it runs on a queue of its own rather than on a
                        // cooperative-pool thread. See `readOffPool`.
                        return await Self.readOffPool { Self.read(photo, at: idx) }
                    }
                }
                // Throttle progress callbacks so a 25k-photo enrichment
                // doesn't queue 25k `Task { @MainActor in scanProgress = ... }`
                // jobs back-to-back. Each callback fires an Observable
                // invalidation that re-evaluates PhotoGridScreen's body (its
                // toolbar reads `scanProgress`), re-diffs every visible cell,
                // and starves the thumbnail `.task` closures queued on the
                // same actor — i.e. thumbnails wouldn't paint until
                // enrichment drained. Mirrors the 500-file throttle on the
                // scanner side.
                var collected: [EnrichedResult] = []
                let progressBatch = 250
                var lastProgressTick = 0
                for await item in group {
                    if let item { collected.append(item) }
                    if collected.count - lastProgressTick >= progressBatch {
                        onProgress?(collected.count, staleTotal)
                        lastProgressTick = collected.count
                    }
                    if collected.count % 5000 == 0 {
                        Log.enrich.info("Processed \(collected.count)/\(staleIndices.count)…")
                    }
                }
                // Final flush so the bar reaches the true total instead of
                // stopping at the last batch boundary.
                if lastProgressTick != collected.count {
                    onProgress?(collected.count, staleTotal)
                }
                return collected
            }

            var dateCount = 0
            var tagCount = 0
            var uniquePaths = Set<String>()
            var regionPhotoCount = 0
            var regionCount = 0
            var namedRegionCount = 0
            var regionNamesSeen = Set<String>()
            for enriched in batchResults {
                result[enriched.index].dateTaken = enriched.dateTaken
                result[enriched.index].dateFromMetadata = enriched.dateFromMetadata
                result[enriched.index].hierarchicalTags = enriched.hierarchicalTags
                result[enriched.index].countryCode = enriched.countryCode
                result[enriched.index].gpsLatitude = enriched.gpsLatitude
                result[enriched.index].gpsLongitude = enriched.gpsLongitude
                result[enriched.index].enrichedFileDate = enriched.enrichedFileDate
                result[enriched.index].faceRegions = enriched.faceRegions
                if enriched.dateTaken != nil { dateCount += 1 }
                if !enriched.hierarchicalTags.isEmpty {
                    tagCount += 1
                    for tag in enriched.hierarchicalTags { uniquePaths.insert(tag.fullPath.lowercased()) }
                }
                if !enriched.faceRegions.isEmpty {
                    regionPhotoCount += 1
                    regionCount += enriched.faceRegions.count
                    for region in enriched.faceRegions {
                        if let name = region.name, !name.isEmpty {
                            namedRegionCount += 1
                            regionNamesSeen.insert(name)
                        }
                    }
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            Log.enrich.info("Done in \(String(format: "%.1f", elapsed))s: \(dateCount) EXIF dates, \(tagCount) photos with tags, \(uniquePaths.count) unique tag paths")
            Log.enrich.info("Face regions: \(regionCount) on \(regionPhotoCount) photos (\(namedRegionCount) named, \(regionNamesSeen.count) unique names)")
            if regionCount == 0 {
                Log.enrich.warning("No MWG regions found — Person rail will fall back to center-crop. Check that your XMP has <mwg-rs:RegionInfo> blocks.")
            } else {
                let sampleNames = regionNamesSeen.prefix(8).map { Log.r.person($0) }.joined(separator: ", ")
                Log.enrich.debug("Sample region names: \(sampleNames)")
            }
            let sampleTags = result.flatMap(\.hierarchicalTags).prefix(20)
            if !sampleTags.isEmpty {
                let tagDetails = sampleTags.map { "\(Log.r.tag($0.fullPath)) → ns:\(Log.r.other($0.namespace ?? "nil")) name:\(Log.r.tag($0.displayName))" }
                Log.enrich.debug("Sample hierarchical tags:\n  \(tagDetails.joined(separator: "\n  "))")
            }
            return result
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
