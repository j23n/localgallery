import Foundation
import XCTest
@testable import LocalGallery

final class MergeGroupTests: XCTestCase {
    private func cluster(
        _ id: Int64, size: Int, name: String? = nil
    ) -> FaceService.Cluster {
        FaceService.Cluster(
            id: id,
            size: size,
            state: name == nil ? .unlabeled : .named,
            name: name,
            exemplars: []
        )
    }

    private func proposal(_ a: Int64, _ b: Int64, _ similarity: Double) -> FaceService.Proposal {
        FaceService.Proposal(a: a, b: b, similarity: similarity)
    }

    func testDisjointPairsStaySeparateGroups() {
        let clusters = [cluster(1, size: 4), cluster(2, size: 5), cluster(3, size: 4), cluster(4, size: 6)]
        let groups = MergeGroups.make(
            proposals: [proposal(1, 2, 0.95), proposal(3, 4, 0.8)],
            clusters: clusters
        )
        XCTAssertEqual(groups.map(\.clusterIDs), [[1, 2], [3, 4]])
        XCTAssertEqual(groups.map(\.similarity), [0.95, 0.8])
    }

    func testOverlappingPairsCollapseIntoOneGroup() {
        let clusters = [cluster(1, size: 4), cluster(2, size: 5), cluster(3, size: 6)]
        let groups = MergeGroups.make(
            proposals: [proposal(1, 2, 0.91), proposal(2, 3, 0.88)],
            clusters: clusters
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].clusterIDs, [1, 2, 3])
        XCTAssertEqual(groups[0].similarity, 0.91, "the row uses the strongest pair")
        XCTAssertEqual(groups[0].proposals.count, 2)
    }

    func testAProposalWhoseClusterIsMissingIsDropped() {
        let groups = MergeGroups.make(
            proposals: [proposal(1, 2, 0.9), proposal(2, 99, 0.99)],
            clusters: [cluster(1, size: 4), cluster(2, size: 5)]
        )
        XCTAssertEqual(groups.map(\.clusterIDs), [[1, 2]])
    }

    func testMergePlanForAPairMatchesMergeDirection() {
        let named = cluster(1, size: 2, name: "Ada")
        let huge = cluster(2, size: 200)
        let plan = MergePlan([named, huge])
        let direction = MergeDirection(named, huge)
        XCTAssertEqual(plan?.survivor.id, direction?.survivor.id)
        XCTAssertEqual(plan?.absorbed.map(\.id), [direction?.absorbed.id].compactMap { $0 })
        XCTAssertEqual(plan?.buttonLabel, direction?.buttonLabel)
    }

    func testMergePlanPicksTheNamedSurvivorAcrossThreeGroups() {
        let plan = MergePlan([
            cluster(1, size: 2, name: "Ada"),
            cluster(2, size: 200),
            cluster(3, size: 8, name: "Grace"),
        ])
        // Two named groups: the bigger named one survives; Ada is dropped.
        XCTAssertEqual(plan?.survivor.id, 3)
        XCTAssertEqual(plan?.droppedNames, ["Ada"])
        XCTAssertEqual(plan?.totalFaces, 210)
        XCTAssertTrue(plan?.confirmation.contains("“Ada” is dropped") ?? false, plan?.confirmation ?? "")
    }

    func testMergePlanNilWhenFewerThanTwoGroups() {
        XCTAssertNil(MergePlan([cluster(1, size: 4)]))
        XCTAssertNil(MergePlan([]))
    }

    func testNamingOneNewGroupSavesThatPerson() {
        let outcome = PeopleReviewNaming.outcome(
            selected: [cluster(1, size: 4)],
            typed: "Ada",
            named: []
        )
        XCTAssertEqual(outcome, .name(clusterID: 1, name: "Ada"))
        XCTAssertEqual(outcome?.buttonTitle, "Save Person")
        XCTAssertFalse(outcome?.needsConfirmation ?? true)
    }

    func testNamingOntoAnExistingPersonIsAMerge() {
        let outcome = PeopleReviewNaming.outcome(
            selected: [cluster(1, size: 3), cluster(2, size: 5)],
            typed: "ada",
            named: [cluster(9, size: 12, name: "Ada")]
        )
        XCTAssertEqual(outcome?.buttonTitle, "Merge Person")
        guard case .merge(let plan) = outcome else {
            return XCTFail("expected a merge into Ada")
        }
        XCTAssertEqual(plan.survivor.id, 9)
        XCTAssertEqual(Set(plan.absorbed.map(\.id)), [1, 2])
    }

    func testNamingSeveralNewGroupsMergesThenNames() {
        let outcome = PeopleReviewNaming.outcome(
            selected: [cluster(1, size: 3), cluster(2, size: 8)],
            typed: "Ada",
            named: []
        )
        guard case .mergeThenName(let plan, let name) = outcome else {
            return XCTFail("expected merge-then-name")
        }
        XCTAssertEqual(name, "Ada")
        XCTAssertEqual(plan.survivor.id, 2)
        XCTAssertEqual(plan.absorbed.map(\.id), [1])
        XCTAssertTrue(outcome?.confirmation.contains("named Ada") ?? false, outcome?.confirmation ?? "")
    }
}
