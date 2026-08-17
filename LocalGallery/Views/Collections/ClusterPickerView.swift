import SwiftUI

/// "Merge with…": pick the other group.
///
/// Named groups first, then unlabeled ones biggest first — the same order the
/// review screen uses, and the order that matches what the user is usually
/// after here, which is "this is that person I already named".
///
/// Ignored groups are absent: the user said "not a person" about them, and
/// offering one as a merge target would be asking them to contradict a decision
/// they already made rather than to reverse it.
struct ClusterPickerView: View {
    let source: FaceService.Cluster
    let onPick: (MergeDirection) -> Void

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var candidates: [FaceService.Cluster] {
        let others = store.faces.allClusters.filter { $0.id != source.id && $0.state != .ignored }
        let named = others.filter { $0.state == .named }.sorted(by: FaceService.biggestFirst)
        let unlabeled = others.filter { $0.state != .named }.sorted(by: FaceService.biggestFirst)
        return named + unlabeled
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("There is no other group to merge with yet.")
                        .font(.footnote)
                        .foregroundStyle(Design.ink2)
                }
                ForEach(candidates) { candidate in
                    if let direction = MergeDirection(source, candidate) {
                        Button {
                            onPick(direction)
                            dismiss()
                        } label: {
                            row(candidate, direction: direction)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Merge With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ cluster: FaceService.Cluster, direction: MergeDirection) -> some View {
        HStack(spacing: 10) {
            ForEach(cluster.exemplars.prefix(3)) { face in
                PersonThumbnailView(
                    url: face.url,
                    region: face.region,
                    size: 44,
                    cornerRadius: 8
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.name ?? "Unnamed group")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Design.ink)
                // The outcome, per row: which group survives depends on this
                // pair, and finding that out only after tapping would make the
                // list a guess.
                Text(direction.buttonLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink2)
            }
            Spacer(minLength: 0)
            Text(cluster.size == 1 ? "1 face" : "\(cluster.size) faces")
                .font(.system(size: 12))
                .foregroundStyle(Design.ink2)
        }
        .padding(.vertical, 2)
    }
}
