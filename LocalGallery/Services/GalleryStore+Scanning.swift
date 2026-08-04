import Foundation
import os

/// The folder-scan pipeline: launch restore, scan-kind resolution and
/// dedupe, the two-phase scan, metadata enrichment, and the sidecar merge.
/// Same type as `GalleryStore` (the pipeline reads and publishes Store
/// state); split into its own file so the Store's state surface and the
/// scan machinery can be read separately.
extension GalleryStore {
    // MARK: - Restore on Launch

    func restoreFolder() async {
        let hadCache = rootFolder != nil

        // Refresh contacts if access is already granted. No-op (and no prompt)
        // when access hasn't been granted — birthday memories simply won't
        // appear until the user grants access from Settings.
        await loadContacts()

        // Security scope may already be active from init()
        let url: URL
        if let active = bookmarks.activeURL {
            url = active
        } else {
            guard let resolved = bookmarks.resolve() else { return }
            bookmarks.startAccessing(resolved)
            url = resolved
        }

        // Only show spinner if no cache to display
        if !hadCache {
            isScanning = true
        }

        // Rescan in background — cached URLs are from a previous session.
        // `.auto` picks light when we have fresh cache + recent full scan,
        // and full otherwise (cold install, post-upgrade, >fullScanInterval
        // since last full pass).
        await scanFolder(at: url, kind: .auto, silent: hadCache)
    }

    /// Scan trigger entry point. All call sites pass `kind` explicitly so the
    /// behaviour is deterministic and grep-able:
    ///
    ///   - **`.light`** — pull-to-refresh in any view. Never promotes; the
    ///     user pulled down to see new files, not to pay a 3-min full-rescan
    ///     bill.
    ///   - **`.auto`** — foreground observer + cold-launch `restoreFolder`.
    ///     Light by default, but promotes to full if it's been more than
    ///     `fullScanInterval` (48h) since the last full scan. This is the
    ///     deterministic backstop: every two days a full pass happens
    ///     transparently on the next foreground.
    ///   - **`.full`** — Settings "Reload Library", "Re-download all
    ///     sidecars", and the folder-picker's first scan. Explicit user
    ///     intent, always runs the slow path.
    ///
    /// The default is `.auto` so a future caller that omits `kind` still
    /// gets the safe-by-default behaviour.
    func rescan(kind: ScanKind = .auto, silent: Bool = true) async {
        guard let url = bookmarks.activeURL else { return }
        await scanFolder(at: url, kind: kind, silent: silent)
    }


    // MARK: - Folder Scanning (Iterative)

    /// - Parameter requestedAt: when the *original* request was made. Set only
    ///   by the recursive re-run below, so a request that has to wait out an
    ///   in-flight pass keeps its own timestamp instead of gaining a fresh one
    ///   on every hop — which is what makes the recursion terminate.
    func scanFolder(
        at url: URL,
        kind: ScanKind = .full,
        silent: Bool = false,
        requestedAt: Date? = nil
    ) async {
        let requestedAt = requestedAt ?? clock.now()
        let resolved = resolvedScanKind(for: kind, now: clock.now())
        if let active = activeScanTask {
            if active.url == url {
                await active.task.value
                // The spawner's cleanup races this resumption; clear the
                // finished entry ourselves so the re-run below can't loop on
                // a stale `activeScanTask`.
                if activeScanTask?.task == active.task { activeScanTask = nil }
                // Two reasons a completed in-flight pass may not satisfy this
                // request:
                //
                //  - It was weaker. A `.full` request must not be silently
                //    downgraded by an in-flight light scan — "Reload Library"
                //    during a foreground auto-scan would otherwise no-op.
                //  - It was *earlier*. A pass that started before this request
                //    existed may have walked the tree before the files the
                //    request is about did: a tagging run's post-write rescan
                //    coalesced onto a pull-to-refresh that began a second
                //    earlier would report a manifest with none of the new
                //    `.xmp` files in it, and nothing would look again.
                //
                // Either way, re-run once the in-flight pass settles. This
                // costs at most one extra walk per request, not a storm: the
                // re-run carries the original `requestedAt`, so the moment a
                // pass that started after it completes, the request is done.
                let tooWeak = resolved == .full && active.kind != .full
                let tooEarly = active.startedAt < requestedAt
                if tooWeak || tooEarly {
                    await scanFolder(
                        at: url,
                        kind: tooWeak ? .full : kind,
                        silent: silent,
                        requestedAt: requestedAt
                    )
                }
                return
            }
            // Different root in flight (user picked a new folder mid-scan).
            // Let it settle first so two performScans never interleave their
            // apply()/saveCache() calls.
            await active.task.value
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performScan(at: url, kind: resolved, silent: silent)
        }
        activeScanTask = (url, resolved, clock.now(), task)
        await task.value
        if activeScanTask?.task == task { activeScanTask = nil }
    }

    /// Resolve `.auto` → `.light` or `.full` based on how long it's been
    /// since the last full scan. Exposed so tests can verify the gate.
    func resolvedScanKind(for kind: ScanKind, now: Date) -> ScanKind {
        switch kind {
        case .light, .full: return kind
        case .auto:
            guard let last = lastFullScanAt else { return .full }
            return now.timeIntervalSince(last) >= Self.fullScanInterval ? .full : .light
        }
    }


    private func performScan(at url: URL, kind: ScanKind, silent: Bool) async {
        let resolved = resolvedScanKind(for: kind, now: clock.now())

        // Spinner state is reserved for non-silent scans (Settings "Reload
        // Library", cold launch without cache). It spans both passes of a
        // two-phase scan and is cleared once, below.
        if !silent { isScanning = true }

        // Two-phase scan: when a full scan is on tap AND we already hold a
        // cache to reuse, run a quick light pass first. The light pass walks
        // the tree but reuses cached PhotoFiles for unchanged files (no
        // FileProvider probe, no EXIF re-read), so newly added / changed
        // files surface in seconds instead of waiting out the full pass's
        // ~3-min probe + enrichment over the whole library. The full pass
        // then follows for the deterministic backstop: probe/locality
        // refresh, in-place EXIF edits, and missed sidecars.
        //
        // Skipped when `allPhotos` is empty (cold launch with no cache):
        // with nothing to reuse, the light pass pays the same per-file cost
        // as the full pass, so a pre-pass would just scan everything twice
        // for no speed-up.
        if resolved == .full && !allPhotos.isEmpty {
            await runScanPass(at: url, light: true, silent: silent)
        }

        // Final pass: full when requested, light for the `.light` kind.
        let result = await runScanPass(at: url, light: resolved == .light, silent: silent)

        isScanning = false
        lastSyncedAt = clock.now()
        // A full pass that never completed has not refreshed anything, so it
        // must not restart the 48-hour clock — doing that would let one
        // cancelled scan suppress the backstop for two days.
        if resolved == .full && !result.didNotComplete {
            lastFullScanAt = lastSyncedAt
            defaults.set(lastFullScanAt, forKey: "lastFullScanAt")
        }

        // Post-scan work runs once, against the just-published `allPhotos`,
        // after the final pass — the light pre-pass deliberately skips all of
        // it so it stays quick.
        //
        // A pass that produced no outcome is skipped too: its empty manifest
        // would tell `sidecarSync` every `.xmp` in the library had vanished.
        // The progress banner is still cleared, because the scan is over
        // either way.
        if !result.didNotComplete {
            // Hand the manifest to the sidecar sync service; it diffs against
            // the cache and either fetches silently or surfaces a prompt.
            let allIDs = Set(allPhotos.map(\.id))
            sidecarSync.plan(
                manifest: result.sidecarManifest,
                allPhotoIDs: allIDs,
                autoApprove: false
            )

            // Memory generation runs against the just-published `allPhotos`.
            memories.generateIfNeeded()
        }

        // Scan + enrichment have settled — clear progress so the banner
        // dismisses.
        self.scanProgress = nil

        // Refresh the widget snapshot after the scan/enrichment pass settles.
        exportWidgetSnapshot()
    }

    /// One scan pass: walk `url`, enrich new/changed files, and publish the
    /// result to `allPhotos` / `rootFolder`. Returns the scanner result so the
    /// caller can drive the once-per-scan post-processing (sidecar plan,
    /// memory generation, widget export) after the final pass of a two-phase
    /// scan. Owns `scanProgress` for its scanning/enriching phases but leaves
    /// `isScanning` / `lastFullScanAt` / final progress teardown to
    /// `performScan`, which spans both passes.
    ///
    /// Internal rather than private so `ScanBailoutTests` can cancel one pass
    /// on its own: cancellation is only observable at a suspension point inside
    /// this function, and racing `performScan`'s two-phase sequencing from
    /// outside would test the scheduler, not the behaviour.
    @discardableResult
    func runScanPass(at url: URL, light: Bool, silent: Bool) async -> CoreScanner.Result {
        let startedAt = clock.now()
        self.scanProgress = ScanProgress(phase: .scanning, processed: 0, total: nil, startedAt: startedAt)

        let cachedPhotos = Dictionary(
            allPhotos.map { ($0.url, $0) },
            uniquingKeysWith: { _, b in b }
        )
        // Pass last scan's sidecar manifest in too so the light-scan fast
        // path can skip the `.xmp` `FileProviderDetector.probe()` for
        // unchanged photos — that probe dominates light-scan wall time on
        // digiKam libraries (one 7-key resourceValues syscall per sidecar).
        let cachedSidecarManifest = Dictionary(
            self.lastSidecarManifest.map { ($0.photoID, $0) },
            uniquingKeysWith: { _, b in b }
        )

        // Heavy file I/O runs off the main actor so cached UI stays responsive.
        // Scanner progress hops back to the main actor to publish into
        // `scanProgress`; throttled to once per ~100 files inside the scanner.
        let progressCallback: @Sendable (Int) -> Void = { [weak self] processed in
            Task { @MainActor [weak self] in
                guard let self, let current = self.scanProgress, current.phase == .scanning else { return }
                self.scanProgress = ScanProgress(
                    phase: .scanning,
                    processed: processed,
                    total: nil,
                    startedAt: current.startedAt
                )
            }
        }
        let result = await coreScanner.scan(
            at: url,
            cachedPhotos: cachedPhotos,
            cachedSidecarManifest: cachedSidecarManifest,
            reuseCached: light,
            onProgress: progressCallback
        )

        // A pass that never produced an outcome — cancelled, or the core threw
        // — describes nothing. Publishing it would empty `allPhotos`, empty
        // `rootFolder`, empty `lastSidecarManifest`, and then `saveCache()`
        // would write all three to disk: one cancelled scan and the library is
        // gone until the next successful full pass rebuilds it from the
        // filesystem, losing every tag and enrichment on the way. An
        // unreadable *directory* is the opposite case and does not come
        // through here — it arrives as `failedDirectoryPaths` below, with the
        // rest of the tree intact.
        guard !result.didNotComplete else {
            Log.scan.warning("\(light ? "light" : "full") scan produced no outcome; keeping \(self.allPhotos.count) cached photos")
            return result
        }

        // Captured before the assignment: the manifest can change while the
        // photo list does not — a new `.xmp` beside an untouched photo, or the
        // very first pass after an upgrade, where the persisted snapshot had
        // no manifest at all. That last case is the one that matters: without
        // the explicit save below, the "no changes" branch would skip
        // `saveCache()`, the manifest would never reach disk, and every launch
        // would go on re-probing every sidecar — `_plans/06` Finding 2 fixed
        // in memory only.
        let manifestChanged = self.lastSidecarManifest != result.sidecarManifest
        self.lastSidecarManifest = result.sidecarManifest
        let remoteCount = result.flatPhotos.filter {
            if case .remote = $0.locality { return true } else { return false }
        }.count
        if remoteCount > 0 {
            Log.scan.info("Detected \(remoteCount) file-provider photos, \(result.sidecarManifest.count) sidecar candidates")
        }

        // Carry forward cached photos under directories whose listing failed
        // (transient provider error, brief unmount) — the scanner couldn't
        // see them this pass, and dropping them would wipe their tags and
        // enrichment over a one-off I/O error. They stay in the flat grid
        // (not the folder tree) until a scan can list their parent again.
        var scannedPhotos = result.flatPhotos
        if !result.failedDirectoryPaths.isEmpty {
            let scannedURLs = Set(scannedPhotos.map(\.url))
            let preserved = allPhotos.filter { photo in
                guard !scannedURLs.contains(photo.url) else { return false }
                let path = photo.url.standardizedFileURL.path
                return result.failedDirectoryPaths.contains { path.hasPrefix($0 + "/") }
            }
            if !preserved.isEmpty {
                Log.scan.warning("Preserving \(preserved.count) cached photos under \(result.failedDirectoryPaths.count) unreadable directories")
                scannedPhotos += preserved
            }
        }

        // Merge cached sidecar entries onto the freshly-scanned photos.
        let mergedPhotos = mergeCachedSidecars(into: scannedPhotos)

        // Run enrichment on the scan output BEFORE publishing anything to
        // the observed grid state. The displayed grid keeps showing the
        // cached photos throughout the scan + enrichment window, so
        // ThumbnailViews (keyed on the unchanged URLs) stay on their
        // cached thumbnails instead of being torn down and re-loaded
        // mid-sync. One `allPhotos` assignment below covers both phases.
        let finalPhotos: [PhotoFile]
        if result.needsEnrichment && !mergedPhotos.isEmpty {
            finalPhotos = await enrichPhotos(mergedPhotos)
        } else {
            finalPhotos = mergedPhotos
        }

        // Patch the folder tree to carry the enriched photo values, so the
        // Folders tab sees the same dates/tags as the flat grid.
        let finalRoot: PhotoFolder?
        if let root = result.rootFolder {
            let photosByURL = Dictionary(finalPhotos.map { ($0.url, $0) }, uniquingKeysWith: { _, b in b })
            finalRoot = Self.updateFolderPhotos(root, photosByURL: photosByURL)
        } else {
            finalRoot = nil
        }

        // Atomic swap — single assignment for both rootFolder and allPhotos,
        // single rebuildSortAndIndex, single saveCache. Views observing
        // sortedPhotos / allPhotos see one update at the end of the pass
        // instead of one after the scan + one after enrichment.
        let existingURLs = Set(allPhotos.map(\.url))
        let newURLs = Set(finalPhotos.map(\.url))
        let contentChanged = existingURLs != newURLs || result.needsEnrichment

        let scanKindLabel = light ? "light" : "full"
        if contentChanged && (!finalPhotos.isEmpty || !silent) {
            Log.scan.info("\(scanKindLabel) scan complete: \(finalPhotos.count) photos (+\(result.addedURLs.count) -\(result.removedURLs.count) ~\(result.modifiedURLs.count), needsEnrichment=\(result.needsEnrichment))")
            apply(.scanResult(photos: finalPhotos, root: finalRoot, persistCache: true))
        } else if finalPhotos.isEmpty && !silent {
            // Explicit user-driven scan that found nothing — surface the empty
            // state but don't overwrite the on-disk cache; a transient folder
            // access failure shouldn't blow away a good cache.
            Log.scan.info("\(scanKindLabel) scan complete: 0 photos")
            apply(.scanResult(photos: [], root: finalRoot, persistCache: false))
        } else {
            Log.scan.info("\(scanKindLabel) scan complete, no changes (\(finalPhotos.count) photos)")
            if manifestChanged {
                // No `apply` on this path — nothing about the photos moved —
                // so the cache write has to be asked for directly.
                Log.scan.info("Persisting \(result.sidecarManifest.count) sidecar rows (photos unchanged)")
                persistLibraryCache()
            }
        }

        return result
    }

    /// Read EXIF dates and hierarchical tags for the stale entries in
    /// `photos`. Pure transform: returns the enriched array without
    /// mutating `allPhotos`. The caller (`performScan`) publishes the
    /// result as part of its atomic swap.
    private func enrichPhotos(_ photos: [PhotoFile]) async -> [PhotoFile] {
        guard !isEnriching else { return photos }
        isEnriching = true
        defer { isEnriching = false }

        let staleCount = photos.filter { $0.enrichedFileDate == nil }.count
        Log.enrich.info("Starting metadata enrichment: \(staleCount) new/changed of \(photos.count) total")

        if staleCount == 0 {
            Log.enrich.info("All photos up-to-date, skipping")
            return photos
        }

        // Flip the progress banner to the enriching phase. Total is known
        // up-front (the stale-file count), so the UI can render a percent
        // and ETA.
        let enrichStart = clock.now()
        self.scanProgress = ScanProgress(
            phase: .enriching,
            processed: 0,
            total: staleCount,
            startedAt: enrichStart
        )

        let enrichedPhotos = await EnrichmentService.enrich(photos: photos) { [weak self] processed, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let current = self.scanProgress, current.phase == .enriching else { return }
                self.scanProgress = ScanProgress(
                    phase: .enriching,
                    processed: processed,
                    total: total,
                    startedAt: current.startedAt
                )
            }
        }

        let enrichedCount = zip(photos, enrichedPhotos).filter { old, new in
            old.dateTaken != new.dateTaken ||
            old.hierarchicalTags != new.hierarchicalTags ||
            old.countryCode != new.countryCode ||
            old.gpsLatitude != new.gpsLatitude
        }.count
        Log.enrich.info("Enrichment changed \(enrichedCount) photos")
        return enrichedPhotos
    }

    /// Re-apply `mergeCachedSidecars` to the live `allPhotos`. Called after
    /// the sidecar sync service finishes a fetch run so newly-cached entries
    /// surface tags/country codes without a manual rescan.
    func reapplySidecarMerges() {
        let merged = mergeCachedSidecars(into: allPhotos)
        guard merged != allPhotos else { return }
        apply(.sidecarsMerged(photos: merged))
        Log.cache.info("Re-applied sidecar merges to live photos")
    }

    /// Merge any `SidecarCacheStore` entry into a photo's runtime fields, so
    /// search/tags/country/face-regions surface for cloud photos before the
    /// next sync completes. Cached fields lose to existing in-memory values
    /// only when the photo already has them — fresh-from-disk metadata
    /// (EXIF + sidecar, read by the core's `readImageMetadata`) wins on the
    /// enrichment pass that runs after this.
    private func mergeCachedSidecars(into photos: [PhotoFile]) -> [PhotoFile] {
        var photos = photos
        for i in photos.indices {
            guard let cached = sidecarCache.get(photos[i].id) else { continue }
            if photos[i].hierarchicalTags.isEmpty {
                photos[i].hierarchicalTags = cached.hierarchicalTags
            }
            if photos[i].countryCode == nil {
                photos[i].countryCode = cached.countryCode
            }
            if photos[i].faceRegions.isEmpty {
                photos[i].faceRegions = cached.faceRegions
            }
            photos[i].sidecarStatus = .cached(cached.version)
        }
        return photos
    }

    /// Recursively update photos inside folder tree with enriched metadata
    nonisolated static func updateFolderPhotos(_ folder: PhotoFolder, photosByURL: [URL: PhotoFile]) -> PhotoFolder {
        var f = folder
        f.photos = f.photos.map { photosByURL[$0.url] ?? $0 }
        f.subfolders = f.subfolders.map { updateFolderPhotos($0, photosByURL: photosByURL) }
        return f
    }

}
