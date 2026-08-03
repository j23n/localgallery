import XCTest
@testable import LocalGallery

/// Pins the *current* `FolderScanner` output over the fixture library
/// described by `core/fixtures/scan-conformance/scanner_tree.json`.
///
/// Four passes over one tree:
///
/// | pass | kind | cache | tree |
/// |---|---|---|---|
/// | `1-full-cold` | full | empty | initial |
/// | `2-light-after-mutations` | light | pass 1 | mutated, `Locked/` chmod 000 |
/// | `3-full-after-mutations` | full | pass 1 | mutated, `Locked/` chmod 000 |
/// | `4-light-after-unlock` | light | pass 1 | mutated, `Locked/` readable |
///
/// Passes 2 and 3 differ *only* in `reuseCached`, which is what makes the
/// light-scan blind spot legible: `a.jpg` is rewritten with a new size and a
/// new mtime, and only the full pass notices.
///
/// Nothing in the fixture stores an absolute path or a UUID. Paths are
/// relative to the library root; ids are re-derived at assert time from the
/// real absolute URL via `PhotoFile.stableID(for:)` and only the *match* is
/// recorded (`idMatchesStableUUIDOfPath`).
final class ScannerConformanceTests: XCTestCase {

    private var temp: TempDir!
    private var lockedDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        temp = TempDir.make()
    }

    override func tearDown() {
        // Restore before the temp dir is torn down — FileManager cannot
        // remove a directory it is not allowed to read.
        ScannerFixtureTree.unlock(lockedDirectories)
        lockedDirectories = []
        temp?.teardown()
        temp = nil
        super.tearDown()
    }

    // MARK: - Fixture shape

    struct Dump: Codable, Equatable {
        let schema: Int
        let passes: [Pass]
    }

    struct Pass: Codable, Equatable {
        let name: String
        /// `FolderScanner.scan(reuseCached:)` — true is the light scan.
        let reuseCached: Bool
        /// Which pass's output seeded `cachedPhotos` / `cachedSidecarManifest`.
        let cacheFrom: String?
        let treeState: String
        let needsEnrichment: Bool
        let rootFolder: Folder?
        /// Sorted by path. Within-folder order is the filesystem's listing
        /// order and is NOT specified — see the pass notes.
        let flatPhotos: [Photo]
        let addedPaths: [String]
        let removedPaths: [String]
        let modifiedPaths: [String]
        let failedDirectoryPaths: [String]
        let sidecarManifest: [SidecarRow]
        let notes: [String]
    }

    /// Subfolder order IS specified (sorted ascending by
    /// `localizedStandardCompare`, via the descending push onto the DFS
    /// stack) and is compared as-is.
    struct Folder: Codable, Equatable {
        let path: String
        let name: String
        let photoCount: Int
        let photoPaths: [String]       // sorted; listing order is unspecified
        let totalPhotoCount: Int
        /// `ownPhotos` · `subfolder:<name>` · `none` — pins the cover-selection
        /// rule without pinning the unspecified within-folder listing order.
        let coverPhotoSource: String
        let hasDateModified: Bool
        let hasDateCreated: Bool
        let subfolders: [Folder]
    }

    struct Photo: Codable, Equatable {
        let path: String
        /// `ascii` · `NFC` · `NFD`. Load-bearing: Swift's `String ==` is
        /// canonical equivalence, so comparing `path` alone can NEVER catch a
        /// normalization change. This ASCII token can.
        let pathNormalization: String
        let filename: String
        let filenameNormalization: String
        let fileSize: Int64
        let isVideo: Bool
        let livePhotoVideoPath: String?
        let dateTaken: ConformanceDate?
        let dateFromMetadata: Bool
        let fileModificationDate: ConformanceDate?
        let enrichedFileDate: ConformanceDate?
        let locality: String
        let sidecarStatus: String
        let countryCode: String?
        let hierarchicalTagCount: Int
        let faceRegionCount: Int
        /// Always true; the assertion is the point, the recorded value is the
        /// receipt. Ids are derived from the absolute path, so they cannot be
        /// committed — this is how the fixture pins them anyway.
        let idMatchesStableUUIDOfPath: Bool
    }

    struct SidecarRow: Codable, Equatable {
        let photoPath: String
        let sidecarPath: String
        let downloadStatus: String
        /// The value itself is provider/volume-dependent; only its presence is
        /// part of the contract.
        let versionHasContentIdentifier: Bool
        let versionModificationDate: ConformanceDate?
        let versionSize: Int64?
    }

    // MARK: - Pass notes

    private static let passNotes: [String: [String]] = [
        "1-full-cold": [
            "Cold full scan: no cache, so every file takes the slow path and everything lands in addedPaths.",
            "Traversal is an explicit stack. Subdirectories are sorted DESCENDING by localizedStandardCompare before being pushed, so they pop ASCENDING — root's children come out Empty, Junk, Locked, Media, Nested, Unicode and Nested/Deep is visited before Unicode.",
            "Within a folder, photo order is whatever contentsOfDirectory returned. That is NOT specified; this fixture sorts flatPhotos and photoPaths by path. The Rust port is free to emit any within-folder order (the app sorts in SearchIndex anyway) but MUST keep the folder order above.",
            "Classification is by extension only: Junk/readme.txt, Junk/data.xyz and Junk/noext are not media, Junk/.hidden.jpg is filtered by .skipsHiddenFiles, Junk/orphan.xmp is a sidecar with no photo and produces no row.",
            "Junk/zero.jpg is a zero-byte file and is scanned like any other image.",
            "dateTaken has no metadata behind it here — the scanner never opens a file. It is min(creationDate, modificationDate); every fixture mtime is older than its birth time, so dateTaken == fileModificationDate.",
            "dateFromMetadata is false for everything: only EnrichmentService ever sets it.",
            "enrichedFileDate is nil for every slow-path photo, which is exactly what makes needsEnrichment true.",
            "Live-photo pairing covers both shapes: IMG_0001.jpg + IMG_0001.mov, and the double-extension IMG_0002.heic + IMG_0002.heic.mov. A paired .mov never becomes a photo of its own — only the standalone Media/Clip.MOV does.",
            "LANDMINE: a standalone video's `filename` is LOWERCASED. The image branch assigns `url.deletingPathExtension().lastPathComponent` (B.JPG -> \"B\"), the standalone-video branch assigns `videoStem(url)`, which lowercases (Clip.MOV -> \"clip\"). Not a typo in the fixture.",
            "LANDMINE: Media/Clip.MOV.xmp exists and produces NO sidecar manifest row. The manifest is emitted only inside the image loop, so a video can never carry a sidecar through a scan.",
            "Junk/orphan.xmp is a sidecar with no photo: no row, no photo, no complaint.",
            "The sidecar manifest keys on the LOWERCASED full basename, so B.JPG finds B.JPG.xmp.",
            "totalPhotoCount is recursive (root = 15) while photoCount is the folder's own; Empty/ still becomes a node, with coverPhotoSource \"none\".",
            "versionHasContentIdentifier is true here: APFS populates fileContentIdentifierKey, so ContentVersion.sameContent compares identifiers rather than (mtime, size). On a provider that leaves it nil the other branch runs — both are live paths.",
            "PhotoLocality is `local` for everything: FileProviderDetector sees totalFileSize == fileSize on a plain volume, so nothing looks provider-backed.",
        ],
        "2-light-after-mutations": [
            "Light scan (reuseCached = true) against the pass-1 cache.",
            "LANDMINE — the light-scan blind spot: for a URL already in the cache the classify pass reuses the CACHED size and mtime and never stats the file. `a.jpg` was rewritten with a different size AND a different mtime and still does not appear in modifiedPaths. A light scan can never detect a change to a file it already knows.",
            "Unicode/emoji cactus.jpg was rewritten with the SAME size and mtime; it is invisible to light and full alike, because the only change signal is (fileSize, fileModificationDate).",
            "Locked/ is chmod 000: its listing throws, so it contributes a failedDirectoryPaths entry, its photos are absent from flatPhotos, and — critically — they are EXCLUDED from removedPaths. A transient I/O error must not look like a deletion.",
            "The Locked/ folder node still exists in the tree (with zero photos): the directory is stat-able even when it is not listable.",
            "Nested/nested1.jpg was deleted and does appear in removedPaths.",
            "New files (Media/IMG_0003.jpg, Added/added1.jpg) take the slow path even in a light scan, because a cache miss is the one branch that stats.",
            "Cached photos keep their cached PhotoFile verbatim; only `filename` and `livePhotoVideoURL` are refreshed, since live-photo pairing can change without the photo's own bytes changing.",
            "Sidecar rows for unchanged photos are reused from the cached manifest, which is what skips the 7-key FileProviderDetector probe.",
            "Nested/Deep/deep1.jpg.xmp was deleted, so its row disappears — a removed sidecar drops out of the manifest via the directory listing, never via the cache.",
            "Locked/locked1.jpg's row disappears too, but only because its directory could not be listed. Compare pass 4.",
        ],
        "3-full-after-mutations": [
            "Full scan (reuseCached = false) against the same pass-1 cache and the same mutated tree — the direct comparison with pass 2.",
            "`a.jpg` IS in modifiedPaths here: the full pass stats every file, so the new size and mtime are visible.",
            "Unicode/emoji cactus.jpg is still invisible: same size, same mtime, different bytes. Neither scan kind hashes content.",
            "Everything else matches pass 2 — full vs light changes WHAT is detected, not the tree shape or the removal accounting.",
            "A full scan re-probes and rebuilds every PhotoFile, but for an unchanged file it still carries the cached dateTaken / tags / GPS / country forward and keeps enrichedFileDate, so it does not force a re-enrichment.",
        ],
        "4-light-after-unlock": [
            "Light scan against the pass-1 cache with Locked/ readable again.",
            "The previously unreadable photos come back as plain cache hits — no removal, no re-enrichment — which is the payoff for excluding them from removedPaths in passes 2 and 3.",
            "failedDirectoryPaths is empty and removedPaths contains only the genuinely deleted Nested/nested1.jpg.",
            "Locked/locked1.jpg's sidecar row is back, taken from the cached manifest rather than re-probed.",
            "Unicode/ pins the normalization contract: café.jpg is stored NFD, résumé.jpg NFC, and both survive the round trip byte-for-byte. `pathNormalization` is the field that proves it — comparing the path strings could not, because Swift's String == is canonical equivalence. See PathNormalizationTests.",
        ],
    ]

    // MARK: - The dump

    func testScannerConformance() async throws {
        let tree = try ScannerFixtureTree.load()
        let root = try tree.materialize(in: temp.url)

        // Pass 1 — cold full scan over the pristine tree.
        let pass1 = await FolderScanner.scan(at: root, reuseCached: false)
        let cachedPhotos = Dictionary(pass1.flatPhotos.map { ($0.url, $0) }, uniquingKeysWith: { _, b in b })
        let cachedManifest = Dictionary(pass1.sidecarManifest.map { ($0.photoID, $0) }, uniquingKeysWith: { _, b in b })

        lockedDirectories = try tree.mutate(root)

        let pass2 = await FolderScanner.scan(
            at: root, cachedPhotos: cachedPhotos,
            cachedSidecarManifest: cachedManifest, reuseCached: true
        )
        let pass3 = await FolderScanner.scan(
            at: root, cachedPhotos: cachedPhotos,
            cachedSidecarManifest: cachedManifest, reuseCached: false
        )

        ScannerFixtureTree.unlock(lockedDirectories)
        lockedDirectories = []

        let pass4 = await FolderScanner.scan(
            at: root, cachedPhotos: cachedPhotos,
            cachedSidecarManifest: cachedManifest, reuseCached: true
        )

        let dump = Dump(schema: 1, passes: [
            record(pass1, name: "1-full-cold", reuseCached: false, cacheFrom: nil,
                   treeState: "initial", root: root),
            record(pass2, name: "2-light-after-mutations", reuseCached: true, cacheFrom: "1-full-cold",
                   treeState: "mutated, Locked/ unreadable", root: root),
            record(pass3, name: "3-full-after-mutations", reuseCached: false, cacheFrom: "1-full-cold",
                   treeState: "mutated, Locked/ unreadable", root: root),
            record(pass4, name: "4-light-after-unlock", reuseCached: true, cacheFrom: "1-full-cold",
                   treeState: "mutated, Locked/ readable", root: root),
        ])

        // Guard rails that would otherwise be invisible inside a big JSON blob.
        XCTAssertTrue(dump.passes[0].flatPhotos.allSatisfy(\.idMatchesStableUUIDOfPath),
                      "a photo id diverged from StableUUID.derive of its standardized path")
        XCTAssertEqual(dump.passes[1].failedDirectoryPaths, ["Locked"])
        XCTAssertEqual(dump.passes[2].failedDirectoryPaths, ["Locked"])
        XCTAssertEqual(dump.passes[3].failedDirectoryPaths, [])
        XCTAssertFalse(dump.passes[1].modifiedPaths.contains("a.jpg"),
                       "the light-scan blind spot is the point of this fixture")
        XCTAssertTrue(dump.passes[2].modifiedPaths.contains("a.jpg"),
                      "a full scan must notice a size+mtime change")

        try ConformanceFixtures.assertMatches(dump, fixture: "scanner_conformance.json")
    }

    func testCommittedFixtureIsCanonical() throws {
        try ConformanceFixtures.assertCommittedBytesAreCanonical(
            Dump.self, fixture: "scanner_conformance.json"
        )
    }

    /// The committed fixture must still carry one NFC and one NFD path.
    /// Without this, an editor or a git filter that normalized the JSON would
    /// quietly collapse the two Unicode cases — and the main comparison could
    /// not notice, because `String ==` is canonical equivalence.
    func testFixtureKeepsBothNormalizationForms() throws {
        let url = try ConformanceFixtures.root().appendingPathComponent("scanner_conformance.json")
        let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: url))
        let forms = Set(dump.passes[0].flatPhotos.map(\.pathNormalization))
        XCTAssertTrue(forms.contains("NFD"), "the NFD fixture path was normalized away")
        XCTAssertTrue(forms.contains("NFC"), "the NFC fixture path was normalized away")
        // …and the recorded token must still describe the recorded string.
        for photo in dump.passes[0].flatPhotos {
            XCTAssertEqual(Self.normalizationForm(photo.path), photo.pathNormalization,
                           "\(photo.path) no longer matches its recorded normalization form")
        }
    }

    // MARK: - Recording

    private func record(
        _ result: FolderScanner.Result,
        name: String,
        reuseCached: Bool,
        cacheFrom: String?,
        treeState: String,
        root: URL
    ) -> Pass {
        let rel = Self.relativizer(root)
        return Pass(
            name: name,
            reuseCached: reuseCached,
            cacheFrom: cacheFrom,
            treeState: treeState,
            needsEnrichment: result.needsEnrichment,
            rootFolder: result.rootFolder.map { folder($0, rel: rel) },
            flatPhotos: result.flatPhotos.map { photo($0, rel: rel) }.sorted { $0.path < $1.path },
            addedPaths: result.addedURLs.map(rel).sorted(),
            removedPaths: result.removedURLs.map(rel).sorted(),
            modifiedPaths: result.modifiedURLs.map(rel).sorted(),
            failedDirectoryPaths: result.failedDirectoryPaths.map { Self.relativize($0, root: root) }.sorted(),
            sidecarManifest: result.sidecarManifest.map { row($0, rel: rel) }.sorted { $0.photoPath < $1.photoPath },
            notes: Self.passNotes[name] ?? []
        )
    }

    private func folder(_ node: PhotoFolder, rel: (URL) -> String) -> Folder {
        let coverSource: String
        if let cover = node.coverPhotoURL {
            if node.photos.contains(where: { $0.url == cover }) {
                coverSource = "ownPhotos"
            } else if let sub = node.subfolders.first(where: { $0.coverPhotoURL == cover }) {
                coverSource = "subfolder:\(sub.name)"
            } else {
                coverSource = "unexpected"
            }
        } else {
            coverSource = "none"
        }
        return Folder(
            path: rel(node.url),
            name: node.name,
            photoCount: node.photos.count,
            photoPaths: node.photos.map { rel($0.url) }.sorted(),
            totalPhotoCount: node.totalPhotoCount,
            coverPhotoSource: coverSource,
            hasDateModified: node.dateModified != nil,
            hasDateCreated: node.dateCreated != nil,
            subfolders: node.subfolders.map { folder($0, rel: rel) }
        )
    }

    private func photo(_ p: PhotoFile, rel: (URL) -> String) -> Photo {
        Photo(
            path: rel(p.url),
            pathNormalization: Self.normalizationForm(rel(p.url)),
            filename: p.filename,
            filenameNormalization: Self.normalizationForm(p.filename),
            fileSize: p.fileSize,
            isVideo: p.isVideo,
            livePhotoVideoPath: p.livePhotoVideoURL.map(rel),
            dateTaken: ConformanceDate.utc(p.dateTaken),
            dateFromMetadata: p.dateFromMetadata,
            fileModificationDate: ConformanceDate.utc(p.fileModificationDate),
            enrichedFileDate: ConformanceDate.utc(p.enrichedFileDate),
            locality: Self.describe(p.locality),
            sidecarStatus: Self.describe(p.sidecarStatus),
            countryCode: p.countryCode,
            hierarchicalTagCount: p.hierarchicalTags.count,
            faceRegionCount: p.faceRegions.count,
            idMatchesStableUUIDOfPath: p.id == PhotoFile.stableID(for: p.url)
        )
    }

    private func row(_ candidate: FolderScanner.SidecarCandidate, rel: (URL) -> String) -> SidecarRow {
        // The manifest carries the photo *id*, not its URL; the sidecar is
        // always `<photo basename>.xmp`, so stripping the extension recovers
        // the photo path without a lookup table.
        let sidecarPath = rel(candidate.sidecarURL)
        return SidecarRow(
            photoPath: String(sidecarPath.dropLast(".xmp".count)),
            sidecarPath: sidecarPath,
            downloadStatus: "\(candidate.downloadStatus)",
            versionHasContentIdentifier: candidate.currentVersion.contentIdentifier != nil,
            versionModificationDate: ConformanceDate.utc(candidate.currentVersion.modificationDate),
            versionSize: candidate.currentVersion.size
        )
    }

    // MARK: - Helpers

    private static func describe(_ locality: PhotoLocality) -> String {
        switch locality {
        case .local: return "local"
        case .remote(let downloaded): return "remote(downloaded: \(downloaded))"
        }
    }

    private static func describe(_ status: SidecarStatus) -> String {
        switch status {
        case .absent: return "absent"
        case .cached: return "cached"
        }
    }

    /// `url.path` (not `standardizedFileURL.path`) on purpose — see
    /// `URLNormalizationTests`. `standardizedFileURL` decomposes; `path` and
    /// `standardized.path`, which is what `PhotoFile.stableID` hashes, hand
    /// back the on-disk bytes.
    private static func relativizer(_ root: URL) -> (URL) -> String {
        { url in relativize(url.path, root: root) }
    }

    /// Relative, `/`-separated path under the library root; "" for the root
    /// itself. Absolute paths never enter the fixture — they carry the temp
    /// directory's random name. Both spellings of the root are tried because
    /// `failedDirectoryPaths` is emitted through `standardizedFileURL`.
    private static func relativize(_ path: String, root: URL) -> String {
        for base in [root.path, root.standardizedFileURL.path] {
            if path == base { return "" }
            if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        }
        return path
    }

    /// Scalar-exact classification. `String ==` would answer "yes" to every
    /// question here, since it compares under canonical equivalence.
    static func normalizationForm(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        let isNFD = scalars == Array(s.decomposedStringWithCanonicalMapping.unicodeScalars)
        let isNFC = scalars == Array(s.precomposedStringWithCanonicalMapping.unicodeScalars)
        switch (isNFC, isNFD) {
        case (true, true): return "ascii"     // nothing to normalize either way
        case (true, false): return "NFC"
        case (false, true): return "NFD"
        case (false, false): return "mixed"
        }
    }
}
