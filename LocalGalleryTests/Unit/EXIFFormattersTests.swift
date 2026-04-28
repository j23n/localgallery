import XCTest
import CoreGraphics
@testable import LocalGallery

final class EXIFFormattersTests: XCTestCase {

    // MARK: - Dimensions

    func testDimensionsPrefersExifOverRuntimeSize() {
        let result = EXIFFormatters.dimensions(
            exifWidth: 1920, exifHeight: 1080,
            runtimeSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(result, "1920 × 1080 px")
    }

    func testDimensionsFallsBackToRuntimeSize() {
        let result = EXIFFormatters.dimensions(
            exifWidth: nil, exifHeight: nil,
            runtimeSize: CGSize(width: 4032, height: 3024)
        )
        XCTAssertEqual(result, "4032 × 3024 px")
    }

    func testDimensionsReturnsNilWhenAllSourcesAreMissing() {
        XCTAssertNil(EXIFFormatters.dimensions(exifWidth: nil, exifHeight: nil, runtimeSize: nil))
    }

    func testDimensionsReturnsNilWhenOnlyOneExifAxisIsKnown() {
        XCTAssertNil(EXIFFormatters.dimensions(
            exifWidth: 1920, exifHeight: nil, runtimeSize: nil
        ))
    }

    // MARK: - Camera

    func testCameraReturnsMakeAndModelWhenBothPresent() {
        XCTAssertEqual(EXIFFormatters.camera(make: "Sony", model: "A7 IV"), "Sony A7 IV")
    }

    func testCameraCollapsesWhenModelAlreadyContainsMake() {
        XCTAssertEqual(
            EXIFFormatters.camera(make: "Apple", model: "Apple iPhone 15 Pro"),
            "Apple iPhone 15 Pro"
        )
    }

    func testCameraReturnsModelOnlyWhenMakeMissing() {
        XCTAssertEqual(EXIFFormatters.camera(make: nil, model: "iPhone 15"), "iPhone 15")
    }

    func testCameraReturnsMakeOnlyWhenModelMissing() {
        XCTAssertEqual(EXIFFormatters.camera(make: "Canon", model: nil), "Canon")
    }

    func testCameraReturnsNilWhenBothMissing() {
        XCTAssertNil(EXIFFormatters.camera(make: nil, model: nil))
    }

    // MARK: - Aperture

    func testAperturePrefixesWithFAndOneDecimal() {
        XCTAssertEqual(EXIFFormatters.aperture(2.8), "f/2.8")
        XCTAssertEqual(EXIFFormatters.aperture(1.4), "f/1.4")
    }

    func testApertureReturnsNilWhenMissing() {
        XCTAssertNil(EXIFFormatters.aperture(nil))
    }

    // MARK: - Shutter speed

    func testShutterSpeedFractionalUsesReciprocalNotation() {
        XCTAssertEqual(EXIFFormatters.shutterSpeed(1.0 / 250.0), "1/250s")
    }

    func testShutterSpeedAtOrAboveOneSecondUsesDecimalNotation() {
        XCTAssertEqual(EXIFFormatters.shutterSpeed(2.0), "2.0s")
        XCTAssertEqual(EXIFFormatters.shutterSpeed(1.0), "1.0s")
    }

    func testShutterSpeedReturnsNilForMissingValue() {
        XCTAssertNil(EXIFFormatters.shutterSpeed(nil))
    }

    func testShutterSpeedReturnsNilForNonPositiveValue() {
        XCTAssertNil(EXIFFormatters.shutterSpeed(0))
        XCTAssertNil(EXIFFormatters.shutterSpeed(-1))
    }

    // MARK: - File size

    func testFileSizeFormatsBytesIntoLocalisedString() {
        // ByteCountFormatter is locale-sensitive — assert a structural shape
        // (non-empty, contains a digit and a unit) rather than exact bytes.
        let small = EXIFFormatters.fileSize(512)
        XCTAssertFalse(small.isEmpty)

        let oneKB = EXIFFormatters.fileSize(1_024)
        XCTAssertFalse(oneKB.isEmpty)

        let oneMB = EXIFFormatters.fileSize(1_048_576)
        XCTAssertTrue(oneMB.localizedCaseInsensitiveContains("MB"))

        let oneGB = EXIFFormatters.fileSize(1_073_741_824)
        XCTAssertTrue(oneGB.localizedCaseInsensitiveContains("GB"))
    }
}
