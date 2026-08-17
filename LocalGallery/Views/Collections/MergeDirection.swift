import Foundation

/// Which of two face groups survives a merge, and what to tell the user about
/// it.
///
/// The core's `merge(into:from:)` is directional and deliberately carries no
/// policy: "which one should win" is a presentation question. It is answered
/// here, once, because both entry points — the suggested-merge row and the
/// "Merge with…" picker — have to answer it the same way or the same pair of
/// groups would merge differently depending on where the user tapped.
///
/// The rule, in order:
///
/// 1. A **named** group survives an unnamed one. Naming is the human decision
///    in this feature; nothing the user typed should be dropped in favour of a
///    group nobody has looked at.
/// 2. Between two named groups, the one with more faces survives, and
///    `droppedName` says whose name is going. That is the smaller retraction:
///    fewer photos change what they claim.
/// 3. Between two unnamed groups, the larger survives, for the same reason.
///
/// Size ties break on the lower id so the answer does not depend on which order
/// the list happened to be in.
struct MergeDirection: Equatable {
    /// The group that keeps its id, its name and everything merged into it.
    let survivor: FaceService.Cluster
    /// The group that disappears.
    let absorbed: FaceService.Cluster

    init(survivor: FaceService.Cluster, absorbed: FaceService.Cluster) {
        self.survivor = survivor
        self.absorbed = absorbed
    }

    /// Nil when the two are the same group — the core refuses that, and a
    /// button that cannot work should not be drawn.
    init?(_ a: FaceService.Cluster, _ b: FaceService.Cluster) {
        guard a.id != b.id else { return nil }
        switch (a.name, b.name) {
        case (.some, .none):
            self.init(survivor: a, absorbed: b)
        case (.none, .some):
            self.init(survivor: b, absorbed: a)
        default:
            // Both named or neither: size decides, id breaks the tie.
            if (a.size, b.id) > (b.size, a.id) {
                self.init(survivor: a, absorbed: b)
            } else {
                self.init(survivor: b, absorbed: a)
            }
        }
    }

    /// The name this merge takes back, when there is one. Only a *second*,
    /// different name is dropped: two groups of one person named the same thing
    /// lose nothing, and an unnamed group has nothing to lose.
    var droppedName: String? {
        guard let absorbed = absorbed.name, absorbed != survivor.name else { return nil }
        return absorbed
    }

    /// Always names the outcome, so the button says what will exist afterwards
    /// rather than what is being done to what.
    var buttonLabel: String {
        guard let name = survivor.name else { return "Merge Groups" }
        return "Merge into \(name)"
    }

    /// The sentence under the button. Says the retraction out loud when there
    /// is one — a merge that silently un-names somebody is the failure this
    /// whole feature has to avoid.
    var confirmation: String {
        let faces = survivor.size + absorbed.size
        if let dropped = droppedName, let kept = survivor.name {
            return "“\(dropped)” is dropped and those photos are tagged \(kept) instead. One group of \(faces) faces."
        }
        if let kept = survivor.name {
            return "\(absorbed.size == 1 ? "1 face" : "\(absorbed.size) faces") join \(kept), and their photos gain the tag. One group of \(faces) faces."
        }
        return "One group of \(faces) faces, still unnamed. Nothing is written to a sidecar until you name it."
    }
}
