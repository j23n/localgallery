import SwiftUI

struct FolderBrowserView: View {
    @EnvironmentObject var manager: GalleryManager
    var folder: PhotoFolder? = nil
    @State private var showPicker = false

    private var displayFolder: PhotoFolder? {
        folder ?? manager.rootFolder
    }

    var body: some View {
        Group {
            if manager.isScanning {
                ProgressView("Scanning folder…")
            } else if let folder = displayFolder {
                folderContent(folder)
            } else {
                emptyState
            }
        }
        .navigationTitle(displayFolder?.name ?? "Folders")
        .toolbar {
            if self.folder == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            if displayFolder != nil && !(displayFolder?.subfolders.isEmpty ?? true) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort Folders", selection: $manager.folderSortOrder) {
                            ForEach(FolderSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { pickerURL in
                // Start security-scoped access BEFORE creating bookmark —
                // the scope token must be active for it to be embedded in the bookmark data.
                _ = pickerURL.startAccessingSecurityScopedResource()
                manager.saveBookmark(for: pickerURL)
                pickerURL.stopAccessingSecurityScopedResource()

                // Now resolve the bookmark and use the resolved URL
                if let resolvedURL = manager.resolveBookmark() {
                    Task {
                        manager.startAccessingFolder(resolvedURL)
                        await manager.scanFolder(at: resolvedURL)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Folder Selected")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Choose a folder to browse your photos.")
                .foregroundStyle(.secondary)
            Button("Choose Folder") {
                showPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private func folderContent(_ folder: PhotoFolder) -> some View {
        let sortedSubfolders = manager.sortFolders(folder.subfolders)
        List {
            if !folder.photos.isEmpty {
                Section("Photos") {
                    NavigationLink {
                        FolderGridView(
                            title: folder.name,
                            photos: folder.photos
                        )
                    } label: {
                        Label("\(folder.photos.count) photos in this folder", systemImage: "photo.on.rectangle")
                    }
                }
            }

            if !sortedSubfolders.isEmpty {
                Section("Subfolders") {
                    ForEach(sortedSubfolders) { subfolder in
                        NavigationLink {
                            if subfolder.subfolders.isEmpty && !subfolder.photos.isEmpty {
                                FolderGridView(
                                    title: subfolder.name,
                                    photos: subfolder.photos
                                )
                            } else {
                                FolderBrowserView(folder: subfolder)
                            }
                        } label: {
                            folderRow(subfolder)
                        }
                    }
                }
            }

            if folder.photos.isEmpty && folder.subfolders.isEmpty {
                ContentUnavailableView(
                    "No Photos Found",
                    systemImage: "photo",
                    description: Text("This folder doesn't contain any images.")
                )
            }
        }
    }

    private func folderRow(_ folder: PhotoFolder) -> some View {
        HStack(spacing: 12) {
            if let coverURL = folder.coverPhotoURL {
                ThumbnailView(url: coverURL, size: 56)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(folder.totalPhotoCount) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
