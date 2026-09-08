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

                    SettingsProgressRow(
                        title: "Reload Library",
                        systemImage: "arrow.clockwise",
                        phase: store.scanProgress?.shortLabel ?? "Scanning",
                        progressText: store.scanProgress?.countText,
                        isRunning: store.isScanning || store.scanProgress != nil,
                        disabled: store.analysis.isRunning,
                        idleTrailing: lastSyncedText
                    ) {
                        Task { await store.rescan(kind: .full, silent: false) }
                    } cancel: {
                        store.cancelScan()
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
                    LabeledContent("Places", value: "\(tagCount(namespace: "places"))")
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
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if build.isEmpty || build == short { return short }
        return "\(short) (\(build))"
    }

    private func tagCount(namespace: String) -> Int {
        store.allTags.reduce(into: 0) { count, tag in
            if tag.namespace?.lowercased() == namespace { count += 1 }
        }
    }

    /// `lastSyncedAt` as the Reload Library trailing value, same format the
    /// old "Last Synced" row used.
    private var lastSyncedText: String? {
        store.lastSyncedAt?.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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

    @ViewBuilder
    private var taggingSection: some View {
        let analysis = store.analysis
        Section {
            LabeledContent {
                Text(modelPackSummary)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Model Pack", systemImage: "shippingbox")
            }

            SettingsProgressRow(
                title: "Scan Photos",
                systemImage: "sparkles.rectangle.stack",
                phase: analysis.progress?.shortLabel ?? "Tagging",
                progressText: analysis.progress?.countText,
                isRunning: analysis.isRunning,
                disabled: store.isScanning || analysis.isRunning || store.allPhotos.isEmpty,
                idleTrailing: analysis.lastSummary.map { Self.analysisSummaryLine($0) }
            ) {
                Task { await analysis.start() }
            } cancel: {
                analysis.cancel()
            }

            NavigationLink {
                DropAndRescanView()
            } label: {
                Label("Drop and Rescan", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(store.isScanning || analysis.isRunning || store.allPhotos.isEmpty)

            NavigationLink {
                ScanActivityView()
            } label: {
                LabeledContent {
                    Text(scanActivitySubtitle)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Scan Activity", systemImage: "list.bullet.rectangle")
                }
            }

            if let error = analysis.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("On-device Tagging")
        } footer: {
            if let footer = taggingFooter {
                Text(footer)
            } else {
                Text("Scan Photos runs tagging, faces, and places, skipping work that is already current. Drop and Rescan overwrites one of those passes on every photo. Scan Activity → On file lists People tags with no detected face. Places uses Nominatim — GPS coordinates leave the device.")
            }
        }
        .task {
            await store.tagging.refreshAvailability()
        }
    }

    /// Idle count, or a waiting line while the run has not written yet.
    /// The row stays tappable during a scan — that is the point of the screen.
    private var scanActivitySubtitle: String {
        let activity = store.analysis.activity
        if store.analysis.isRunning, activity.entries.isEmpty {
            return "Waiting…"
        }
        if activity.entries.isEmpty { return "None" }
        return activity.entries.count.formatted()
    }

    private var modelPackSummary: String {
        let tagging = store.tagging
        if let pack = tagging.pack {
            return "\(pack.version) · \(pack.labelCount) labels"
        }
        return tagging.hasCheckedForPack ? "None installed" : "Checking…"
    }

    /// Footer only when there is no usable pack — tagging and faces stay off,
    /// but reverse-geocoding still runs from Scan Photos.
    private var taggingFooter: String? {
        let tagging = store.tagging
        guard tagging.hasCheckedForPack, tagging.pack == nil else { return nil }
        if tagging.hasBundledPack {
            return "The model pack that ships with this build could not be verified. Tagging and face scanning are off; place names from GPS still work (Nominatim)."
        }
        return "This build ships no model pack, so tagging and face scanning are off. Place names from GPS still work (Nominatim — coordinates leave the device)."
    }

    private static func analysisSummaryLine(_ summary: LibraryAnalysis.Summary) -> String {
        if summary.cancelled
            && summary.tagging == nil
            && summary.faces == nil
            && summary.places == nil
        {
            return "Cancelled"
        }
        var parts: [String] = []
        if let tagging = summary.tagging {
            if tagging.tagged > 0 { parts.append("\(tagging.tagged) tagged") }
            else if tagging.processed > 0 { parts.append("\(tagging.processed) photos") }
        }
        if let faces = summary.faces, faces.facesFound > 0 {
            parts.append("\(faces.facesFound) faces")
        }
        if let places = summary.places, places.written > 0 {
            parts.append("\(places.written) places")
        }
        if let tagging = summary.tagging, tagging.failed > 0 { parts.append("\(tagging.failed) failed") }
        if let faces = summary.faces, faces.failed > 0 { parts.append("\(faces.failed) failed") }
        if let places = summary.places, places.failed > 0 { parts.append("\(places.failed) failed") }
        if summary.cancelled { parts.append("cancelled") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
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

/// One Settings action row that keeps its title and swaps the trailing
/// accessory: idle value on the right (last synced / last scan), or the
/// shared progress chip + Cancel while running.
private struct SettingsProgressRow: View {
    let title: String
    let systemImage: String
    let phase: String
    let progressText: String?
    let isRunning: Bool
    let disabled: Bool
    var idleTrailing: String? = nil
    let action: () -> Void
    let cancel: () -> Void

    var body: some View {
        if isRunning {
            HStack(spacing: 8) {
                ScanProgressChip(phase: phase, detail: progressText)
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .layoutPriority(2)
            }
        } else {
            Button(action: action) {
                if let idleTrailing {
                    LabeledContent {
                        Text(idleTrailing)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(title, systemImage: systemImage)
                    }
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .tint(.primary)
            .disabled(disabled)
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
