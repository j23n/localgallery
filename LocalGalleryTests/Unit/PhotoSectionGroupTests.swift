import XCTest
@testable import LocalGallery

final class PhotoSectionGroupTests: XCTestCase {

    // MARK: - group(_:)

    func testEmptyInputProducesNoSections() {
        XCTAssertEqual(PhotoSection.group([]).count, 0)
    }

    func testSingleMonthBucketsTogether() {
        let photos = [
            PhotoFile.fixture(url: URL(fileURLWithPath: "/p/a.jpg"), dateTaken: date(2024, 3, 5)),
            PhotoFile.fixture(url: URL(fileURLWithPath: "/p/b.jpg"), dateTaken: date(2024, 3, 18)),
            PhotoFile.fixture(url: URL(fileURLWithPath: "/p/c.jpg"), dateTaken: date(2024, 3, 25)),
        ]
        let sections = PhotoSection.group(photos)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "2024-03")
        XCTAssertEqual(sections.first?.photos.count, 3)
    }

    func testSectionsAreSortedNewestFirst() {
        let older = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/older.jpg"),
                                       dateTaken: date(2023, 1, 10))
        let newer = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/newer.jpg"),
                                       dateTaken: date(2024, 6, 4))
        let sections = PhotoSection.group([older, newer])
        XCTAssertEqual(sections.map(\.id), ["2024-06", "2023-01"])
    }

    func testNilDateLandsInUnknownBucket() {
        let dated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/d.jpg"),
                                       dateTaken: date(2024, 3, 5))
        let undated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/u.jpg"),
                                         dateTaken: nil)
        let sections = PhotoSection.group([undated, dated])
        XCTAssertEqual(Set(sections.map(\.id)), ["2024-03", "unknown"])
        let unknownSection = sections.first { $0.id == "unknown" }
        XCTAssertEqual(unknownSection?.title, "Unknown Date")
        XCTAssertEqual(unknownSection?.photos.count, 1)
    }

    // MARK: - dateRange caching

    func testSectionDateRangeMatchesPhotoDates() {
        let dates = [date(2024, 3, 5), date(2024, 3, 18), date(2024, 3, 25)]
        let photos = dates.enumerated().map { idx, d in
            PhotoFile.fixture(url: URL(fileURLWithPath: "/p/\(idx).jpg"), dateTaken: d)
        }
        let section = PhotoSection.group(photos).first!
        XCTAssertEqual(section.dateRange?.lowerBound, dates.min())
        XCTAssertEqual(section.dateRange?.upperBound, dates.max())
    }

    func testUnknownSectionHasNoDateRange() {
        let undated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/u.jpg"),
                                         dateTaken: nil)
        let section = PhotoSection.group([undated]).first!
        XCTAssertNil(section.dateRange)
    }

    // MARK: - group(presorted:)

    func testPresortedVariantPreservesProvidedOrder() {
        let a = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/a.jpg"), dateTaken: date(2024, 3, 5))
        let b = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/b.jpg"), dateTaken: date(2024, 3, 18))
        let c = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/c.jpg"), dateTaken: date(2024, 3, 25))
        // Presorted descending by date — group(presorted:) does not re-sort.
        let sections = PhotoSection.group(presorted: [c, b, a])
        XCTAssertEqual(sections.first?.photos.map(\.id), [c.id, b.id, a.id])
    }
}
