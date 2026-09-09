import Foundation
import XCTest
@testable import LocalGallery

final class LogRedactionTests: XCTestCase {
    func testGPSIsQuantizedBeforeItCanReachALogger() {
        let exactLat = 48.8584
        let exactLon = 2.2945
        let rendered = Log.r.gps(exactLat, exactLon)
        XCTAssertEqual(rendered, "lat≈48.86 lon≈2.29")
        XCTAssertFalse(rendered.contains("48.8584"))
        XCTAssertFalse(rendered.contains("2.2945"))
        XCTAssertEqual(quantizedGPS(latitude: exactLat, longitude: exactLon), rendered)
    }

    func testGPSQuantizationKeepsCityScaleDiagnostics() {
        let paris = Log.r.gps(48.8584, 2.2945)
        let rome = Log.r.gps(41.9028, 12.4964)
        XCTAssertNotEqual(paris, rome)
        XCTAssertEqual(Log.r.gps(-33.8688, 151.2093), "lat≈-33.87 lon≈151.21")
    }

    func testNonFiniteGPSIsASentinel() {
        XCTAssertEqual(Log.r.gps(.nan, 0), "lat=? lon=?")
        XCTAssertEqual(Log.r.gps(0, .infinity), "lat=? lon=?")
    }

    func testPlacePathIsTokenizedNotLoggedRaw() {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        let redactor = LogRedactor(fileURL: temp.appending("log-redaction-key.json"))
        let raw = "Places/France/Île-de-France/Paris/Louvre"
        let token = redactor.token(raw, kind: .place)
        XCTAssertEqual(token, "place#0")
        XCTAssertEqual(redactor.token(raw, kind: .place), "place#0")
        XCTAssertEqual(redactor.token("Places/Italy/Lazio/Rome", kind: .place), "place#1")
        XCTAssertFalse(token.contains("Paris"))
        XCTAssertFalse(token.contains("Louvre"))
        XCTAssertFalse(token.contains("Places/"))
    }

    func testLogRPlaceUsesThePlaceKind() {
        let raw = "Places/France/Paris/\(UUID().uuidString)"
        let token = Log.r.place(raw)
        XCTAssertTrue(token.hasPrefix("place#"), token)
        XCTAssertFalse(token.contains("Paris"))
        XCTAssertFalse(token.contains(raw))
        XCTAssertEqual(Log.r.place(raw), token)
    }

    func testErrorDescriptionIsTokenized() {
        let err = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "A server with the specified hostname could not be found. (/Users/ada/Photos/IMG_4032.jpg)"]
        )
        let rendered = Log.r.error(err)
        XCTAssertTrue(rendered.hasPrefix("\(NSURLErrorDomain)#\(NSURLErrorCannotFindHost) "), rendered)
        XCTAssertFalse(rendered.contains("IMG_4032.jpg"))
        XCTAssertFalse(rendered.contains("/Users/ada"))
    }
}
