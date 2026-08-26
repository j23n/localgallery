import SwiftUI

/// Live (and last-run) journal of what Scan Photos wrote. Openable while
/// a run is still going — newest sidecar first, not a second library grid.
struct ScanActivityView: View {
    @Environment(GalleryStore.self) private var store
    @State private var filter: Filter = .all
    @State private var searchText = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, tagging, faces, places, onFile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .tagging: return "Tagging"
            case .faces: return "Faces"
            case .places: return "Places"
            case .onFile: return "On file"
            }
        }

        var phase: ScanActivityEntry.Phase? {
            switch self {
            case .all: return nil
            case .tagging: return .tagging
            case .faces: return .faces
            case .places: return .places
            case .onFile: return .faces
            }
        }
    }

    private var activity: ScanActivityLog { store.analysis.activity }

    private var filtered: [ScanActivityEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sourceEntries.filter { entry in
            if filter != .onFile, let phase = filter.phase, entry.phase != phase { return false }
            guard !needle.isEmpty else { return true }
            if entry.filename.lowercased().contains(needle) { return true }
            if entry.summary.lowercased().contains(needle) { return true }
            return entry.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    /// Live journal, or the library photos that already name a person we
    /// never boxed.
    private var sourceEntries: [ScanActivityEntry] {
        if filter == .onFile {
            return store.allPhotos
                .filter { !$0.peopleTagsWithoutFace.isEmpty }
                .map(ScanActivityEntry.onFile)
        }
        return activity.entries
    }

    var body: some View {
        Group {
            if sourceEntries.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText.isEmpty ? filter.title : searchText)
            } else {
                List(filtered) { entry in
                    NavigationLink {
                        ScanActivityDetailView(entry: entry, album: album)
                    } label: {
                        ScanActivityRow(entry: entry)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Scan Activity")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filename or tag")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Phase", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                emptyTitle,
                systemImage: "list.bullet.rectangle"
            )
        } description: {
            Text(emptyDescription)
        }
    }

    private var emptyTitle: String {
        if filter == .onFile { return "None on file" }
        return store.analysis.isRunning ? "Waiting for the first sidecar…" : "No activity yet"
    }

    private var emptyDescription: String {
        if filter == .onFile {
            return "No photos have a People tag without a detected face."
        }
        return store.analysis.isRunning
            ? "Photos appear here as tagging, faces, and places write sidecars."
            : "Scan the library to see what this run wrote."
    }

    /// The run as a swipeable album: unique photos, newest first.
    private var album: [PhotoFile] {
        var seen = Set<UUID>()
        var photos: [PhotoFile] = []
        for entry in activity.entries {
            guard seen.insert(entry.photoID).inserted else { continue }
            photos.append(store.photo(forActivity: entry.url, photoID: entry.photoID) ?? entry.fallbackPhoto)
        }
        return photos
    }
}

private struct ScanActivityRow: View {
    let entry: ScanActivityEntry
    @Environment(GalleryStore.self) private var store

    private var isRemote: Bool {
        store.photo(forActivity: entry.url, photoID: entry.photoID)?.locality.isRemotePlaceholder ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: entry.url, size: 44, cornerRadius: 6, isRemote: isRemote)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(entry.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(entry.outcome.isFailed ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: entry.phase.icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private extension ScanActivityEntry.Outcome {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// One photo from the run: what this pass wrote, then the real viewer.
struct ScanActivityDetailView: View {
    let entry: ScanActivityEntry
    let album: [PhotoFile]

    @Environment(GalleryStore.self) private var store
    @State private var viewerPhoto: PhotoFile?
    @State private var viewerCurrentID: UUID = UUID()
    @State private var photoTools = PhotoToolsMetadata()

    private var photo: PhotoFile {
        store.photo(forActivity: entry.url, photoID: entry.photoID) ?? entry.fallbackPhoto
    }

    private var relatedLogs: [LogStore.Entry] {
        let filename = entry.filename
        let fileToken = Log.r.filename(filename)
        let pathToken = Log.r.path(entry.url)
        return LogStore.shared.entries.filter { log in
            log.message.contains(filename)
                || log.message.contains(fileToken)
                || log.message.contains(pathToken)
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    ThumbnailView(
                        url: entry.url,
                        size: 160,
                        cornerRadius: 12,
                        isRemote: photo.locality.isRemotePlaceholder
                    )
                    .frame(width: 160, height: 160)
                    Spacer()
                }
                .listRowBackground(Color.clear)

                LabeledContent("File", value: entry.filename)
                LabeledContent("Phase", value: entry.phase.label)
                LabeledContent("Result", value: resultLabel)
            }

            if entry.phase != .faces, !entry.tags.isEmpty {
                Section("Tags") {
                    ForEach(Array(entry.tags.enumerated()), id: \.offset) { _, tag in
                        Label(tag, systemImage: TagNamespace.icon(for: HierarchicalTag(raw: tag).namespace))
                    }
                }
            }

            if entry.phase == .faces {
                if !entry.peopleWithoutDetection.isEmpty {
                    Section("On file · no face") {
                        ForEach(Array(entry.peopleWithoutDetection.enumerated()), id: \.offset) { _, tag in
                            Label(HierarchicalTag(raw: tag).displayName, systemImage: "person")
                        }
                    }
                }
                if !entry.faceNames.isEmpty {
                    Section("Detected") {
                        ForEach(Array(entry.faceNames.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "person.fill")
                        }
                    }
                } else if entry.peopleWithoutDetection.isEmpty {
                    Section("Detected") {
                        Text("No face detected")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !entry.faceNames.isEmpty {
                Section("Faces") {
                    ForEach(Array(entry.faceNames.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "person.fill")
                    }
                }
            }

            if !photoTools.isEmpty {
                Section("photo-tools") {
                    if let version = photoTools.taggerVersion {
                        LabeledContent("Tagger Version", value: version)
                    }
                    if let tagged = photoTools.taggedAt {
                        LabeledContent("Tagged At", value: tagged)
                    }
                    if let model = photoTools.clipModel {
                        LabeledContent("CLIP Model", value: model)
                    }
                    if let stamp = photoTools.clipTimestamp {
                        LabeledContent("CLIP Timestamp", value: stamp)
                    }
                    if let pack = photoTools.facePack {
                        LabeledContent("Face Model", value: pack)
                    }
                    if let faceAt = photoTools.faceTaggedAt {
                        LabeledContent("Face Timestamp", value: faceAt)
                    }
                }
            }

            Section {
                Button {
                    viewerCurrentID = photo.id
                    viewerPhoto = photo
                } label: {
                    Label("Open photo", systemImage: "photo")
                }
            }

            if !relatedLogs.isEmpty {
                Section("Logs") {
                    ForEach(relatedLogs.suffix(20)) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.category.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(log.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle(entry.filename)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: entry.id) {
            photoTools = await store.loadPhotoToolsMetadata(for: photo)
        }
        .fullScreenCover(item: $viewerPhoto) { _ in
            PhotoViewerView(photos: album.isEmpty ? [photo] : album, currentPhotoID: $viewerCurrentID)
        }
    }

    private var resultLabel: String {
        switch entry.outcome {
        case .written: return "Written"
        case .skipped: return "Skipped"
        case .existing: return "On file · no face detected"
        case .failed(let reason): return reason.isEmpty ? "Failed" : "Failed · \(reason)"
        }
    }
}
