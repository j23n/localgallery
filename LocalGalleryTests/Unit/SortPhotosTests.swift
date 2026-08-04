import XCTest
@testable import LocalGallery

/// The newest-first photo order, which is the grid.
///
/// The sort itself moved into the Rust core in Phase 4 (`gallery-index`), so
/// there is no longer a pure `sortPhotos` helper to call — the order is
/// observed through `CoreLibraryIndex.sortedPhotos` after a build. The
/// tiebreak and the Unicode edges are pinned by `IndexConformanceTests`
/// against `search_index.json`; what is here is the plain shape.
@MainActor
final class SortPhotosTests: XCTestCase {

    private func sorted(_ photos: [PhotoFile]) async -> [PhotoFile] {
        let index = CoreLibraryIndex()
        index.build(allPhotos: photos)
        await index.settle()
        return index.sortedPhotos
    }

    func testSortDescendingByDateTaken() async {
        let older = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/older.jpg"),
                                      dateTaken: date(2023, 1, 1))
        let newest = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/newest.jpg"),
                                       dateTaken: date(2025, 6, 1))
        let middle = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/middle.jpg"),
                                       dateTaken: date(2024, 1, 1))

        let result = await sorted([older, middle, newest])
        XCTAssertEqual(result.map(\.id), [newest.id, middle.id, older.id])
    }

    func testNilDatesSortAsTheOldest() async {
        let dated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/dated.jpg"),
                                      dateTaken: date(2024, 1, 1))
        let undated = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/undated.jpg"),
                                        dateTaken: nil)
        let result = await sorted([undated, dated])
        XCTAssertEqual(result.map(\.id), [dated.id, undated.id])
    }

    func testEmptyInputProducesEmptyOutput() async {
        let result = await sorted([])
        XCTAssertTrue(result.isEmpty)
    }

    func testAlreadySortedInputIsUnchanged() async {
        let a = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/a.jpg"), dateTaken: date(2025, 1, 1))
        let b = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/b.jpg"), dateTaken: date(2024, 1, 1))
        let c = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/c.jpg"), dateTaken: date(2023, 1, 1))
        let result = await sorted([a, b, c])
        XCTAssertEqual(result.map(\.id), [a.id, b.id, c.id])
    }

    /// The id table is built synchronously by `build`, *before* the core call
    /// lands — `photo(byID:)` is on the viewer's and the memory rail's critical
    /// path and must never be a frame behind `allPhotos`.
    func testPhotoLookupIsAvailableBeforeTheCoreBuildLands() async {
        let index = CoreLibraryIndex()
        let a = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/a.jpg"), dateTaken: date(2024, 1, 1))
        let b = PhotoFile.fixture(url: URL(fileURLWithPath: "/p/b.jpg"), dateTaken: date(2025, 1, 1))
        index.build(allPhotos: [a, b])
        XCTAssertEqual(index.photo(byID: a.id)?.id, a.id)
        XCTAssertEqual(index.photo(byID: b.id)?.id, b.id)
        await index.settle()
        XCTAssertEqual(index.sortedPhotos.map(\.id), [b.id, a.id])
    }
}
