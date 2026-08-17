import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @AppStorage("crashReportingEnabled") private var crashReportingEnabled = false
    private let crashService = CrashDiagnosticsService.shared

    private static let githubURL = URL(string: "https://github.com/j23n/localgallery")!

    var body: some View {
        @Bindable var store = store
        @Bindable var memories = store.memories
        NavigationStack {
            List {
                Section("Photo Library") {
                    Button {
                        showPicker = true
                    } label: {
                        LabeledContent {
                            Text(store.resolveBookmark()?.lastPathComponent ?? "Not selected")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                    }
                    .tint(.primary)

                    Button {
                        Task { await store.rescan(kind: .full, silent: false) }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isScanning)

                    if let lastSync = store.lastSyncedAt {
                        LabeledContent("Last Synced", value: lastSync,
                                       format: .dateTime.month(.abbreviated).day().hour().minute())
                    }

                    if let progress = store.scanProgress {
                        scanProgressRow(progress)
                    } else if store.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Scanning folder…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if store.hasFileProviderPhotos {
                    cloudStorageSection
                }

                Section("People") {
                    Toggle(isOn: $memories.birthdaysEnabled) {
                        Label("Birthday Memories", systemImage: "birthday.cake")
                    }

                    NavigationLink {
                        MePersonPicker()
                    } label: {
                        LabeledContent {
                            Text(meSummary).foregroundStyle(.secondary)
                        } label: {
                            Label("Me", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }

                    NavigationLink {
                        LinkedContactsList()
                    } label: {
                        LabeledContent {
                            Text(linkedContactsSummary)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Linked Contacts", systemImage: "person.text.rectangle")
                        }
                    }

                    NavigationLink {
                        HiddenPeopleList()
                    } label: {
                        LabeledContent {
                            Text(store.people.hiddenPeople.isEmpty ? "None" : String(store.people.hiddenPeople.count))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Hidden People", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                }

                taggingSection

                Section("Stats") {
                    LabeledContent("Photos", value: "\(store.allPhotos.count)")
                    LabeledContent("People", value: "\(tagCount(namespace: "people"))")
                    LabeledContent("Objects", value: "\(tagCount(namespace: "objects"))")
                    LabeledContent("Scenes", value: "\(tagCount(namespace: "scenes"))")
                }

                Section {
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    LabeledContent("Version", value: appVersion)
                    Toggle("Crash Reporting", isOn: $crashReportingEnabled)

                    ShareLink(item: LogRedactor.shared.keyFileURL) {
                        Label("Export Redaction Key", systemImage: "key.fill")
                    }
                    .tint(.primary)

                    if crashReportingEnabled, crashService.hasPendingCrash {
                        crashRows
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("When on, LocalGallery captures crash details and recent log entries on this device. Nothing is sent automatically — if a crash is captured, a banner appears here in Settings and you can choose to share the report with the developer. Folder names, person names, tags, memory titles, and file paths in logs are replaced with anonymous tokens like \"folder#7\". Export the Redaction Key on this device to reverse-map tokens back to the originals locally — the key file is never bundled with crash reports. App Store crash analytics (system-level) are unaffected by this setting.")
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LocalGallery browses photos from a folder of your choice — no import, no library, no accounts.")
                            .font(.callout)

                        Text("Found a bug or have feedback? Open an issue or get in touch:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Button {
                        openURL(Self.githubURL)
                    } label: {
                        LabeledContent {
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: crashReportingEnabled) { _, newValue in
                CrashDiagnosticsService.shared.setEnabled(newValue)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    crashService.refreshPendingCrash()
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                guard case .success(let pickerURL) = result else { return }
                // Bookmark creation needs an active security scope; the
                // long-lived scope is then (re)opened on the *resolved* URL
                // via startAccessingFolder, so this transient one is closed
                // immediately.
                _ = pickerURL.startAccessingSecurityScopedResource()
                store.saveBookmark(for: pickerURL)
                pickerURL.stopAccessingSecurityScopedResource()

                if let resolvedURL = store.resolveBookmark() {
                    Task {
                        store.startAccessingFolder(resolvedURL)
                        await store.scanFolder(at: resolvedURL)
                    }
                }
            }
        }
    }

    /// Display name of the currently-marked "me" person, or "Not set".
    private var meSummary: String {
        guard !store.people.mePersonPath.isEmpty,
              let me = store.people.peopleTags.first(where: { $0.fullPath == store.people.mePersonPath })
        else { return "Not set" }
        return me.displayName
    }

    /// One-line summary of linked / auto-matched contacts for the Settings row.
    /// Uses `linkState` so we don't linear-scan `store.contacts` per person on
    /// every body re-evaluation.
    private var linkedContactsSummary: String {
        var total = 0
        for person in store.people.peopleTags {
            switch store.linkState(forPersonPath: person.fullPath, displayName: person.displayName) {
            case .manual, .auto: total += 1
            case .disabled, .unlinked: break
            }
        }
        return total == 0 ? "None" : "\(total)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func tagCount(namespace: String) -> Int {
        store.allTags.reduce(into: 0) { count, tag in
            if tag.namespace?.lowercased() == namespace { count += 1 }
        }
    }

    @ViewBuilder
    private func scanProgressRow(_ progress: ScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.label)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(scanProgressDetail(progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            switch progress.phase {
            case .scanning:
                ProgressView().progressViewStyle(.linear)
            case .enriching:
                if let total = progress.total, total > 0 {
                    ProgressView(value: Double(progress.processed), total: Double(total))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }

    private func scanProgressDetail(_ progress: ScanProgress) -> String {
        // Shared count/ETA text — see `ScanProgress.countText`.
        progress.countText
    }

    // MARK: - Crash banner

    @ViewBuilder
    private var crashRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("LocalGallery crashed last session", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text("A crash report was captured. You can share it with the developer to help diagnose the issue, or dismiss it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)

        Button {
            shareCrashReport()
        } label: {
            Label("Share Crash Report", systemImage: "square.and.arrow.up")
        }

        Button(role: .destructive) {
            crashService.clearPendingCrash()
        } label: {
            Label("Dismiss", systemImage: "xmark.circle")
        }
    }

    private func shareCrashReport() {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        var items: [Any] = []

        if let crashData = crashService.pendingCrashReport() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("localgallery-crash-\(stamp).json")
            if (try? crashData.write(to: url, options: .atomic)) != nil {
                items.append(url)
            }
        }

        if let logData = crashService.recentLogTail() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("localgallery-logs-\(stamp).txt")
            if (try? logData.write(to: url, options: .atomic)) != nil {
                items.append(url)
            }
        }

        guard !items.isEmpty else { return }
        ShareSheet.present(items: items)
    }

    // MARK: - On-device tagging

    @State private var showModelPackPicker = false
    @State private var showResetTaggingAlert = false
    @State private var showRemovePackAlert = false

    /// Tagging status, model-pack import, and the "Tag Library Now" run
    /// controls. The section is always present — with no pack installed it
    /// explains what's missing rather than hiding the feature.
    @ViewBuilder
    private var taggingSection: some View {
        let tagging = store.tagging
        Section {
            LabeledContent {
                Text(modelPackSummary)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Model Pack", systemImage: "shippingbox")
            }

            // Where the active pack came from. Worth a row of its own because
            // the two sources behave differently: the bundled pack cannot be
            // removed, and an imported one is only in use while it is the
            // newest.
            if let pack = tagging.pack {
                LabeledContent {
                    Text(pack.source.label)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Source", systemImage: pack.source == .bundled ? "shippingbox.fill" : "tray.and.arrow.down")
                }
            }

            Button {
                showModelPackPicker = true
            } label: {
                Label("Import Model Pack…", systemImage: "square.and.arrow.down")
            }
            .tint(.primary)
            .disabled(tagging.isRunning)

            // Only for an imported pack: the bundled one ships with the app
            // and there is nothing to delete.
            if tagging.pack?.source == .imported {
                Button(role: .destructive) {
                    showRemovePackAlert = true
                } label: {
                    Label("Remove Imported Pack", systemImage: "trash")
                }
                .disabled(tagging.isRunning)
            }

            if tagging.isRunning {
                taggingProgressRow
                Button(role: .destructive) {
                    tagging.cancel()
                } label: {
                    Label("Cancel Tagging", systemImage: "stop.circle")
                }
            } else {
                Button {
                    Task { await store.tagging.startTagging() }
                } label: {
                    Label("Tag Library Now", systemImage: "sparkles.rectangle.stack")
                }
                // Not while a face scan is running: the two engines hold
                // separate SQLite connections to the same cache file, and WAL
                // allows one writer. Serialising them here is cheaper (and far
                // more legible) than teaching both to retry SQLITE_BUSY.
                .disabled(
                    !tagging.isAvailable || store.isScanning || store.allPhotos.isEmpty
                        || store.faces.isRunning
                )
            }

            // Recovery for a queue that has got itself stuck: rows that failed
            // out of their retry budget, or paths left over from a library
            // root the user has moved away from. Cached embeddings survive the
            // reset, so re-tagging afterwards costs a hash per photo, not an
            // inference.
            Button(role: .destructive) {
                showResetTaggingAlert = true
            } label: {
                Label("Reset Tagging Data", systemImage: "arrow.counterclockwise")
            }
            .disabled(!tagging.isAvailable || tagging.isRunning)

            if let summary = tagging.lastSummary {
                LabeledContent("Last Run") {
                    Text(Self.summaryLine(summary))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = tagging.lastError, error != .cancelled {
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            facesRows
        } header: {
            Text("On-device Tagging")
        } footer: {
            Text(taggingFooter)
        }
        .fileImporter(isPresented: $showModelPackPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await store.tagging.importModelPack(from: url) }
        }
        .alert("Remove imported pack?", isPresented: $showRemovePackAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task { await store.tagging.removeImportedPack() }
            }
        } message: {
            Text("Deletes the imported model pack and goes back to the one that ships with the app. Tags already written to `.xmp` sidecars are kept.")
        }
        .alert("Reset tagging data?", isPresented: $showResetTaggingAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                Task { await store.tagging.resetQueue() }
            }
        } message: {
            Text("Clears the tagging queue so every photo is considered again. Tags already written to `.xmp` sidecars are kept, and the cached image embeddings are kept too, so re-tagging does not re-run inference.")
        }
        .task {
            // Cheap on repeat visits: a pack whose manifest hasn't changed
            // since it was verified isn't re-hashed. See `PackFingerprint`.
            await store.tagging.refreshAvailability()
        }
    }

    private var modelPackSummary: String {
        let tagging = store.tagging
        if let pack = tagging.pack {
            return "\(pack.version) · \(pack.labelCount) labels"
        }
        return tagging.hasCheckedForPack ? "None installed" : "Checking…"
    }

    /// What the section says about itself.
    ///
    /// The app ships a pack, so "no pack" is no longer a state the user is
    /// expected to be in: either this build never staged one
    /// (`scripts/prepare_pack.sh`) or the bundled one failed verification.
    /// Only the first is fixed by importing, so only the first says so.
    private var taggingFooter: String {
        let tagging = store.tagging
        let base = "Tags photos with the photo-tools Objects and Scenes taxonomy and writes the result into each photo's `.xmp` sidecar — the image files are never modified. Everything runs on this device, and tagging a photo twice writes nothing. A pack that also ships face models adds face scanning: groups of faces appear under People › Review New People, and naming one writes `People/<name>` keywords and face regions to the same sidecars."
        guard tagging.hasCheckedForPack, tagging.pack == nil else {
            return base + " Importing a newer pack replaces the one in use; whichever pack has the higher version wins."
        }
        if tagging.hasBundledPack {
            return base + " The model pack that ships with this build could not be verified. Importing a pack replaces it."
        }
        return base + " This build ships no model pack, so tagging is off until you import one."
    }

    @ViewBuilder
    private var taggingProgressRow: some View {
        let progress = store.tagging.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Tagging…")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let progress {
                    Text("\(progress.done) / \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    // MARK: - Faces

    /// The faces half of the On-device Tagging section.
    ///
    /// Rows rather than a section of its own: faces come from the *same* model
    /// pack, and a separate section would imply a separate thing to install.
    /// Present only when the installed pack actually ships face models — a
    /// tagging-only pack is valid, so there is nothing to explain.
    @ViewBuilder
    private var facesRows: some View {
        let faces = store.faces
        if faces.isAvailable {
            if faces.isRunning {
                facesProgressRow
                Button(role: .destructive) {
                    faces.cancel()
                } label: {
                    Label("Cancel Face Scan", systemImage: "stop.circle")
                }
            } else {
                Button {
                    Task { await store.faces.startScan() }
                } label: {
                    Label("Scan Faces", systemImage: "person.crop.square.badge.camera")
                }
                .disabled(store.isScanning || store.allPhotos.isEmpty || store.tagging.isRunning)
            }

            if let summary = faces.lastSummary {
                LabeledContent("Last Face Scan") {
                    Text(Self.faceSummaryLine(summary))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = faces.lastError, error != .cancelled {
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var facesProgressRow: some View {
        let progress = store.faces.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding faces…")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let progress {
                    Text("\(progress.done) / \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private static func faceSummaryLine(_ summary: FaceService.Summary) -> String {
        if summary.processed == 0 && summary.facesFound == 0 {
            return summary.cancelled ? "Cancelled" : "Nothing to do"
        }
        var parts = ["\(summary.facesFound) faces", "\(summary.clustersCreated) new groups"]
        if summary.sidecarsWritten > 0 { parts.append("\(summary.sidecarsWritten) written") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.cancelled { parts.append("cancelled") }
        return parts.joined(separator: ", ")
    }

    private static func summaryLine(_ summary: TaggingService.Summary) -> String {
        if summary.processed == 0 && summary.sidecarsWritten == 0 {
            return summary.cancelled ? "Cancelled" : "Nothing to do"
        }
        var parts = ["\(summary.tagged) tagged", "\(summary.sidecarsWritten) written"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.cancelled { parts.append("cancelled") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Cloud Storage

    @State private var cloudStats: CloudStorageService.Stats?
    @State private var isClearingDownloads = false
    @State private var showClearDownloadsAlert = false
    @State private var showClearSidecarsAlert = false

    @ViewBuilder
    private var cloudStorageSection: some View {
        @Bindable var store = store
        Section("Cloud Storage") {
            if let stats = cloudStats {
                LabeledContent("Downloaded") {
                    Text("\(stats.materializedCount) (\(EXIFFormatters.fileSize(stats.materializedBytes)))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Placeholders") {
                    Text("\(stats.placeholderCount)")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Computing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                showClearDownloadsAlert = true
            } label: {
                Label("Clear All Downloads", systemImage: "icloud.slash")
            }
            .disabled(isClearingDownloads || (cloudStats?.materializedCount ?? 0) == 0)

            Toggle(isOn: $store.prefetchAdjacentRemotePhotos) {
                Label("Pre-fetch in Viewer", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Toggle(isOn: $store.useCellularForDownloads) {
                Label("Use Cellular for Downloads", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        Section("Sidecars") {
            Button(role: .destructive) {
                showClearSidecarsAlert = true
            } label: {
                Label("Re-download All Sidecars", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .alert("Clear all downloads?", isPresented: $showClearDownloadsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                isClearingDownloads = true
                Task {
                    _ = await store.clearAllDownloads()
                    isClearingDownloads = false
                    cloudStats = await store.computeCloudStorageStats()
                }
            }
        } message: {
            Text("Photos will need to download again the next time you open them. Thumbnails and tags are kept.")
        }
        .alert("Re-download all sidecars?", isPresented: $showClearSidecarsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Re-download", role: .destructive) {
                store.clearSidecarCache()
                Task { await store.rescan(kind: .full, silent: true) }
            }
        } message: {
            Text("This wipes the cached `.xmp` data and re-fetches everything on the next sync. Tags and country codes will reappear once the sync completes.")
        }
        .task {
            cloudStats = await store.computeCloudStorageStats()
        }
    }

}

// MARK: - Hidden People sub-screen

struct HiddenPeopleList: View {
    @Environment(GalleryStore.self) private var store

    var body: some View {
        Group {
            let hidden = store.people.hiddenPeopleTags
            if hidden.isEmpty {
                ContentUnavailableView {
                    Label("No hidden people", systemImage: "person.fill")
                } description: {
                    Text("Long-press any person in Collections to hide them. Hidden people stay out of the People row but their photos remain searchable.")
                }
            } else {
                List {
                    Section("\(hidden.count) Hidden") {
                        ForEach(hidden) { person in
                            HiddenPersonRow(person: person)
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden People")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HiddenPersonRow: View {
    let person: TagSuggestion
    @Environment(GalleryStore.self) private var store

    private var featured: PhotoFile? {
        store.photos(forTag: person).first
    }

    var body: some View {
        HStack(spacing: 12) {
            if let photo = featured {
                ThumbnailView(url: photo.url, size: 44, cornerRadius: 22, isRemote: photo.locality.isRemotePlaceholder)
                    .frame(width: 44, height: 44)
                    .saturation(0.7)
            } else {
                Circle()
                    .fill(Design.bgGrouped)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(Design.ink3)
                    }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(person.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Design.ink)
                Text(photoCountLabel(person.count))
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink3)
            }
            Spacer()
            Button {
                store.people.unhidePerson(person.fullPath)
            } label: {
                Text("Unhide")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Design.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Design.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - "Me" person picker

/// Choose which `People/<name>` tag represents the current user. Used by
/// trip-title generation to skip the user when listing companions
/// ("Chile with Anna & Bob"). Only one person can be marked at a time.
struct MePersonPicker: View {
    @Environment(GalleryStore.self) private var store
    @State private var searchText = ""

    private var people: [TagSuggestion] {
        let all = store.people.peopleTags
        guard !searchText.isEmpty else { return all }
        let needle = searchText.lowercased()
        return all.filter { $0.displayName.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    store.people.unmarkAsMe()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.xmark")
                        Text("Not set")
                        Spacer()
                        if store.people.mePersonPath.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Design.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Trip memory titles will exclude this person from the “with X, Y, Z” list. The list shows everyone tagged in your library.")
            }
            Section("People") {
                ForEach(people) { person in
                    Button {
                        store.people.markAsMe(person.fullPath)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Design.ink3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.displayName)
                                    .foregroundStyle(Design.ink)
                                Text(photoCountLabel(person.count))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Design.ink3)
                            }
                            Spacer()
                            if store.people.mePersonPath == person.fullPath {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Design.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search people")
        .navigationTitle("Me")
        .navigationBarTitleDisplayMode(.inline)
    }
}
