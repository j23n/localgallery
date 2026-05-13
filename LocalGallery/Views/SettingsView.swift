import SwiftUI

struct SettingsView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @AppStorage("crashReportingEnabled") private var crashReportingEnabled = false
    private var crashService = CrashDiagnosticsService.shared

    private static let githubURL = URL(string: "https://github.com/j23n/localgallery")!

    var body: some View {
        @Bindable var store = store
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
                        Task { await store.rescan(silent: false) }
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
                    Toggle(isOn: $store.birthdayMemoriesEnabled) {
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
                            Text(store.hiddenPeople.isEmpty ? "None" : String(store.hiddenPeople.count))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Hidden People", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                }

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

                    if crashReportingEnabled, crashService.hasPendingCrash {
                        crashRows
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("When on, LocalGallery captures crash details and recent log entries on this device. Nothing is sent automatically — if a crash is captured, a banner appears here in Settings and you can choose to share the report with the developer. Logs include file names and folder paths from your library. Off by default. App Store crash analytics (system-level) are unaffected by this setting.")
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
            .sheet(isPresented: $showPicker) {
                DocumentPicker { pickerURL in
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
    }

    /// Display name of the currently-marked "me" person, or "Not set".
    private var meSummary: String {
        guard !store.mePersonPath.isEmpty,
              let me = store.peopleTags.first(where: { $0.fullPath == store.mePersonPath })
        else { return "Not set" }
        return me.displayName
    }

    /// One-line summary of linked / auto-matched contacts for the Settings row.
    /// Uses `linkState` so we don't linear-scan `store.contacts` per person on
    /// every body re-evaluation.
    private var linkedContactsSummary: String {
        var total = 0
        for person in store.peopleTags {
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
        switch progress.phase {
        case .scanning:
            return "\(progress.processed.formatted()) found"
        case .enriching:
            if let total = progress.total, total > 0 {
                let elapsed = Date().timeIntervalSince(progress.startedAt)
                if progress.processed > 0, elapsed > 1 {
                    let throughput = Double(progress.processed) / elapsed
                    let remaining = max(0, total - progress.processed)
                    let secs = Int((Double(remaining) / max(throughput, 0.001)).rounded())
                    if secs > 0 {
                        let m = secs / 60
                        let s = secs % 60
                        let eta = m > 0 ? String(format: "~%d:%02d", m, s) : "~\(s)s"
                        return "\(progress.processed.formatted()) / \(total.formatted()) · \(eta)"
                    }
                }
                return "\(progress.processed.formatted()) / \(total.formatted())"
            }
            return "\(progress.processed.formatted())"
        }
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

    // MARK: - Cloud Storage

    @State private var cloudStats: GalleryStore.CloudStorageStats?
    @State private var isClearingDownloads = false
    @State private var showClearDownloadsAlert = false
    @State private var showClearSidecarsAlert = false

    @ViewBuilder
    private var cloudStorageSection: some View {
        @Bindable var store = store
        Section("Cloud Storage") {
            if let stats = cloudStats {
                LabeledContent("Downloaded") {
                    Text("\(stats.materializedCount) (\(formatBytes(stats.materializedBytes)))")
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
                    cloudStats = store.computeCloudStorageStats()
                }
            }
        } message: {
            Text("Photos will need to download again the next time you open them. Thumbnails and tags are kept.")
        }
        .alert("Re-download all sidecars?", isPresented: $showClearSidecarsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Re-download", role: .destructive) {
                store.clearSidecarCache()
                Task { await store.rescan(silent: true) }
            }
        } message: {
            Text("This wipes the cached `.xmp` data and re-fetches everything on the next sync. Tags and country codes will reappear once the sync completes.")
        }
        .task {
            cloudStats = store.computeCloudStorageStats()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Hidden People sub-screen

struct HiddenPeopleList: View {
    @Environment(GalleryStore.self) private var store

    var body: some View {
        Group {
            let hidden = store.hiddenPeopleTags
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
                Text("\(person.count) \(person.count == 1 ? "photo" : "photos")")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink3)
            }
            Spacer()
            Button {
                store.unhidePerson(person.fullPath)
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
        let all = store.peopleTags
        guard !searchText.isEmpty else { return all }
        let needle = searchText.lowercased()
        return all.filter { $0.displayName.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    store.unmarkAsMe()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.xmark")
                        Text("Not set")
                        Spacer()
                        if store.mePersonPath.isEmpty {
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
                        store.markAsMe(person.fullPath)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Design.ink3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.displayName)
                                    .foregroundStyle(Design.ink)
                                Text("\(person.count) \(person.count == 1 ? "photo" : "photos")")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Design.ink3)
                            }
                            Spacer()
                            if store.mePersonPath == person.fullPath {
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
