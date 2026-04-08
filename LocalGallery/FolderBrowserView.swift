import SwiftUI

struct FolderBrowserView: View {
    @EnvironmentObject var manager: GalleryManager
    var folder: PhotoFolder? = nil

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
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(Design.accentColor.opacity(0.7))
            VStack(spacing: 8) {
                Text("No Folder Selected")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Set a folder in Settings to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
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
        .refreshable {
            await manager.rescan()
        }
    }

    private func folderRow(_ folder: PhotoFolder) -> some View {
        HStack(spacing: 14) {
            if let coverURL = folder.coverPhotoURL {
                ThumbnailView(url: coverURL, size: 72, cornerRadius: 8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(folder.totalPhotoCount) photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
