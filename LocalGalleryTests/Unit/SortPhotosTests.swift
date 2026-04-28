import XCTest
@testable import LocalGallery

/// `SearchIndex.sortPhotos` is the single source of truth for the
/// newest-first photo order. Test it directly so we don't have to spin up a
/// `GalleryStore` for a stateless helper.
@MainActor
final class SortPhotosTests: XCTestCase {

    func testSortDescendingByDateTaken() {
        let index = SearchIndex()
        let older = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/older.jpg"),
                                       dateTaken: date(2023, 1, 1))
        let newest = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/newest.jpg"),
                                        dateTaken: date(2025, 6, 1))
        let middle = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/middle.jpg"),
                                        dateTaken: date(2024, 1, 1))

        let sorted = index.sortPhotos([older, middle, newest])
        XCTAssertEqual(sorted.map(\.id), [newest.id, middle.id, older.id])
    }

    func testNilDatesSortAsTheOldest() {
        let index = SearchIndex()
        let dated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/dated.jpg"),
                                       dateTaken: date(2024, 1, 1))
        let undated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/undated.jpg"),
                                         dateTaken: nil)
        let sorted = index.sortPhotos([undated, dated])
        XCTAssertEqual(sorted.map(\.id), [dated.id, undated.id])
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(SearchIndex().sortPhotos([]).isEmpty)
    }

    func testAlreadySortedInputIsUnchanged() {
        let index = SearchIndex()
        let a = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/a.jpg"), dateTaken: date(2025, 1, 1))
        let b = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/b.jpg"), dateTaken: date(2024, 1, 1))
        let c = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/c.jpg"), dateTaken: date(2023, 1, 1))
        let sorted = index.sortPhotos([a, b, c])
        XCTAssertEqual(sorted.map(\.id), [a.id, b.id, c.id])
    }

    func testBuildPopulatesSortedPhotosAndPhotoByID() {
        let index = SearchIndex()
        let a = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/a.jpg"), dateTaken: date(2024, 1, 1))
        let b = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/b.jpg"), dateTaken: date(2025, 1, 1))
        index.build(allPhotos: [a, b])
        XCTAssertEqual(index.sortedPhotos.map(\.id), [b.id, a.id])
        XCTAssertEqual(index.photo(byID: a.id)?.id, a.id)
        XCTAssertEqual(index.photo(byID: b.id)?.id, b.id)
    }
}
