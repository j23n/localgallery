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
                        Label("Choose Folder", systemImage: "folder.badge.plus")
                    }

                    if let url = manager.resolveBookmark() {
                        LabeledContent("Current Folder") {
                            Text(url.lastPathComponent)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await manager.rescan() }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
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
