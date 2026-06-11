import XCTest
@testable import LocalGallery

/// Cluster identity, the shared `finalize` post-processing (photo cap +
/// subtitle), and the time-window dedup that every generator funnels through.
final class MemoryEngineSelectionTests: XCTestCase {

    private func memory(
        id: String = "trip-2023-5-1",
        photoIDs: [UUID],
        coverPhotoID: UUID? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) -> Memory {
        Memory(
            id: id, type: .trip, title: "A trip", subtitle: nil,
            photoIDs: photoIDs,
            coverPhotoID: coverPhotoID ?? photoIDs[photoIDs.count / 2],
            dateRange: dateRange, score: 20,
            yearsAgo: nil, personName: nil
        )
    }

    // MARK: clusterKey

    func testSubtripsCollapseToTheirParentTripCluster() {
        XCTAssertEqual(MemoryEngine.clusterKey(for: "subtrip-2023-5-1-italy-tuscany"),
                       "trip-2023-5-1")
        XCTAssertEqual(MemoryEngine.clusterKey(for: "trip-2023-5-1"), "trip-2023-5-1")
        // Every other id is its own singleton cluster.
        XCTAssertEqual(MemoryEngine.clusterKey(for: "onThisDay-2024-06-11"), "onThisDay-2024-06-11")
        XCTAssertEqual(MemoryEngine.clusterKey(for: "birthday-People/Anna"), "birthday-People/Anna")
    }

    // MARK: finalize

    func testFinalizeCapsPhotosAndRepointsOrphanedCover() {
        let ids = (0..<150).map { _ in UUID() }
        // Even-stride sampling keeps even indices; an odd-index cover would
        // be orphaned without the re-point.
        let input = memory(photoIDs: ids, coverPhotoID: ids[101])

        let out = MemoryEngine.finalize([input])
        XCTAssertEqual(out.count, 1)
        guard let capped = out.first else { return }
        XCTAssertEqual(capped.photoIDs.count, 75)
        // Every sampled id comes from the original set, order preserved.
        XCTAssertTrue(Set(capped.photoIDs).isSubset(of: Set(ids)))
        // The cover must be part of the memory's own photo set — in-app
        // `photos(for:)` resolves only `photoIDs`.
        XCTAssertTrue(capped.photoIDs.contains(capped.coverPhotoID))
        // Subtitle reflects the *capped* count (what the user actually sees).
        XCTAssertEqual(capped.subtitle, "75 photos")
    }

    func testFinalizeLeavesSmallMemoriesUncappedButSubtitled() {
        let ids = (0..<5).map { _ in UUID() }
        let input = memory(photoIDs: ids, coverPhotoID: ids[2])
        let out = MemoryEngine.finalize([input]).first
        XCTAssertEqual(out?.photoIDs, ids)
        XCTAssertEqual(out?.coverPhotoID, ids[2])
        XCTAssertEqual(out?.subtitle, "5 photos")
    }

    func testFinalizeSubtitleIncludesDateRangeWhenPresent() {
        let ids = (0..<3).map { _ in UUID() }
        let input = memory(photoIDs: ids, dateRange: date(2023, 5, 1)...date(2023, 5, 4))
        let subtitle = MemoryEngine.finalize([input]).first?.subtitle
        // Date formatting is locale-templated; pin only the stable suffix.
        XCTAssertTrue(subtitle?.hasSuffix("3 photos") == true, "got \(subtitle ?? "nil")")
        XCTAssertNotEqual(subtitle, "3 photos", "range should prefix the count")
    }

    // MARK: subtitle / dedup primitives

    func testSubtitleWithCountSingularPlural() {
        XCTAssertEqual(MemoryEngine.subtitleWithCount(dateRange: nil, count: 1), "1 photo")
        XCTAssertEqual(MemoryEngine.subtitleWithCount(dateRange: nil, count: 2), "2 photos")
    }

    func testDedupByTimeWindowKeepsFirstOfEachWindow() {
        let base = date(2023, 5, 1, 10, 0)
        let entries: [(PhotoFile, Date)] = [0.0, 30.0, 90.0].enumerated().map { i, offset in
            let d = base.addingTimeInterval(offset)
            return (PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/d-\(i).jpg"), dateTaken: d), d)
        }
        let kept = MemoryEngine.dedupByTimeWindow(entries)
        // 30s shot falls inside the 60s window of the first; 90s starts anew.
        XCTAssertEqual(kept.map(\.1), [base, base.addingTimeInterval(90)])
    }
}
