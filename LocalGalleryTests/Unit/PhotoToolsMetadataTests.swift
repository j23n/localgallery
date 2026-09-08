import Foundation
import XCTest
@testable import LocalGallery

final class PhotoToolsMetadataTests: XCTestCase {
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    /// After a tagging run the info panel has to show *something* for
    /// version / time even though we never stamp photo-tools' TaggerVersion
    /// sentinel. CoreModelPack / CoreTaggedAt plus the CLIP cache fields
    /// are what a sidecar we wrote actually contains.
    func testSidecarReadFallsBackToCoreSentinelAndReadsClipFields() throws {
        let temp = makeTemp()
        let photoURL = temp.appending("IMG_1.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data()))
        let xmp = """
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
         <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
          <rdf:Description rdf:about=''
           xmlns:phototools='https://github.com/j23n/photo-tools/ns/1.0/'>
           <phototools:CoreModelPack>mobileclip-s2-2026.1</phototools:CoreModelPack>
           <phototools:CoreTaggedAt>2026-08-03T10:00:00Z</phototools:CoreTaggedAt>
           <phototools:CLIPModel>mobileclip-s2-2026.1</phototools:CLIPModel>
           <phototools:CLIPTimestamp>2026-08-03T10:00:00Z</phototools:CLIPTimestamp>
           <phototools:CoreFacePack>buffalo_sc-2026.1</phototools:CoreFacePack>
           <phototools:CoreFaceTaggedAt>2026-08-03T10:05:00Z</phototools:CoreFaceTaggedAt>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try xmp.write(to: photoURL.appendingPathExtension("xmp"), atomically: true, encoding: .utf8)

        let meta = SidecarDocument.read(imageURL: photoURL).tools
        XCTAssertEqual(meta.taggerVersion, "mobileclip-s2-2026.1")
        XCTAssertEqual(meta.taggedAt, "2026-08-03T10:00:00Z")
        XCTAssertEqual(meta.clipModel, "mobileclip-s2-2026.1")
        XCTAssertEqual(meta.clipTimestamp, "2026-08-03T10:00:00Z")
        XCTAssertEqual(meta.facePack, "buffalo_sc-2026.1")
        XCTAssertEqual(meta.faceTaggedAt, "2026-08-03T10:05:00Z")
        XCTAssertFalse(meta.isEmpty)
    }

    func testMergingPrefersSelfAndFillsGaps() {
        let newer = PhotoToolsMetadata(facePack: "buffalo_sc-2026.1")
        let older = PhotoToolsMetadata(
            taggerVersion: "mobileclip-s2-2026.1",
            facePack: "old",
            faceTaggedAt: "2026-08-03T10:05:00Z"
        )
        let merged = newer.merging(over: older)
        XCTAssertEqual(merged.taggerVersion, "mobileclip-s2-2026.1")
        XCTAssertEqual(merged.facePack, "buffalo_sc-2026.1")
        XCTAssertEqual(merged.faceTaggedAt, "2026-08-03T10:05:00Z")
    }
}
