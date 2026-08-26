import SwiftUI

/// Destination picker for an on-disk move. Walks the live library tree
/// (the same folders the Folders tab shows) and can create a subdirectory.
/// Confirming "Move Here" is what commits the move.
struct FolderMovePicker: View {
    let photos: [PhotoFile]
    var onMove: (PhotoFolder) -> Void

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let root = store.rootFolder {
                FolderMoveList(folder: root, photos: photos) { dest in
                    onMove(dest)
                    dismiss()
                }
            } else {
                ContentUnavailableView(
                    "No Folder Selected",
                    systemImage: "folder",
                    description: Text("Set a library folder in Settings first.")
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct FolderMoveList: View {
    let folder: PhotoFolder
    let photos: [PhotoFile]
    var onMove: (PhotoFolder) -> Void

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDest: PhotoFolder?

    /// Re-resolve against the live tree so a just-created subfolder appears.
    private var live: PhotoFolder {
        store.rootFolder?.folder(withID: folder.id) ?? folder
    }

    private var alreadyHere: Bool {
        photos.allSatisfy { photo in
            !GalleryStore.pathKeys(for: photo.url.deletingLastPathComponent())
                .isDisjoint(with: GalleryStore.pathKeys(for: live.url))
        }
    }

    var body: some View {
        List {
            let subs = store.sortFolders(live.subfolders)
            if !subs.isEmpty {
                Section("Subfolders") {
                    ForEach(subs) { sub in
                        NavigationLink {
                            FolderMoveList(folder: sub, photos: photos, onMove: onMove)
                        } label: {
                            folderRow(sub)
                        }
                    }
                }
            } else {
                Section {
                    Text("No subfolders")
                        .foregroundStyle(Design.ink3)
                }
            }
        }
        .background(Design.bg)
        .navigationTitle(live.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Move Here") {
                    pendingDest = live
                }
                .fontWeight(.semibold)
                .disabled(alreadyHere || photos.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        }
        .alert(PhotoMovePrompt.title(for: photos), isPresented: pendingDestBinding) {
            Button("Cancel", role: .cancel) { pendingDest = nil }
            Button("Move") {
                if let dest = pendingDest {
                    pendingDest = nil
                    onMove(dest)
                }
            }
        } message: {
            if let dest = pendingDest {
                Text(PhotoMovePrompt.message(for: photos, destination: dest))
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                _ = store.createFolder(named: newFolderName, in: live)
                newFolderName = ""
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Created inside “\(live.name)”.")
        }
    }

    private var pendingDestBinding: Binding<Bool> {
        Binding(
            get: { pendingDest != nil },
            set: { if !$0 { pendingDest = nil } }
        )
    }

    private func folderRow(_ folder: PhotoFolder) -> some View {
        HStack(spacing: 14) {
            if let coverURL = folder.coverPhotoURL {
                ThumbnailView(url: coverURL, size: 56, cornerRadius: 8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.title3)
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
        .padding(.vertical, 2)
    }
}
