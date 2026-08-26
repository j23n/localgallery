import Foundation

/// A connected set of face groups the core thinks are the same person.
///
/// The engine proposes **pairs**. Overlapping pairs (A–B and B–C) are one
/// suggestion here, so the review row can show every face that would be
/// merged and the detail screen can let the user pick a subset.
struct MergeGroup: Equatable, Hashable, Identifiable {
    /// Sorted unique cluster ids. Stable identity for navigation.
    var clusterIDs: [Int64]
    /// Strongest pair similarity in the group — drives the "likely" wording.
    var similarity: Double
    /// The pairwise proposals that produced this group. Dismissing the
    /// suggestion forgets all of them.
    var proposals: [FaceService.Proposal]

    var id: String { clusterIDs.map(String.init).joined(separator: "-") }

    var clusterCount: Int { clusterIDs.count }
}

enum MergeGroups {
    /// Collapse pairwise proposals into connected groups, strongest first.
    ///
    /// A proposal whose clusters are missing from `clusters` is dropped —
    /// the two reads come from one crossing, so that means the cluster is
    /// ignored or otherwise not on offer.
    static func make(
        proposals: [FaceService.Proposal],
        clusters: [FaceService.Cluster]
    ) -> [MergeGroup] {
        let known = Set(clusters.map(\.id))
        let live = proposals.filter { known.contains($0.a) && known.contains($0.b) }
        guard !live.isEmpty else { return [] }

        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var x = x
            while parent[x, default: x] != x {
                let p = parent[x, default: x]
                parent[x] = parent[p, default: p]
                x = parent[x, default: x]
            }
            return x
        }
        func union(_ a: Int64, _ b: Int64) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for proposal in live {
            union(proposal.a, proposal.b)
        }

        var buckets: [Int64: [FaceService.Proposal]] = [:]
        for proposal in live {
            buckets[find(proposal.a), default: []].append(proposal)
        }

        return buckets.values.map { groupProposals in
            var ids = Set<Int64>()
            var best = 0.0
            for proposal in groupProposals {
                ids.insert(proposal.a)
                ids.insert(proposal.b)
                best = max(best, proposal.similarity)
            }
            return MergeGroup(
                clusterIDs: ids.sorted(),
                similarity: best,
                proposals: groupProposals
            )
        }
        .sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.clusterIDs.lexicographicallyPrecedes($1.clusterIDs)
        }
    }
}

/// How a merge of two *or more* groups will land: which id survives, whose
/// names are retracted, and the sentence the confirmation alert shows.
///
/// Pairwise policy is still `MergeDirection` — this just folds it over the
/// selection so a three-group suggestion does not invent a second rule.
struct MergePlan: Equatable {
    let survivor: FaceService.Cluster
    let absorbed: [FaceService.Cluster]

    /// Nil when there are fewer than two groups — nothing to merge.
    init?(_ clusters: [FaceService.Cluster]) {
        guard clusters.count >= 2 else { return nil }
        let ranked = clusters.sorted { a, b in
            guard let direction = MergeDirection(a, b) else { return a.id < b.id }
            return direction.survivor.id == a.id
        }
        survivor = ranked[0]
        absorbed = Array(ranked.dropFirst())
    }

    var droppedNames: [String] {
        absorbed.compactMap(\.name).filter { $0 != survivor.name }
    }

    var totalFaces: Int {
        survivor.size + absorbed.reduce(0) { $0 + $1.size }
    }

    var buttonLabel: String {
        guard let name = survivor.name else { return "Merge Groups" }
        return "Merge into \(name)"
    }

    var confirmation: String {
        let faces = totalFaces
        if let kept = survivor.name, !droppedNames.isEmpty {
            let listed = droppedNames.map { "“\($0)”" }.joined(separator: " and ")
            let verb = droppedNames.count == 1 ? "is" : "are"
            return "\(listed) \(verb) dropped and those photos are tagged \(kept) instead. One group of \(faces) faces."
        }
        if let kept = survivor.name {
            let joining = absorbed.reduce(0) { $0 + $1.size }
            let joiningLabel = joining == 1 ? "1 face" : "\(joining) faces"
            return "\(joiningLabel) join \(kept), and their photos gain the tag. One group of \(faces) faces."
        }
        return "One group of \(faces) faces, still unnamed. Nothing is written to a sidecar until you name it."
    }
}

/// What naming the current New People selection will do: name one group,
/// fold the selection into someone already named, or merge the selection
/// first and then name the survivor.
enum PeopleReviewNaming {
    enum Outcome: Equatable {
        case name(clusterID: Int64, name: String)
        case merge(MergePlan)
        case mergeThenName(MergePlan, name: String)

        var needsConfirmation: Bool {
            switch self {
            case .name: return false
            case .merge, .mergeThenName: return true
            }
        }

        var buttonTitle: String {
            switch self {
            case .name, .mergeThenName: return "Save Person"
            case .merge: return "Merge Person"
            }
        }

        var confirmation: String {
            switch self {
            case .name(_, let name):
                return "These photos are tagged \(name)."
            case .merge(let plan):
                return plan.confirmation
            case .mergeThenName(let plan, let name):
                return "One group of \(plan.totalFaces) faces, named \(name)."
            }
        }
    }

    static func outcome(
        selected: [FaceService.Cluster],
        typed: String,
        named: [FaceService.Cluster]
    ) -> Outcome? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selected.isEmpty else { return nil }

        if let existing = named.first(where: {
            $0.name?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return MergePlan(selected + [existing]).map { .merge($0) }
        }
        if selected.count == 1 {
            return .name(clusterID: selected[0].id, name: name)
        }
        return MergePlan(selected).map { .mergeThenName($0, name: name) }
    }
}
