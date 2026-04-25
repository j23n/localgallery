import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var manager: GalleryManager
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Photo Library") {
                    Button {
                        showPicker = true
                    } label: {
                        LabeledContent {
                            Text(manager.resolveBookmark()?.lastPathComponent ?? "Not selected")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                    }
                    .tint(.primary)

                    Button {
                        Task { await manager.rescan() }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }

                    if let lastSync = manager.lastSyncedAt {
                        LabeledContent("Last Synced") {
                            Text(lastSync, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("People") {
                    Toggle(isOn: $manager.birthdayMemoriesEnabled) {
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
                            Text(manager.hiddenPeople.isEmpty ? "None" : String(manager.hiddenPeople.count))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Hidden People", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                }

                Section("Info") {
                    LabeledContent("Photos", value: "\(manager.allPhotos.count)")
                    LabeledContent("Tags", value: "\(manager.allTags.count)")
                    LabeledContent("Version", value: appVersion)
                }

                Section {
                    Text("LocalGallery — read-only viewer")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
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
                    manager.saveBookmark(for: pickerURL)
                    pickerURL.stopAccessingSecurityScopedResource()

                    if let resolvedURL = manager.resolveBookmark() {
                        Task {
                            manager.startAccessingFolder(resolvedURL)
                            await manager.scanFolder(at: resolvedURL)
                        }
                    }
                }
            }
        }
    }

    /// One-line summary of linked / auto-matched contacts for the Settings row.
    private var linkedContactsSummary: String {
        let manualCount = manager.personContactLinks.values.filter { !$0.isEmpty }.count
        let autoCount = manager.peopleTags.filter { person in
            // Auto-match only — exclude any manual override (including the
            // "" disabled sentinel).
            guard manager.personContactLinks[person.fullPath] == nil else { return false }
            let target = person.displayName.lowercased()
            return manager.contacts.contains { $0.fullName.lowercased() == target }
        }.count
        let total = manualCount + autoCount
        if total == 0 { return "None" }
        return "\(total)"
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}

// MARK: - Hidden People sub-screen

struct HiddenPeopleList: View {
    @EnvironmentObject var manager: GalleryManager

    var body: some View {
        Group {
            let hidden = manager.hiddenPeopleTags
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
    @EnvironmentObject var manager: GalleryManager

    private var featured: PhotoFile? {
        manager.photos(forTag: person).first
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
                manager.unhidePerson(person.fullPath)
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
