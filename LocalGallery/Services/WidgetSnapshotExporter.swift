import Foundation
import UIKit
import ImageIO
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
    /// spawn 500 simultaneous decoders and pin a phone's CPU.
    private static let thumbnailConcurrency = 8

    /// Day-only formatter reused across exports — `ISO8601DateFormatter()` is
    /// expensive to allocate, and we only need a stable date string for the
    /// content fingerprint. Apple documents `ISO8601DateFormatter` as
    /// thread-safe; `nonisolated(unsafe)` documents that invariant for Swift 6.
    private nonisolated(unsafe) static let dayKeyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// One person whose linked contact's birthday is today. Pre-computed on
    /// the main actor by `GalleryStore.exportWidgetSnapshot`, so the
    /// exporter doesn't need access to `Contacts.framework` or the
    /// `PersonLink` enum.
    struct BirthdayResolution: Sendable, Hashable {
        let tagFullPath: String
        /// Preferred display name (full contact name, or the tag's leaf when
        /// the contact has no usable name).
        let displayName: String
    }

    /// Inputs collected on the main actor before crossing into the actor.
    struct Inputs: Sendable {
        let allPhotos: [PhotoFile]
        let memories: [Memory]
        let allTags: [TagSuggestion]
        let rootFolder: PhotoFolder?
        let leafFolders: [PhotoFolder]
        /// People whose linked contact has a birthday matching today. Empty
        /// when birthdays are disabled, Contacts permission isn't granted, or
        /// nobody on file is celebrating today.
        let todayBirthdays: [BirthdayResolution]
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
            allPhotos: inputs.allPhotos,
            todayBirthdays: inputs.todayBirthdays,
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
    /// memory/folder/birthday inventories and the calendar day. Catches
    /// equal-count edits (delete-one-add-one, retag, mtime bump) that the
    /// previous count-only signature missed.
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

        hasher.update(data: Data("birthdays:\n".utf8))
        for b in inputs.todayBirthdays.sorted(by: { $0.tagFullPath < $1.tagFullPath }) {
            hasher.update(data: Data("\(b.tagFullPath)|\(b.displayName)\n".utf8))
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

    private func buildMemoryItems(
        memories: [Memory],
        allPhotos: [PhotoFile],
        todayBirthdays: [BirthdayResolution],
        folderIdByURL: [URL: String]
    ) -> [MemorySnapshotItem] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86400)

        let photoByID = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })

        var items: [MemorySnapshotItem] = []

        // 1. App-generated memories with a dateRange covering today (the existing
        //    `onThisDay` / `yearsAgo` slots already encode "valid today").
        for memory in memories where memory.type == .onThisDay || memory.type == .yearsAgo {
            let refs = orderedRefs(for: memory, photoByID: photoByID, folderIdByURL: folderIdByURL)
            guard !refs.isEmpty else { continue }
            let kind: MemorySnapshotKind = memory.type == .onThisDay ? .onThisDay : .yearsAgo
            let priority: Int = memory.type == .yearsAgo ? 60 : 50
            items.append(MemorySnapshotItem(
                id: memory.id,
                kind: kind,
                title: memory.title,
                subtitle: memory.subtitle,
                photoRefs: refs,
                validFrom: startOfToday,
                validTo: startOfTomorrow,
                priority: priority
            ))
        }

        // 2. Birthdays — synthesize a memory for every pre-resolved entry.
        //    The main app filtered out unlinked / disabled / non-matching
        //    people already, so we just emit one item per resolution. We
        //    build the tag→photos index once and key it on lowercased
        //    fullPath, matching the convention used elsewhere in the app
        //    (`GalleryStore._photosForTag`) — so case-only differences
        //    between the canonical tag list and a photo's raw XMP entry
        //    don't drop photos.
        if !todayBirthdays.isEmpty {
            var photosByTag: [String: [PhotoFile]] = [:]
            for photo in allPhotos {
                for tag in photo.hierarchicalTags {
                    photosByTag[tag.fullPath.lowercased(), default: []].append(photo)
                }
            }
            for resolution in todayBirthdays {
                let photos = photosByTag[resolution.tagFullPath.lowercased()] ?? []
                guard !photos.isEmpty else { continue }
                let sorted = photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
                let refs = Array(sorted.prefix(12)).map { makeRef(photo: $0, folderIdByURL: folderIdByURL) }
                items.append(MemorySnapshotItem(
                    id: "birthday-" + resolution.tagFullPath,
                    kind: .birthday,
                    title: "\(resolution.displayName)'s birthday",
                    subtitle: "\(photos.count) photos",
                    photoRefs: refs,
                    validFrom: startOfToday,
                    validTo: startOfTomorrow,
                    priority: 100
                ))
            }
        }

        // 3. Fallback: use any other stored memory (trip, person, folder, etc.)
        //    so the widget always shows real content when memories exist.
        if items.isEmpty {
            let fallback = memories.first { $0.type != .onThisDay && $0.type != .yearsAgo }
            if let fallback {
                let refs = orderedRefs(for: fallback, photoByID: photoByID, folderIdByURL: folderIdByURL)
                if !refs.isEmpty {
                    items.append(MemorySnapshotItem(
                        id: fallback.id,
                        kind: .other,
                        title: fallback.title,
                        subtitle: fallback.subtitle,
                        photoRefs: refs,
                        validFrom: startOfToday,
                        validTo: startOfTomorrow,
                        priority: 10
                    ))
                }
            }
        }

        return items.sorted { $0.priority > $1.priority }
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
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return }

        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let flat = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        if let data = flat.jpegData(compressionQuality: thumbQuality) {
            try? data.write(to: dest, options: .atomic)
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
            Log.widget.error("Failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
