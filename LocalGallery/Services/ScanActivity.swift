import Foundation
import Observation

/// One photo the current (or last) analysis run touched.
///
/// Ids and strings only — no `PhotoFile`, no bitmap. The list cell loads a
/// thumbnail through the existing cache; the viewer resolves the photo from
/// the Store when the user opens it.
struct ScanActivityEntry: Identifiable, Equatable, Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case tagging, faces, places

        var label: String {
            switch self {
            case .tagging: return "Tagging"
            case .faces: return "Faces"
            case .places: return "Places"
            }
        }

        var icon: String {
            switch self {
            case .tagging: return "tag.fill"
            case .faces: return "person.crop.rectangle"
            case .places: return "mappin.and.ellipse"
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case written
        case skipped
        case failed(String)
        /// On the file already; this run did not write it. Used for People
        /// keywords that have no matching detection.
        case existing
    }

    let id: UUID
    let photoID: UUID
    let url: URL
    let filename: String
    let at: Date
    let phase: Phase
    let outcome: Outcome
    /// Hierarchical paths relevant to `phase` (`Objects/…`, `People/…`, `Places/…`).
    let tags: [String]
    let faceNames: [String]

    var faceCount: Int { faceNames.count }

    /// People keywords whose leaf is not in `faceNames`.
    var peopleWithoutDetection: [String] {
        let detected = Set(faceNames.map { $0.lowercased() })
        return tags.filter { tag in
            let leaf = HierarchicalTag(raw: tag).displayName
            return !detected.contains(leaf.lowercased())
        }
    }

    /// Last-resort stand-in when the Store cannot resolve this url. The
    /// viewer must prefer `GalleryStore.photo(forActivity:)` — this stub
    /// is 0 bytes and has no tags, which is what "Open photo" showed when
    /// the journal id missed the library row.
    var fallbackPhoto: PhotoFile {
        PhotoFile(id: photoID, url: url, filename: filename, fileSize: 0, dateTaken: nil)
    }

    /// One-line list subtitle.
    var summary: String {
        switch outcome {
        case .failed(let reason):
            return reason.isEmpty ? "failed" : "failed · \(reason)"
        case .skipped:
            if let first = tags.first {
                return "skipped · \(HierarchicalTag(raw: first).displayName)"
            }
            return "skipped"
        case .existing:
            if !peopleWithoutDetection.isEmpty {
                let names = peopleWithoutDetection.map { HierarchicalTag(raw: $0).displayName }
                return "on file · no face · \(names.joined(separator: " · "))"
            }
            return "on file · no face"
        case .written:
            if !tags.isEmpty {
                return tags.map { HierarchicalTag(raw: $0).displayName }.joined(separator: " · ")
            }
            if faceCount > 0 {
                return faceCount == 1 ? "1 face" : "\(faceCount) faces"
            }
            return "no tags"
        }
    }

    /// A library photo that already carries `People/` with no matching box.
    static func onFile(photo: PhotoFile) -> ScanActivityEntry {
        let standardized = photo.url.standardizedFileURL
        return ScanActivityEntry(
            id: photo.id,
            photoID: photo.id,
            url: standardized,
            filename: photo.filename,
            at: Date(),
            phase: .faces,
            outcome: .existing,
            tags: photo.peopleTagsWithoutFace.map(\.fullPath),
            faceNames: photo.faceRegions.compactMap(\.name)
        )
    }

    static func place(
        url: URL,
        path: String?,
        outcome: Outcome,
        at: Date = Date()
    ) -> ScanActivityEntry {
        let standardized = url.standardizedFileURL
        return ScanActivityEntry(
            id: UUID(),
            photoID: PhotoFile.stableID(for: standardized),
            url: standardized,
            filename: standardized.lastPathComponent,
            at: at,
            phase: .places,
            outcome: outcome,
            tags: path.map { [$0] } ?? [],
            faceNames: []
        )
    }
}

/// In-memory journal of one analysis run. Newest first, capped so a 20k
/// library cannot grow without bound across repeated scans.
///
/// Appends are batched (the core already reports tagging/faces in 32-photo
/// chunks). Sidecar reads stay off the main actor; only the finished
/// records hop back.
@Observable
@MainActor
final class ScanActivityLog {
    static let cap = 20_000

    private(set) var entries: [ScanActivityEntry] = []
    /// Bumped on `beginRun` so an in-flight ingest from the *previous* run
    /// cannot append after we cleared.
    private var generation = 0

    func beginRun() {
        generation += 1
        entries = []
    }

    /// Parse sidecars for `paths` off the main actor, then prepend.
    func scheduleIngest(paths: [String], phase: ScanActivityEntry.Phase) {
        guard !paths.isEmpty else { return }
        let generation = self.generation
        Task { [weak self] in
            await self?.ingest(paths: paths, phase: phase, generation: generation)
        }
    }

    func ingest(
        paths: [String],
        phase: ScanActivityEntry.Phase,
        generation: Int? = nil
    ) async {
        let expected = generation ?? self.generation
        let batch = await Self.read(paths: paths, phase: phase)
        guard expected == self.generation else { return }
        prepend(batch)
    }

    func record(_ entry: ScanActivityEntry) {
        prepend([entry])
    }

    /// Chronological batch; the last element becomes newest.
    func record(_ batch: [ScanActivityEntry]) {
        prepend(batch)
    }

    private func prepend(_ batch: [ScanActivityEntry]) {
        guard !batch.isEmpty else { return }
        // A later sidecar write for the same photo replaces the earlier
        // "we scanned this" row so the journal does not double-count.
        let keys = Set(batch.map { Self.key(for: $0) })
        entries.removeAll { keys.contains(Self.key(for: $0)) }
        entries.insert(contentsOf: batch.reversed(), at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
    }

    private static func key(for entry: ScanActivityEntry) -> String {
        "\(entry.photoID.uuidString)|\(entry.phase.rawValue)"
    }

    nonisolated static func read(
        paths: [String],
        phase: ScanActivityEntry.Phase
    ) async -> [ScanActivityEntry] {
        await Task.detached(priority: .utility) {
            paths.map { entry(forImagePath: $0, phase: phase) }
        }.value
    }

    nonisolated static func entry(
        forImagePath path: String,
        phase: ScanActivityEntry.Phase,
        at: Date = Date()
    ) -> ScanActivityEntry {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let sidecar = URL(fileURLWithPath: path + ".xmp")
        var tags: [String] = []
        var faceNames: [String] = []
        if let data = try? Data(contentsOf: sidecar) {
            let parsed = parseXmpBytes(bytes: data)
            tags = parsed.rawTags.filter { tag in
                let ns = tag.split(separator: "/").first.map(String.init)?.lowercased()
                switch phase {
                case .tagging: return ns == "objects" || ns == "scenes" || ns == "landmarks"
                case .faces: return ns == "people"
                case .places: return ns == "places"
                }
            }
            if phase == .faces {
                faceNames = parsed.faceRegions.compactMap(\.name)
            }
        }
        return ScanActivityEntry(
            id: UUID(),
            photoID: PhotoFile.stableID(for: url),
            url: url,
            filename: url.lastPathComponent,
            at: at,
            phase: phase,
            outcome: .written,
            tags: tags,
            faceNames: faceNames
        )
    }
}
