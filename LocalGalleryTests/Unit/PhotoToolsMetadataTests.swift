import Foundation
import XCTest
@testable import LocalGallery

@MainActor
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
    func testSidecarReadFallsBackToCoreSentinelAndReadsClipFields() async throws {
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

        let meta = await EXIFService.loadPhotoToolsMetadata(for: .fixture(url: photoURL))
        XCTAssertEqual(meta.taggerVersion, "mobileclip-s2-2026.1")
        XCTAssertEqual(meta.taggedAt, "2026-08-03T10:00:00Z")
        XCTAssertEqual(meta.clipModel, "mobileclip-s2-2026.1")
        XCTAssertEqual(meta.clipTimestamp, "2026-08-03T10:00:00Z")
        XCTAssertEqual(meta.facePack, "buffalo_sc-2026.1")
        XCTAssertEqual(meta.faceTaggedAt, "2026-08-03T10:05:00Z")
        XCTAssertFalse(meta.isEmpty)
    }

    /// photo-tools' own sentinels win over the core's, so a file both tools
    /// have touched still shows the version photo-tools stamped.
    func testPhotoToolsSentinelsWinOverCoreFallbacks() async throws {
        let temp = makeTemp()
        let photoURL = temp.appending("IMG_2.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data()))
        let xmp = """
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
         <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
          <rdf:Description rdf:about=''
           xmlns:phototools='https://github.com/j23n/photo-tools/ns/1.0/'>
           <phototools:TaggerVersion>2026.4</phototools:TaggerVersion>
           <phototools:TaggedAt>2026-07-01T09:15:00Z</phototools:TaggedAt>
           <phototools:CoreModelPack>mobileclip-s2-2026.1</phototools:CoreModelPack>
           <phototools:CoreTaggedAt>2026-08-03T10:00:00Z</phototools:CoreTaggedAt>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try xmp.write(to: photoURL.appendingPathExtension("xmp"), atomically: true, encoding: .utf8)

        let meta = await EXIFService.loadPhotoToolsMetadata(for: .fixture(url: photoURL))
        XCTAssertEqual(meta.taggerVersion, "2026.4")
        XCTAssertEqual(meta.taggedAt, "2026-07-01T09:15:00Z")
    }
}
