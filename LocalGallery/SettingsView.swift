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

                Section("Info") {
                    LabeledContent("Photos", value: "\(manager.allPhotos.count)")
                    LabeledContent("Tags", value: "\(manager.allTags.count)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
}
