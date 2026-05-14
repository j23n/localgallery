import SwiftUI

struct FolderBrowserView: View {
    @Environment(GalleryStore.self) private var store
    var folder: PhotoFolder? = nil
    /// Only the root tab should show the gear. Child browsers leave it off.
    var isRoot: Bool = true

    @State private var showSettings = false

    private var displayFolder: PhotoFolder? {
        folder ?? store.rootFolder
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.isScanning {
                ProgressView("Scanning folder…")
            } else if let folder = displayFolder {
                folderContent(folder)
            } else {
                emptyState
            }
        }
        // Stable placeholder while the bookmark resolves on cold launch —
        // without it the large title flashes from "" to the folder name on
        // first render. Pushed children always have a folder by construction
        // so the fallback only applies at the root.
        .navigationTitle(displayFolder?.name ?? (isRoot ? "Folders" : ""))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar {
            if store.scanProgress != nil {
                ToolbarItem(placement: .principal) {
                    ScanProgressBanner()
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if displayFolder != nil && !(displayFolder?.subfolders.isEmpty ?? true) {
                    Menu {
                        Picker("Sort Folders", selection: $store.folderSortOrder) {
                            ForEach(FolderSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                if isRoot {
                    SettingsToolbarButton(isPresented: $showSettings)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        let sortedSubfolders = store.sortFolders(folder.subfolders)
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
                                FolderBrowserView(folder: subfolder, isRoot: false)
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
        .softTopScrollEdge()
        .refreshable {
            await store.rescan(kind: .light)
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
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
