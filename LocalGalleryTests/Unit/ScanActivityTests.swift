import Foundation
import XCTest
@testable import LocalGallery

@MainActor
final class ScanActivityTests: XCTestCase {
    func testWrittenTagsSummarizeAsDisplayNames() {
        let entry = ScanActivityEntry(
            id: UUID(),
            photoID: UUID(),
            url: URL(fileURLWithPath: "/tmp/IMG_1842.jpg"),
            filename: "IMG_1842.jpg",
            at: Date(),
            phase: .tagging,
            outcome: .written,
            tags: ["Objects/Dog", "Scenes/Beach"],
            faceNames: []
        )
        XCTAssertEqual(entry.summary, "Dog · Beach")
    }

    func testWrittenWithNothingToShowIsNoTags() {
        let entry = ScanActivityEntry(
            id: UUID(),
            photoID: UUID(),
            url: URL(fileURLWithPath: "/tmp/empty.jpg"),
            filename: "empty.jpg",
            at: Date(),
            phase: .tagging,
            outcome: .written,
            tags: [],
            faceNames: []
        )
        XCTAssertEqual(entry.summary, "no tags")
    }

    func testFaceCountSummarizesWhenPeopleTagsAreEmpty() {
        let entry = ScanActivityEntry(
            id: UUID(),
            photoID: UUID(),
            url: URL(fileURLWithPath: "/tmp/faces.jpg"),
            filename: "faces.jpg",
            at: Date(),
            phase: .faces,
            outcome: .written,
            tags: [],
            faceNames: ["Ada", "Zoe"]
        )
        XCTAssertEqual(entry.summary, "2 faces")
    }

    func testOnFilePeopleWithoutAFaceSummarizeAsOnFile() {
        let entry = ScanActivityEntry(
            id: UUID(),
            photoID: UUID(),
            url: URL(fileURLWithPath: "/tmp/named.jpg"),
            filename: "named.jpg",
            at: Date(),
            phase: .faces,
            outcome: .existing,
            tags: ["People/Ada"],
            faceNames: []
        )
        XCTAssertEqual(entry.peopleWithoutDetection, ["People/Ada"])
        XCTAssertEqual(entry.summary, "on file · no face · Ada")
    }

    func testOnFileEntryUsesPeopleTagsWithoutAFace() {
        var photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/poster.jpg"),
            tags: ["People/Ada", "Objects/Poster"]
        )
        photo.faceRegions = [
            FaceRegion(name: "Ada", centerX: 0.5, centerY: 0.4, width: 0.2, height: 0.3)
        ]
        XCTAssertTrue(ScanActivityEntry.onFile(photo: photo).tags.isEmpty)

        var unnamed = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/named.jpg"),
            tags: ["People/Ada"]
        )
        let entry = ScanActivityEntry.onFile(photo: unnamed)
        XCTAssertEqual(entry.outcome, .existing)
        XCTAssertEqual(entry.tags, ["People/Ada"])
        XCTAssertEqual(entry.summary, "on file · no face · Ada")
    }

    func testPeopleTagMatchingADetectedNameIsNotOnFileOnly() {
        var photo = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/tmp/ada.jpg"),
            tags: ["People/Ada"]
        )
        XCTAssertEqual(photo.peopleTagsWithoutFace.map(\.displayName), ["Ada"])

        photo.faceRegions = [
            FaceRegion(name: "Ada", centerX: 0.5, centerY: 0.4, width: 0.2, height: 0.3)
        ]
        XCTAssertTrue(photo.peopleTagsWithoutFace.isEmpty)
    }

    func testFailedOutcomeLeadsTheSummary() {
        let entry = ScanActivityEntry(
            id: UUID(),
            photoID: UUID(),
            url: URL(fileURLWithPath: "/tmp/bad.jpg"),
            filename: "bad.jpg",
            at: Date(),
            phase: .places,
            outcome: .failed("network"),
            tags: [],
            faceNames: []
        )
        XCTAssertEqual(entry.summary, "failed · network")
    }

    func testALaterWriteReplacesTheEarlierScanRowForTheSamePhoto() {
        let log = ScanActivityLog()
        let url = URL(fileURLWithPath: "/tmp/ada.jpg")
        let id = PhotoFile.stableID(for: url)
        log.record(ScanActivityEntry(
            id: UUID(),
            photoID: id,
            url: url,
            filename: "ada.jpg",
            at: Date(),
            phase: .faces,
            outcome: .written,
            tags: [],
            faceNames: []
        ))
        log.record(ScanActivityEntry(
            id: UUID(),
            photoID: id,
            url: url,
            filename: "ada.jpg",
            at: Date(),
            phase: .faces,
            outcome: .written,
            tags: ["People/Ada"],
            faceNames: ["Ada"]
        ))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.tags, ["People/Ada"])
    }

    func testCapDropsTheOldestFromTheEnd() {
        let log = ScanActivityLog()
        let batch = (0..<(ScanActivityLog.cap + 1)).map { i in
            ScanActivityEntry(
                id: UUID(),
                photoID: UUID(),
                url: URL(fileURLWithPath: "/tmp/\(i).jpg"),
                filename: "\(i).jpg",
                at: Date(),
                phase: .tagging,
                outcome: .written,
                tags: [],
                faceNames: []
            )
        }
        log.record(batch)
        XCTAssertEqual(log.entries.count, ScanActivityLog.cap)
        XCTAssertEqual(log.entries.first?.filename, "\(ScanActivityLog.cap).jpg")
        XCTAssertEqual(log.entries.last?.filename, "1.jpg")
    }

    func testBeginRunClearsAndStaleIngestIsDropped() async {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        let image = temp.appending("dog.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data("jpeg".utf8)))
        try writeSidecar(at: image, tags: ["Objects/Dog"])

        let log = ScanActivityLog()
        log.record(ScanActivityEntry.place(
            url: URL(fileURLWithPath: "/tmp/old.jpg"),
            path: "Places/Old",
            outcome: .written
        ))
        XCTAssertEqual(log.entries.count, 1)

        log.beginRun()
        XCTAssertTrue(log.entries.isEmpty)

        await log.ingest(paths: [image.path], phase: .tagging, generation: 0)
        XCTAssertTrue(log.entries.isEmpty, "an ingest started before beginRun must not land")

        await log.ingest(paths: [image.path], phase: .tagging)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.tags, ["Objects/Dog"])
        XCTAssertEqual(log.entries.first?.summary, "Dog")
    }

    func testAttachDiagnosticsMergesBeforeAndAfterIngest() async {
        let log = ScanActivityLog()
        let url = URL(fileURLWithPath: "/tmp/ada.jpg")
        let id = PhotoFile.stableID(for: url)
        let diagnostic = FacePhotoDiagnostic(
            score: 0.91,
            quality: 0.42,
            clusterID: 3,
            assignment: .seeded,
            label: nil
        )

        log.attachDiagnostics([url.path: [diagnostic]])
        log.record(ScanActivityEntry(
            id: UUID(),
            photoID: id,
            url: url,
            filename: "ada.jpg",
            at: Date(),
            phase: .faces,
            outcome: .written,
            tags: [],
            faceNames: []
        ))
        XCTAssertEqual(log.entries.first?.diagnostics, [diagnostic])

        let joined = FacePhotoDiagnostic(
            score: 0.80,
            quality: 0.30,
            clusterID: 3,
            assignment: .joined,
            label: "Ada"
        )
        log.attachDiagnostics(["/tmp/./ada.jpg": [joined]])
        XCTAssertEqual(log.entries.first?.diagnostics, [joined])
    }

    func testSidecarParseKeepsOnlyThePhaseNamespace() throws {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        let image = temp.appending("mixed.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data("jpeg".utf8)))
        try writeSidecar(at: image, tags: [
            "Objects/Dog",
            "Scenes/Beach",
            "People/Ada",
            "Places/Italy/Rome",
        ])

        let tagging = ScanActivityLog.entry(forImagePath: image.path, phase: .tagging)
        XCTAssertEqual(tagging.tags.sorted(), ["Objects/Dog", "Scenes/Beach"])

        let faces = ScanActivityLog.entry(forImagePath: image.path, phase: .faces)
        XCTAssertEqual(faces.tags, ["People/Ada"])

        let places = ScanActivityLog.entry(forImagePath: image.path, phase: .places)
        XCTAssertEqual(places.tags, ["Places/Italy/Rome"])
        XCTAssertEqual(places.summary, "Rome")
    }

    private func writeSidecar(at image: URL, tags: [String]) throws {
        let items = tags.map { "<rdf:li>\($0)</rdf:li>" }.joined()
        let xmp = """
        <?xpacket begin='' id='W5M0Mp'?>
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
        <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
         <rdf:Description rdf:about=''
          xmlns:digiKam='http://www.digikam.org/ns/1.0/'>
          <digiKam:TagsList><rdf:Seq>\(items)</rdf:Seq></digiKam:TagsList>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end='w'?>
        """
        try Data(xmp.utf8).write(to: URL(fileURLWithPath: image.path + ".xmp"))
    }
}
