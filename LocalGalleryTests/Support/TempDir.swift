import Foundation
import XCTest

/// Per-test temporary directory under `NSTemporaryDirectory()`. The dir is
/// created on `make()` and removed on `teardown()`. Test classes hold on to
/// the value as a stored property and call `teardown()` from `tearDown()`.
final class TempDir {
    let url: URL

    private init(url: URL) { self.url = url }

    static func make(file: StaticString = #file, line: UInt = #line) -> TempDir {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LocalGallery.tests.\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create temp dir at \(base.path): \(error)", file: file, line: line)
        }
        return TempDir(url: base)
    }

    /// Build a child URL under this temp dir without touching the filesystem.
    func appending(_ path: String, isDirectory: Bool = false) -> URL {
        url.appendingPathComponent(path, isDirectory: isDirectory)
    }

    func teardown() {
        try? FileManager.default.removeItem(at: url)
    }
}
