import SwiftUI

/// Force-overwrite passes, one step behind Settings. Each row confirms
/// before it resets that phase's skip and walks every photo.
struct DropAndRescanView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case tagging
        case faces
        case places

        var id: Self { self }

        var title: String {
            switch self {
            case .tagging: return "Redo tagging on every photo?"
            case .faces: return "Redo face detection on every photo?"
            case .places: return "Redo place names on every photo?"
            }
        }

        var message: String {
            switch self {
            case .tagging:
                return "Objects, scenes, and landmarks already written to sidecars will be replaced."
            case .faces:
                return "Every photo is re-detected. People names already written stay until the new pass replaces them."
            case .places:
                return "Places tags already written to sidecars will be replaced."
            }
        }

        var confirm: String {
            switch self {
            case .tagging: return "Tag Library"
            case .faces: return "Face Scan"
            case .places: return "Reverse Geocode"
            }
        }

        var phases: Set<LibraryAnalysis.Phase> {
            switch self {
            case .tagging: return [.tagging]
            case .faces: return [.faces]
            case .places: return [.places]
            }
        }
    }

    var body: some View {
        let analysis = store.analysis
        let busy = store.isScanning || analysis.isRunning || store.allPhotos.isEmpty
        List {
            Section {
                Button {
                    pending = .tagging
                } label: {
                    Label("Tag Library", systemImage: "tag")
                }
                .disabled(busy || !store.tagging.isAvailable)

                Button {
                    pending = .faces
                } label: {
                    Label("Face Scan", systemImage: "person.crop.rectangle")
                }
                .disabled(busy || !store.faces.isAvailable)

                Button {
                    pending = .places
                } label: {
                    Label("Reverse Geocode", systemImage: "mappin.and.ellipse")
                }
                .disabled(busy)
            } footer: {
                Text("Each pass runs on every photo and overwrites what is already in the sidecars. Scan Photos on the previous screen only fills in gaps.")
            }
        }
        .tint(.primary)
        .navigationTitle("Drop and Rescan")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { action in
            Button("Cancel", role: .cancel) { pending = nil }
            Button(action.confirm, role: .destructive) {
                let phases = action.phases
                pending = nil
                dismiss()
                Task { await store.analysis.start(phases: phases, force: true) }
            }
        } message: { action in
            Text(action.message)
        }
    }
}
