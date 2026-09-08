import Foundation
import XCTest
@testable import LocalGallery

final class PhotoInfoFormattingTests: XCTestCase {

    func testFilesAppURLRewritesFileScheme() throws {
        let file = URL(fileURLWithPath: "/var/mobile/Media/IMG_1.HEIC")
        let files = try XCTUnwrap(PhotoInfoFormatting.filesAppURL(for: file))
        XCTAssertEqual(files.scheme, "shareddocuments")
        XCTAssertEqual(files.path, file.standardizedFileURL.path)
    }

    func testFilesAppURLPreservesPathWithSpaces() throws {
        let file = URL(fileURLWithPath: "/var/mobile/Media/My Photos/IMG 2.jpg")
        let files = try XCTUnwrap(PhotoInfoFormatting.filesAppURL(for: file))
        XCTAssertEqual(files.scheme, "shareddocuments")
        XCTAssertEqual(files.path, file.standardizedFileURL.path)
    }

    func testFileFormatUppercasesExtension() {
        XCTAssertEqual(PhotoInfoFormatting.fileFormat(filename: "IMG_4821.HEIC"), "HEIC")
        XCTAssertEqual(PhotoInfoFormatting.fileFormat(filename: "clip.mov"), "MOV")
        XCTAssertNil(PhotoInfoFormatting.fileFormat(filename: "noext"))
    }

    func testRelativeTimestampUsesFullUnits() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let twoHoursEarlier = now.addingTimeInterval(-2 * 60 * 60)
        let raw = ISO8601DateFormatter().string(from: twoHoursEarlier)
        let text = PhotoInfoFormatting.relativeTimestamp(raw, now: now)
        XCTAssertNotEqual(text, raw)
        XCTAssertFalse(text.contains("T"))
    }

    func testRelativeTimestampFallsBackToRawWhenUnparseable() {
        XCTAssertEqual(PhotoInfoFormatting.relativeTimestamp("buffalo_sc-2026.1"), "buffalo_sc-2026.1")
    }

    func testFacesSummary() {
        XCTAssertNil(PhotoInfoFormatting.facesSummary(named: 0, unnamed: 0, scanned: false))
        XCTAssertEqual(PhotoInfoFormatting.facesSummary(named: 0, unnamed: 0, scanned: true), "no box")
        XCTAssertEqual(PhotoInfoFormatting.facesSummary(named: 1, unnamed: 0, scanned: true), "1 named")
        XCTAssertEqual(PhotoInfoFormatting.facesSummary(named: 2, unnamed: 1, scanned: true), "2 named · 1 unnamed")
        XCTAssertEqual(PhotoInfoFormatting.facesSummary(named: 0, unnamed: 1, scanned: true), "1 unnamed")
    }

    func testSidecarAndDateSourceLabels() {
        XCTAssertEqual(PhotoInfoFormatting.sidecarOnDiskLabel(false), "absent")
        XCTAssertEqual(PhotoInfoFormatting.sidecarOnDiskLabel(true), "on disk")
        XCTAssertNil(PhotoInfoFormatting.sidecarCacheLabel(.absent))
        XCTAssertEqual(PhotoInfoFormatting.sidecarCacheLabel(.cached(.init())), "cache present")
        XCTAssertEqual(PhotoInfoFormatting.dateSourceLabel(hasDate: true, fromMetadata: true), "from EXIF")
        XCTAssertEqual(PhotoInfoFormatting.dateSourceLabel(hasDate: true, fromMetadata: false), "from filesystem")
        XCTAssertNil(PhotoInfoFormatting.dateSourceLabel(hasDate: false, fromMetadata: false))
    }
}
