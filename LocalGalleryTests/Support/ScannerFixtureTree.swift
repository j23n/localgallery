import Foundation
import XCTest

/// Materialises the fixture library described by
/// `core/fixtures/scan-conformance/scanner_tree.json` and applies the
/// between-pass mutations.
///
/// The tree lives in JSON rather than in this file so the Rust port can build
/// the byte-identical library from the same description. `FolderScanner`
/// never opens a file — it stats and classifies by extension — so filler
/// bytes with an explicit size and modification date are the whole contract.
struct ScannerFixtureTree: Decodable {

    let schema: Int
    /// Directory name the library is created under, inside the caller's temp
    /// dir. Fixed (not the temp dir's random name) because it is the root
    /// `PhotoFolder`'s `name` and therefore part of the expectation.
    let root: String
    let initial: [Entry]
    let mutations: [Mutation]

    struct Entry: Decodable {
        let dir: String?
        let file: String?
        let size: Int?
        let fill: String?
        let mtime: String?
    }

    struct Mutation: Decodable {
        /// `create` · `delete` · `rewrite` · `lockDirectory`
        let op: String
        let path: String
        let size: Int?
        let fill: String?
        let mtime: String?
    }

    // MARK: - Loading

    static func load(file: StaticString = #filePath, line: UInt = #line) throws -> ScannerFixtureTree {
        let url = try ConformanceFixtures.root(file: file, line: line)
            .appendingPathComponent("scanner_tree.json")
        return try JSONDecoder().decode(ScannerFixtureTree.self, from: Data(contentsOf: url))
    }

    // MARK: - Materialising

    nonisolated(unsafe) private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    /// Create the library under `base` and return its root URL.
    @discardableResult
    func materialize(in base: URL) throws -> URL {
        let rootURL = base.appendingPathComponent(root, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for entry in initial {
            if let dir = entry.dir {
                try FileManager.default.createDirectory(
                    at: rootURL.appendingPathComponent(dir, isDirectory: true),
                    withIntermediateDirectories: true
                )
            } else if let file = entry.file {
                try Self.write(
                    rootURL.path + "/" + file,
                    size: entry.size ?? 0, fill: entry.fill ?? "0", mtime: entry.mtime
                )
            }
        }
        return rootURL
    }

    /// Apply every mutation, in order. Returns the directories that were
    /// chmod-000'd so the caller can restore them in `tearDown` — a leaked
    /// unreadable directory breaks the *next* run's temp-dir cleanup.
    @discardableResult
    func mutate(_ rootURL: URL) throws -> [URL] {
        var locked: [URL] = []
        for m in mutations {
            let path = rootURL.path + "/" + m.path
            switch m.op {
            case "create", "rewrite":
                try Self.write(path, size: m.size ?? 0, fill: m.fill ?? "0", mtime: m.mtime)
            case "delete":
                try FileManager.default.removeItem(atPath: path)
            case "lockDirectory":
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
                locked.append(URL(fileURLWithPath: path, isDirectory: true))
            default:
                throw NSError(domain: "ScannerFixtureTree", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "unknown mutation op \(m.op)"
                ])
            }
        }
        return locked
    }

    static func unlock(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
    }

    /// Create the file with the *byte-exact* name.
    ///
    /// Deliberately not `Data.write(to:)`: every Foundation path API on Darwin
    /// runs the name through `fileSystemRepresentation`, which DECOMPOSES it,
    /// so an NFC fixture name would land on disk as NFD and the normalization
    /// cases would test nothing. `String.withCString` hands over the UTF-8
    /// bytes untouched, which is what `open(2)` wants.
    private static func write(_ path: String, size: Int, fill: String, mtime: String?) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        let byte = fill.utf8.first ?? 0x30
        let bytes = [UInt8](repeating: byte, count: size)
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open(\(path)) failed"
            ])
        }
        if !bytes.isEmpty {
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)
        // Set the modification date *after* the write, and always: it is the
        // scanner's change-detection key and, being older than the file's
        // birth time, it is also what `earliestFilesystemDate` picks — which
        // is what makes `dateTaken` reproducible.
        if let mtime, let date = iso.date(from: mtime) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }
}
