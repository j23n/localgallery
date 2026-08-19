import SwiftUI

struct FolderBrowserView: View {
    @Environment(GalleryStore.self) private var store
    var folder: PhotoFolder? = nil
    /// Only the root tab should show the gear. Child browsers leave it off.
    var isRoot: Bool = true

    @State private var showSettings = false

    private var displayFolder: PhotoFolder? {
        if let folder {
            // Pushed screens hold a snapshot from navigation time; re-resolve
            // against the live tree so a rescan that dropped files updates
            // counts and photos instead of leaving a stale child on screen.
            return store.rootFolder?.folder(withID: folder.id)
        }
        return store.rootFolder
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if folder != nil {
                childBody
            } else {
                rootBody
            }
        }
        // Live name first; the NavigationLink snapshot covers a child whose
        // node was deleted mid-drill-in; "Folders" only at the root before
        // the bookmark resolves, so the large title does not flash "".
        .navigationTitle(displayFolder?.name ?? folder?.name ?? (isRoot ? "Folders" : ""))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar {
            // Always include the banner — it returns EmptyView when no
            // scan is running. The `if store.scanProgress != nil` used to
            // live here, but reading scanProgress in the parent body made
            // every progress tick re-evaluate FolderBrowserView and the
            // List of folder rows below it. Scoping the read to
            // ScanProgressBanner.body keeps the parent untouched.
            ToolbarItem(placement: .principal) {
                ScanProgressBanner()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if displayFolder?.subfolders.isEmpty == false {
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

    /// Root tab only. Unavailable takes the whole screen — the cached tree
    /// may still be in memory after an unlistable root, and showing it would
    /// look like the library was still there. The cold-launch spinner is
    /// `isScanning && displayFolder == nil` so a Reload Library pass does
    /// not hide a tree we already have.
    @ViewBuilder
    private var rootBody: some View {
        if store.libraryAvailability == .unavailable {
            unavailableState
        } else if store.isScanning && displayFolder == nil {
            ProgressView("Scanning folder…")
        } else if let folder = displayFolder {
            folderContent(folder)
        } else if store.libraryAvailability == .empty {
            emptyLibraryState
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var childBody: some View {
        // Unlistable root keeps `rootFolder` in memory so lookup would still
        // hit and show a ghost tree. The root tab already hid that; a pushed
        // child has to as well.
        if store.libraryAvailability == .unavailable {
            unavailableState
        } else if let folder = displayFolder {
            folderContent(folder)
        } else {
            ContentUnavailableView(
                "This folder is no longer available",
                systemImage: "folder"
            )
        }
    }

    private var emptyState: some View {
        LibraryEmptyState(icon: "folder", title: "No Folder Selected",
                          message: "Set a folder in Settings to get started.")
    }

    private var emptyLibraryState: some View {
        LibraryEmptyState.selectedFolderEmpty(icon: "folder", title: "No Photos")
    }

    private var unavailableState: some View {
        LibraryEmptyState.unavailable(icon: "folder") {
            Task { await store.rescan(kind: .light, silent: false) }
        }
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
                            folderID: folder.id
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
                                    folderID: subfolder.id
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
