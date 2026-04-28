import SwiftUI

struct SettingsView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

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
                        Task { await store.rescan() }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isScanning)

                    if let lastSync = store.lastSyncedAt {
                        LabeledContent("Last Synced", value: lastSync, format: .dateTime)
                    }

                    if store.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Scanning folder…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("People") {
                    Toggle(isOn: $store.birthdayMemoriesEnabled) {
                        Label("Birthday Memories", systemImage: "birthday.cake")
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

                Section("Info") {
                    LabeledContent("Photos", value: "\(store.allPhotos.count)")
                    LabeledContent("Tags", value: "\(store.allTags.count)")
                    LabeledContent("Version", value: appVersion)
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
                ThumbnailView(url: photo.url, size: 44, cornerRadius: 22)
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
