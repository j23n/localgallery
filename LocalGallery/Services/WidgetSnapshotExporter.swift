import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import WidgetKit
import CryptoKit
import os

/// Publishes a compact snapshot of the library into the App Group container so
/// widget extensions can render photos without re-scanning the user's folder.
///
/// Writes four JSON files plus a directory of widget-sized JPEG thumbnails.
/// Triggered after each scan, after memories regenerate, and on day rollover.
actor WidgetSnapshotExporter {

    /// Cap on photos in `index.json`. Folder/tag widgets pick from this pool.
    /// 500 most recent covers the rotation use-case while keeping the thumb
    /// directory under ~75MB at q=0.85 / 1024px.
    private static let maxIndexPhotos = 500
    /// Max edge for widget thumbnails in pixels. Large widget on a Pro Max
    /// is ~1180px wide @3x, so 1024 keeps headroom without bloating storage.
    private static let thumbMaxPixel: CGFloat = 1024
    private static let thumbQuality: CGFloat = 0.85
    /// Cap parallel `CGImageSourceCreateThumbnailAtIndex` decodes during thumb
    /// generation. With 500 photos in the index pool a first-run could otherwise
    /// spawn 500 simultaneous decoders and pin a phone's CPU. Kept at 4 to match
    /// `ThumbnailService`'s decode gate: higher fan-out exhausts the shared
    /// IOSurface pool when an export overlaps grid scrolling, surfacing as a
    /// flood of `CMPhotoJFIFUtilities -17102` / `IOSurface creation failed`
    /// errors and dropped (`-50`) thumbnails.
    private static let thumbnailConcurrency = 4

    /// Day-only formatter reused across exports — `ISO8601DateFormatter()` is
    /// expensive to allocate, and we only need a stable date string for the
    /// content fingerprint. Apple documents `ISO8601DateFormatter` as
    /// thread-safe; `nonisolated(unsafe)` documents that invariant for Swift 6.
    private nonisolated(unsafe) static let dayKeyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// A `Memory` plus the day window during which the widget should surface
    /// it. Used for calendar-tied memories the engine can produce in advance
    /// (onThisDay, yearsAgo, birthdays) so the widget stays correct even if
    /// the app isn't launched for several days. When the user finally opens
    /// the app on the matching day, foreground catch-up regenerates `Memory`
    /// with the same id, so the widget deep link still resolves.
    struct ScheduledMemory: Sendable, Hashable {
        let memory: Memory
        let validFrom: Date
        let validTo: Date
    }

    /// Inputs collected on the main actor before crossing into the actor.
    /// `memories` should be the same list rendered by the in-app rail
    /// (`GalleryStore.visibleMemories`) so widget taps always land on a
    /// memory the app can resolve. `scheduled` carries future-dated
    /// calendar-tied items (onThisDay/yearsAgo/birthdays for the next ~week)
    /// that the widget rotates to on their day without needing a fresh app
    /// launch.
    struct Inputs: Sendable {
        let allPhotos: [PhotoFile]
        let memories: [Memory]
        let allTags: [TagSuggestion]
        let rootFolder: PhotoFolder?
        let leafFolders: [PhotoFolder]
        let scheduled: [ScheduledMemory]
    }

    static let shared = WidgetSnapshotExporter()

    private var lastExportSignature: String?

    func export(_ inputs: Inputs) async {
        let t = CFAbsoluteTimeGetCurrent()
        SharedContainer.prepareDirectories()
        guard SharedContainer.widgetDataDir != nil,
              let thumbsDir = SharedContainer.thumbsDir else {
            Log.widget.warning("App Group container unavailable; skipping export")
            return
        }

        // Content-aware dedup: skip re-export when the inputs that actually
        // affect the snapshot haven't changed. Mixes in the calendar day so
        // a midnight rollover always rebuilds (today's onThisDay/birthday
        // memories become valid for one day at a time).
        let signature = Self.contentFingerprint(inputs: inputs)
        if signature == lastExportSignature {
            Log.widget.debug("Snapshot signature unchanged — skipping export")
            return
        }

        let recent = topRecentPhotos(from: inputs.allPhotos, limit: Self.maxIndexPhotos)
        let folderIdByPhotoURL = buildFolderIdMap(rootFolder: inputs.rootFolder)
        let indexRefs = recent.map { photo -> (PhotoFile, WidgetPhotoRef) in
            (photo, makeRef(photo: photo, folderIdByURL: folderIdByPhotoURL))
        }

        let memoryItems = buildMemoryItems(
            memories: inputs.memories,
            scheduled: inputs.scheduled,
            allPhotos: inputs.allPhotos,
            folderIdByURL: folderIdByPhotoURL
        )

        let folderEntries = buildFolderCatalog(rootFolder: inputs.rootFolder, leaves: inputs.leafFolders)
        let tagPaths = inputs.allTags
            .map(\.fullPath)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        // Collect referenced photos: index pool ∪ memory items.
        var referencedPhotos: [String: (PhotoFile, WidgetPhotoRef)] = [:]
        for (photo, ref) in indexRefs { referencedPhotos[ref.id] = (photo, ref) }
        let photoByIdString = Dictionary(uniqueKeysWithValues: inputs.allPhotos.map { ($0.id.uuidString, $0) })
        for item in memoryItems {
            for ref in item.photoRefs {
                if referencedPhotos[ref.id] == nil, let photo = photoByIdString[ref.id] {
                    referencedPhotos[ref.id] = (photo, ref)
                }
            }
        }

        // Generate / refresh thumbnails (skips files already up-to-date on disk).
        await generateThumbnails(referencedPhotos.values.map { $0 }, thumbsDir: thumbsDir)
        garbageCollectThumbs(thumbsDir: thumbsDir, keepIDs: Set(referencedPhotos.keys))

        let now = Date()
        let index = WidgetIndex(generatedAt: now, photos: indexRefs.map(\.1))
        let folderCatalog = FolderCatalog(generatedAt: now, folders: folderEntries)
        let tagCatalog = TagCatalog(generatedAt: now, tagPaths: tagPaths)
        let memorySnapshot = MemorySnapshot(generatedAt: now, items: memoryItems)

        writeJSON(index, to: SharedContainer.indexURL)
        writeJSON(folderCatalog, to: SharedContainer.foldersURL)
        writeJSON(tagCatalog, to: SharedContainer.tagsURL)
        writeJSON(memorySnapshot, to: SharedContainer.memoriesURL)

        let elapsed = (CFAbsoluteTimeGetCurrent() - t) * 1000
        Log.widget.info("Exported snapshot: \(indexRefs.count) photos, \(memoryItems.count) memories, \(folderEntries.count) folders, \(tagPaths.count) tags in \(String(format: "%.0f", elapsed))ms")

        lastExportSignature = signature
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Content fingerprint

    /// Hex-encoded MD5 of every input that affects the published snapshot —
    /// photo identity *and* mutable fields (date, tags, folder), plus tag/
    /// memory/folder inventories and the calendar day. Catches equal-count
    /// edits (delete-one-add-one, retag, mtime bump) that the previous
    /// count-only signature missed.
    private static func contentFingerprint(inputs: Inputs) -> String {
        var hasher = Insecure.MD5()

        let dayKey = dayKeyFormatter.string(from: Calendar.current.startOfDay(for: Date()))
        hasher.update(data: Data("day:\(dayKey)\n".utf8))

        // Photos: stable identity + everything the widget displays. Sort by id
        // so reordered allPhotos arrays produce the same hash.
        hasher.update(data: Data("photos:\n".utf8))
        let recent = inputs.allPhotos
            .filter { !$0.isVideo }
            .sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
            .prefix(maxIndexPhotos)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for p in recent {
            let date = p.dateTaken.map { String($0.timeIntervalSince1970) } ?? "nil"
            let tags = p.hierarchicalTags.map(\.fullPath).sorted().joined(separator: ",")
            hasher.update(data: Data("\(p.id.uuidString)|\(date)|\(tags)\n".utf8))
        }

        hasher.update(data: Data("tags:\n".utf8))
        for path in inputs.allTags.map(\.fullPath).sorted() {
            hasher.update(data: Data("\(path)\n".utf8))
        }

        hasher.update(data: Data("memories:\n".utf8))
        for m in inputs.memories.sorted(by: { $0.id < $1.id }) {
            hasher.update(data: Data("\(m.id)|\(m.coverPhotoID.uuidString)|\(m.photoIDs.count)\n".utf8))
        }

        hasher.update(data: Data("folders:\n".utf8))
        for f in inputs.leafFolders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let mod = f.dateModified.map { String($0.timeIntervalSince1970) } ?? "nil"
            hasher.update(data: Data("\(f.id.uuidString)|\(f.name)|\(mod)|\(f.photos.count)\n".utf8))
        }

        hasher.update(data: Data("scheduled:\n".utf8))
        let scheduledSorted = inputs.scheduled.sorted { lhs, rhs in
            if lhs.validFrom != rhs.validFrom { return lhs.validFrom < rhs.validFrom }
            return lhs.memory.id < rhs.memory.id
        }
        for s in scheduledSorted {
            hasher.update(data: Data("\(s.memory.id)|\(s.validFrom.timeIntervalSince1970)|\(s.memory.photoIDs.count)\n".utf8))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Photo / Folder maps

    private func topRecentPhotos(from photos: [PhotoFile], limit: Int) -> [PhotoFile] {
        let images = photos.filter { !$0.isVideo }
        let sorted = images.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
        return Array(sorted.prefix(limit))
    }

    private func buildFolderIdMap(rootFolder: PhotoFolder?) -> [URL: String] {
        var out: [URL: String] = [:]
        guard let root = rootFolder else { return out }
        func walk(_ folder: PhotoFolder) {
            let id = folder.id.uuidString
            for photo in folder.photos { out[photo.url] = id }
            for sub in folder.subfolders { walk(sub) }
        }
        walk(root)
        return out
    }

    private func makeRef(photo: PhotoFile, folderIdByURL: [URL: String]) -> WidgetPhotoRef {
        WidgetPhotoRef(
            id: photo.id.uuidString,
            folderId: folderIdByURL[photo.url] ?? "",
            date: photo.dateTaken,
            tagPaths: photo.hierarchicalTags.map(\.fullPath),
            thumbnailFilename: photo.id.uuidString + ".jpg"
        )
    }

    // MARK: - Folder catalog

    private func buildFolderCatalog(rootFolder: PhotoFolder?, leaves: [PhotoFolder]) -> [FolderCatalogEntry] {
        guard let root = rootFolder else { return [] }
        // Build path: walk the tree once, recording the parent chain so the
        // intent picker can show "Trips › Italy 2024" instead of just "Italy 2024".
        var parents: [UUID: String] = [:]   // folder id -> chain like "Trips › Italy 2024"
        func walk(_ folder: PhotoFolder, parentChain: String) {
            let chain = parentChain.isEmpty ? folder.name : "\(parentChain) › \(folder.name)"
            parents[folder.id] = chain
            for sub in folder.subfolders { walk(sub, parentChain: chain) }
        }
        walk(root, parentChain: "")

        return leaves
            .sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
            .map { folder in
                FolderCatalogEntry(
                    id: folder.id.uuidString,
                    displayName: folder.name,
                    pathDescription: parents[folder.id] ?? folder.name
                )
            }
    }

    // MARK: - Memory snapshot

    /// Direct projection of the in-app rail: every memory in `memories`
    /// (assumed to be `GalleryStore.visibleMemories` order) becomes a
    /// `MemorySnapshotItem` with the same id, so widget deep-links always
    /// resolve to a memory the app can render. Priority comes from the
    /// engine's own score so the rail's top entry is the widget's top entry.
    ///
    /// `scheduled` adds future-dated calendar-tied items (onThisDay,
    /// yearsAgo, birthdays for the next few days) with per-item validity
    /// windows so the widget can rotate to them on their day even if the
    /// app isn't opened in between.
    private func buildMemoryItems(
        memories: [Memory],
        scheduled: [ScheduledMemory],
        allPhotos: [PhotoFile],
        folderIdByURL: [URL: String]
    ) -> [MemorySnapshotItem] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86400)

        let photoByID = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })

        var items: [MemorySnapshotItem] = []
        for memory in memories {
            let refs = orderedRefs(for: memory, photoByID: photoByID, folderIdByURL: folderIdByURL)
            guard !refs.isEmpty else { continue }
            items.append(MemorySnapshotItem(
                id: memory.id,
                kind: snapshotKind(for: memory.type),
                title: memory.title,
                subtitle: memory.subtitle,
                photoRefs: refs,
                validFrom: startOfToday,
                validTo: startOfTomorrow,
                priority: Int(memory.score.rounded())
            ))
        }
        for entry in scheduled {
            let refs = orderedRefs(for: entry.memory, photoByID: photoByID, folderIdByURL: folderIdByURL)
            guard !refs.isEmpty else { continue }
            items.append(MemorySnapshotItem(
                id: entry.memory.id,
                kind: snapshotKind(for: entry.memory.type),
                title: entry.memory.title,
                subtitle: entry.memory.subtitle,
                photoRefs: refs,
                validFrom: entry.validFrom,
                validTo: entry.validTo,
                priority: Int(entry.memory.score.rounded())
            ))
        }
        return items.sorted { $0.priority > $1.priority }
    }

    private func snapshotKind(for type: MemoryType) -> MemorySnapshotKind {
        switch type {
        case .onThisDay:   return .onThisDay
        case .yearsAgo:    return .yearsAgo
        case .birthday:    return .birthday
        case .trip, .folderEvent, .photoDensity, .personOverTime:
            return .other
        }
    }

    private func orderedRefs(
        for memory: Memory,
        photoByID: [UUID: PhotoFile],
        folderIdByURL: [URL: String]
    ) -> [WidgetPhotoRef] {
        var seen = Set<UUID>()
        var ordered: [PhotoFile] = []
        // Cover first so it leads in the widget hero shot.
        if let cover = photoByID[memory.coverPhotoID], seen.insert(cover.id).inserted {
            ordered.append(cover)
        }
        for id in memory.photoIDs {
            guard !seen.contains(id), let photo = photoByID[id] else { continue }
            seen.insert(id)
            ordered.append(photo)
            if ordered.count >= 12 { break }
        }
        return ordered.map { makeRef(photo: $0, folderIdByURL: folderIdByURL) }
    }

    // MARK: - Thumbnails

    private func generateThumbnails(_ pairs: [(PhotoFile, WidgetPhotoRef)], thumbsDir: URL) async {
        // Cap concurrency: a first-run with the full 500-photo pool would
        // otherwise spawn 500 simultaneous CGImageSource decoders and pin
        // the device's CPU. Sliding window via the in-flight counter keeps
        // exactly `thumbnailConcurrency` decodes inflight at any moment.
        let limit = Self.thumbnailConcurrency
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            var iter = pairs.makeIterator()
            while let (photo, ref) = iter.next() {
                if inflight >= limit {
                    await group.next()
                    inflight -= 1
                }
                group.addTask {
                    await Self.writeThumbIfNeeded(photo: photo, ref: ref, thumbsDir: thumbsDir)
                }
                inflight += 1
            }
            await group.waitForAll()
        }
    }

    private nonisolated static func writeThumbIfNeeded(photo: PhotoFile, ref: WidgetPhotoRef, thumbsDir: URL) async {
        let dest = thumbsDir.appendingPathComponent(ref.thumbnailFilename)
        let fm = FileManager.default
        let srcMod = (try? photo.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let dstMod = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let srcMod, let dstMod, dstMod >= srcMod, fm.fileExists(atPath: dest.path) {
            return
        }

        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(photo.url as CFURL, opts as CFDictionary) else { return }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbMaxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bake EXIF orientation into the pixels so the JPEG we write below
            // is "born upright" and the widget extension doesn't need to apply
            // a transform at read time.
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        // No `kCGImageSourceShouldCacheImmediately`: the `opaqueCopy()` redraw
        // below forces the decode anyway (into a malloc-backed context), so the
        // eager flag would only add a second IOSurface-backed buffer per photo
        // and worsen pool pressure during a large export.
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return }

        // Encode JPEG via CGImageDestination instead of routing through
        // `UIGraphicsImageRenderer` — its default `UIGraphicsImageRendererFormat()`
        // init touches `UIScreen.main` / `UITraitCollection.current.displayScale`,
        // both of which assert main-thread on iOS 26. The widget export runs on
        // a detached background task (BG-task wake path or post-scan), so the
        // assertion fires as `_dispatch_assert_queue_fail` and crashes the app
        // (EXC_BREAKPOINT). CGImageDestination has no such restriction and
        // produces an equivalent JPEG from the already-oriented CGImage.
        // Write to a temp file then rename so a torn write can't leave the
        // widget reading a half-flushed thumbnail.
        let tmp = dest.appendingPathExtension("tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            tmp as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }
        let destProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: thumbQuality
        ]
        // Flatten the thumbnail's `premultipliedLast` alpha before encoding so
        // ImageIO doesn't log "save an opaque image with 'AlphaPremulLast'" for
        // every widget thumbnail (JPEG drops the channel regardless).
        CGImageDestinationAddImage(destination, cg.opaqueCopy(), destProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? fm.removeItem(at: tmp)
            return
        }
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }

    private func garbageCollectThumbs(thumbsDir: URL, keepIDs: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let id = url.deletingPathExtension().lastPathComponent
            if !keepIDs.contains(id) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - JSON

    private func writeJSON<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.widget.error("Failed to write \(Log.r.filename(url.lastPathComponent)): \(Log.r.error(error))")
        }
    }
}
