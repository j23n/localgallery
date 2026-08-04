import XCTest
@testable import LocalGallery

/// `EnrichmentService.earliestFilesystemDate` is the AirDrop / chat-save guard:
/// when a file arrives via AirDrop the modification date is preserved
/// (matching the original capture time) but the creation date reflects when
/// iOS wrote the file to this volume — i.e. today. Picking the smaller of
/// the two keeps such photos from clustering on the import day.
final class EarliestFilesystemDateTests: XCTestCase {

    func testReturnsNilWhenBothDatesAreMissing() {
        XCTAssertNil(EnrichmentService.earliestFilesystemDate(creation: nil, modification: nil))
    }

    func testReturnsCreationWhenModificationIsMissing() {
        let creation = date(2024, 6, 1)
        XCTAssertEqual(
            EnrichmentService.earliestFilesystemDate(creation: creation, modification: nil),
            creation
        )
    }

    func testReturnsModificationWhenCreationIsMissing() {
        let modification = date(2024, 6, 1)
        XCTAssertEqual(
            EnrichmentService.earliestFilesystemDate(creation: nil, modification: modification),
            modification
        )
    }

    func testReturnsModificationWhenItIsEarlier() {
        // The AirDrop case: modDate is the original photo time (2023),
        // creationDate is when it landed on this volume (today).
        let originalCapture = date(2023, 8, 14, 10, 30)
        let arrivedToday = date(2024, 6, 1, 9, 0)
        let earliest = EnrichmentService.earliestFilesystemDate(
            creation: arrivedToday, modification: originalCapture
        )
        XCTAssertEqual(earliest, originalCapture)
    }

    func testReturnsCreationWhenItIsEarlier() {
        // The opposite: a file that was modified after creation (e.g. user
        // re-saved it). Still pick the earlier of the two.
        let creation = date(2024, 1, 1)
        let modification = date(2024, 6, 1)
        let earliest = EnrichmentService.earliestFilesystemDate(
            creation: creation, modification: modification
        )
        XCTAssertEqual(earliest, creation)
    }

    func testEqualDatesReturnTheSameValue() {
        let d = date(2024, 6, 1)
        XCTAssertEqual(EnrichmentService.earliestFilesystemDate(creation: d, modification: d), d)
    }
}
