import Foundation
import XCTest
@testable import LocalGallery

final class SidecarDocumentTests: XCTestCase {
    func testReadPicksAppendedSidecarAndStamps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("IMG.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: Data()))
        let xmp = """
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
         <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
          <rdf:Description rdf:about=''
           xmlns:digiKam='http://www.digikam.org/ns/1.0/'
           xmlns:phototools='https://github.com/j23n/photo-tools/ns/1.0/'>
           <digiKam:TagsList><rdf:Seq><rdf:li>People/Ada</rdf:li></rdf:Seq></digiKam:TagsList>
           <phototools:CoreFacePack>buffalo_sc-2026.1</phototools:CoreFacePack>
           <phototools:CoreFaceTaggedAt>2026-08-03T10:05:00Z</phototools:CoreFaceTaggedAt>
           <phototools:CoreFaceDecisions>
            <rdf:Bag><rdf:li>0.4,0.35,0.12,0.16 named Ada</rdf:li></rdf:Bag>
           </phototools:CoreFaceDecisions>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try xmp.write(to: URL(fileURLWithPath: image.path + ".xmp"), atomically: true, encoding: .utf8)

        let doc = SidecarDocument.read(imagePath: image.path)
        XCTAssertTrue(doc.exists)
        XCTAssertEqual(doc.rawTags, ["People/Ada"])
        XCTAssertEqual(doc.tools.facePack, "buffalo_sc-2026.1")
        XCTAssertEqual(doc.tools.faceTaggedAt, "2026-08-03T10:05:00Z")
        XCTAssertEqual(doc.namedWithoutBox, ["Ada"])
    }

    func testAttributeFormStampsAreRead() {
        let xml = """
        <rdf:Description phototools:CoreFacePack="buffalo_sc-2026.1" phototools:CoreFaceTaggedAt="2026-08-03T10:00:00Z"/>
        """
        let doc = SidecarDocument.parse(data: Data(xml.utf8), url: nil)
        XCTAssertEqual(doc.tools.facePack, "buffalo_sc-2026.1")
        XCTAssertEqual(doc.tools.faceTaggedAt, "2026-08-03T10:00:00Z")
    }

    func testPhotoToolsSentinelsWinOverCoreFallbacks() {
        let xml = """
        <phototools:TaggerVersion>2026.4</phototools:TaggerVersion>
        <phototools:TaggedAt>2026-07-01T09:15:00Z</phototools:TaggedAt>
        <phototools:CoreModelPack>mobileclip-s2-2026.1</phototools:CoreModelPack>
        <phototools:CoreTaggedAt>2026-08-03T10:00:00Z</phototools:CoreTaggedAt>
        """
        let doc = SidecarDocument.parse(data: Data(xml.utf8), url: nil)
        XCTAssertEqual(doc.tools.taggerVersion, "2026.4")
        XCTAssertEqual(doc.tools.taggedAt, "2026-07-01T09:15:00Z")
    }

    func testApplyUnionsPeopleTagAndOnDiskFlag() {
        var photo = PhotoFile.fixture(url: URL(fileURLWithPath: "/tmp/a.jpg"), tags: ["Objects/Cup"])
        var doc = SidecarDocument.empty
        doc.exists = true
        doc.rawTags = ["People/Ada"]
        doc.tools.facePack = "buffalo_sc-2026.1"
        doc.tools.faceTaggedAt = "2026-08-03T10:05:00Z"
        photo.apply(doc)
        XCTAssertTrue(photo.sidecarOnDisk)
        XCTAssertEqual(photo.photoTools.facePack, "buffalo_sc-2026.1")
        XCTAssertEqual(Set(photo.hierarchicalTags.map(\.fullPath)), ["Objects/Cup", "People/Ada"])
        XCTAssertEqual(photo.peopleTagsWithoutFace.map(\.displayName), ["Ada"])
    }
}
