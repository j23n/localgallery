import Foundation
import XCTest
@testable import LocalGallery

/// Which of two face groups survives a merge.
///
/// The core is deliberately directionless about this, so the policy lives in
/// one place in the UI — and both entry points (the suggested-merge row and the
/// "Merge with…" picker) go through it, because the same pair merging
/// differently depending on where the user tapped would be indefensible.
final class MergeDirectionTests: XCTestCase {
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

    /// Naming is the human decision in this feature; a group nobody has looked
    /// at must never absorb one somebody named.
    func testANamedGroupSurvivesAnUnnamedOneWhateverTheSizes() {
        let named = cluster(1, size: 2, name: "Ada")
        let huge = cluster(2, size: 200)

        for pair in [(named, huge), (huge, named)] {
            let direction = MergeDirection(pair.0, pair.1)
            XCTAssertEqual(direction?.survivor.id, named.id)
            XCTAssertEqual(direction?.absorbed.id, huge.id)
            XCTAssertEqual(direction?.buttonLabel, "Merge into Ada")
        }
    }

    /// Between two named groups the bigger one wins: that is the smaller
    /// retraction, since fewer photos change what they claim.
    func testBetweenTwoNamedGroupsTheBiggerOneKeepsItsName() {
        let big = cluster(9, size: 30, name: "Ada")
        let small = cluster(3, size: 4, name: "Grace")

        let direction = try? XCTUnwrap(MergeDirection(small, big))
        XCTAssertEqual(direction?.survivor.id, big.id)
        XCTAssertEqual(direction?.droppedName, "Grace", "the user was not told whose name goes")
        XCTAssertTrue(direction?.confirmation.contains("“Grace” is dropped") ?? false,
                      "\(direction?.confirmation ?? "")")
    }

    func testBetweenTwoUnnamedGroupsTheBiggerOneSurvives() {
        let direction = MergeDirection(cluster(1, size: 3), cluster(2, size: 8))
        XCTAssertEqual(direction?.survivor.id, 2)
        XCTAssertEqual(direction?.buttonLabel, "Merge Groups")
        XCTAssertNil(direction?.droppedName)
    }

    /// A tie must not be decided by which order the list happened to be in —
    /// the same pair has to merge the same way from either screen.
    func testASizeTieIsBrokenDeterministicallyById() {
        let a = cluster(4, size: 5)
        let b = cluster(7, size: 5)

        XCTAssertEqual(MergeDirection(a, b)?.survivor.id, MergeDirection(b, a)?.survivor.id)
        XCTAssertEqual(MergeDirection(a, b)?.survivor.id, 4)
    }

    /// Two groups of one person named the same thing lose nothing, so the
    /// confirmation must not claim a retraction.
    func testMergingTwoGroupsOfOneNameRetractsNothing() {
        let direction = MergeDirection(
            cluster(1, size: 9, name: "Ada"), cluster(2, size: 3, name: "Ada")
        )
        XCTAssertNil(direction?.droppedName)
        XCTAssertEqual(direction?.survivor.id, 1)
        XCTAssertTrue(direction?.confirmation.contains("join Ada") ?? false,
                      "\(direction?.confirmation ?? "")")
    }

    /// The core refuses a self-merge, and a button that cannot work should not
    /// be drawn.
    func testAGroupCannotMergeWithItself() {
        XCTAssertNil(MergeDirection(cluster(5, size: 2), cluster(5, size: 2)))
    }

    /// An unnamed result writes nothing to disk, and the confirmation has to
    /// say so — otherwise every merge reads as a sidecar rewrite.
    func testAnUnnamedMergeSaysNothingIsWritten() {
        let direction = MergeDirection(cluster(1, size: 3), cluster(2, size: 8))
        XCTAssertTrue(direction?.confirmation.contains("still unnamed") ?? false)
        XCTAssertTrue(direction?.confirmation.contains("11 faces") ?? false,
                      "\(direction?.confirmation ?? "")")
    }
}
