import XCTest
@testable import LocalGallery

@MainActor
final class FacePhotoLookupTests: XCTestCase {
    private var harness: TestGalleryStore.Harness!

    override func setUp() {
        super.setUp()
        harness = TestGalleryStore.make()
    }

    override func tearDown() {
        harness.teardown()
        harness = nil
        super.tearDown()
    }

    func testPhotoAtFindsALibraryPhotoThroughTheScannerURL() {
        let path = "/tmp/library/holiday.jpg"
        let photo = PhotoFile.fixture(url: CoreScanner.fileURL(path))
        harness.store.apply(.scanResult(photos: [photo], root: nil, persistCache: false))

        XCTAssertEqual(harness.store.photo(at: CoreScanner.fileURL(path))?.id, photo.id)
        XCTAssertEqual(harness.store.photo(at: URL(fileURLWithPath: path))?.id, photo.id)
    }

    func testPhotoForFaceStillOpensWhenTheIndexMisses() {
        let url = CoreScanner.fileURL("/tmp/library/missing.jpg")
        let face = FaceService.Face(
            url: url,
            region: FaceRegion(name: nil, centerX: 0.5, centerY: 0.5, width: 0.1, height: 0.1),
            quality: 1,
            key: "missing:0"
        )
        let standIn = harness.store.photo(forFace: face)
        XCTAssertEqual(standIn.url.standardized.path, url.standardized.path)
        XCTAssertEqual(standIn.id, PhotoFile.stableID(for: url))
    }

    func testActivityLookupUsesTheLibraryPhotoNotAZeroByteStub() {
        let path = "/tmp/library/café.jpg"
        let photo = PhotoFile.fixture(
            url: CoreScanner.fileURL(path),
            filename: "café.jpg",
            fileSize: 4096,
            tags: ["Objects/Cup"]
        )
        harness.store.apply(.scanResult(photos: [photo], root: nil, persistCache: false))

        let activityURL = URL(fileURLWithPath: path).standardizedFileURL
        let activityID = PhotoFile.stableID(for: activityURL)
        let found = harness.store.photo(forActivity: activityURL, photoID: activityID)
        XCTAssertEqual(found?.id, photo.id)
        XCTAssertEqual(found?.fileSize, 4096)
        XCTAssertEqual(found?.hierarchicalTags.map(\.fullPath), ["Objects/Cup"])
        XCTAssertNotEqual(found?.fileSize, 0, "Open photo must not fall back to the 0 KB stub")
    }

    func testApplyParsedSidecarsUnionsAPeopleTagTheScanWillNotReread() throws {
        let dir = harness.tempDir.appending("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appending("ada.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data("jpeg".utf8)))
        let photo = PhotoFile.fixture(
            url: CoreScanner.fileURL(image.path),
            filename: "ada.jpg",
            fileSize: 4,
            tags: ["Objects/Poster"]
        )
        harness.store.apply(.scanResult(photos: [photo], root: nil, persistCache: false))

        let xmp = """
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
         <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
          <rdf:Description rdf:about=''
           xmlns:digiKam='http://www.digikam.org/ns/1.0/'>
           <digiKam:TagsList><rdf:Seq>
            <rdf:li>People/Ada</rdf:li>
            <rdf:li>Objects/Poster</rdf:li>
           </rdf:Seq></digiKam:TagsList>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try xmp.write(to: URL(fileURLWithPath: image.path + ".xmp"), atomically: true, encoding: .utf8)

        harness.store.applyParsedSidecars(paths: [image.path])
        let updated = try XCTUnwrap(harness.store.photo(at: image))
        XCTAssertEqual(updated.fileSize, 4)
        XCTAssertEqual(
            Set(updated.hierarchicalTags.map(\.fullPath)),
            ["People/Ada", "Objects/Poster"]
        )
        XCTAssertEqual(updated.peopleTagsWithoutFace.map(\.displayName), ["Ada"])
    }

    func testViewerPayloadKeepsTheTappedPhotoEvenIfTheAlbumIsEmpty() {
        let photo = PhotoFile.fixture(url: URL(fileURLWithPath: "/tmp/library/a.jpg"))
        let viewer = FacePhotoViewer(photo: photo, album: [])
        XCTAssertEqual(viewer.photos.map(\.id), [photo.id])
        XCTAssertEqual(viewer.currentID, photo.id)
    }
}
