import XCTest
@testable import LocalGallery

/// Bounded wait + coalescing around the blocking file-coordinator path.
@MainActor
final class PhotoMaterializerTests: XCTestCase {

    private func writeTempPhoto() -> (PhotoFile, TempDir) {
        let tmp = TempDir.make()
        addTeardownBlock { tmp.teardown() }
        let url = tmp.appending("remote.jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        var photo = PhotoFile.fixture(url: url)
        photo.locality = .remote(downloaded: false)
        return (photo, tmp)
    }

    func testConcurrentRequestsShareOneCoordinationAttempt() async throws {
        let (photo, _) = writeTempPhoto()
        let materializer = PhotoMaterializer()
        materializer.testForceCoordination = true
        materializer.testCoordinationDelay = .milliseconds(60)
        materializer.coordinationTimeout = .seconds(5)

        async let first = materializer.ensureMaterialized(photo)
        async let second = materializer.ensureMaterialized(photo)
        let urls = try await (first, second)

        XCTAssertEqual(urls.0, photo.url)
        XCTAssertEqual(urls.1, photo.url)
        XCTAssertEqual(materializer.debugCoordinationStarts, 1)
    }

    func testWaiterTimesOutWithoutCancellingTheSharedAttempt() async {
        let (photo, _) = writeTempPhoto()
        let materializer = PhotoMaterializer()
        materializer.testForceCoordination = true
        materializer.testCoordinationDelay = .milliseconds(400)
        materializer.coordinationTimeout = .milliseconds(40)

        do {
            _ = try await materializer.ensureMaterialized(photo)
            XCTFail("expected a timeout")
        } catch let error as PhotoMaterializer.MaterializationError {
            guard case .timeout = error else {
                return XCTFail("expected timeout, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(materializer.debugCoordinationStarts, 1)

        materializer.coordinationTimeout = .seconds(5)
        do {
            let url = try await materializer.ensureMaterialized(photo)
            XCTAssertEqual(url, photo.url)
        } catch {
            XCTFail("retry should join the in-flight attempt: \(error)")
        }
        XCTAssertEqual(materializer.debugCoordinationStarts, 1,
                       "a timeout must not start a second coordinated read")
    }
}
