import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LocalGallery

final class WidgetSnapshotExporterTests: XCTestCase {

    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    // MARK: - Fingerprint

    func testFingerprintIsStableForTheSameInputs() {
        let inputs = makeInputs()
        let a = WidgetSnapshotExporter.contentFingerprint(inputs: inputs)
        let b = WidgetSnapshotExporter.contentFingerprint(inputs: inputs)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testFingerprintChangesWhenDisplayedPhotoFieldsChange() {
        let base = makeInputs()
        let photo = base.allPhotos[0]

        var dated = photo
        dated.dateTaken = date(2020, 1, 2)
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: replacePhoto(base, dated)),
            WidgetSnapshotExporter.contentFingerprint(inputs: base)
        )

        var tagged = photo
        tagged.hierarchicalTags = [HierarchicalTag(raw: "Places/Italy")]
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: replacePhoto(base, tagged)),
            WidgetSnapshotExporter.contentFingerprint(inputs: base)
        )

        var sized = photo
        sized.fileSize = photo.fileSize + 4096
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: replacePhoto(base, sized)),
            WidgetSnapshotExporter.contentFingerprint(inputs: base),
            "source size is a freshness field"
        )

        var stamped = photo
        stamped.fileModificationDate = date(2024, 6, 1)
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: replacePhoto(base, stamped)),
            WidgetSnapshotExporter.contentFingerprint(inputs: base),
            "mtime is a freshness field"
        )
    }

    func testFingerprintChangesWhenMemoryContentChanges() {
        let base = makeInputs()
        let memory = base.memories[0]
        let cover = memory.coverPhotoID

        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: withMemory(base, titled: "Other title")),
            WidgetSnapshotExporter.contentFingerprint(inputs: base)
        )
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: withMemory(base, subtitle: "changed")),
            WidgetSnapshotExporter.contentFingerprint(inputs: base)
        )
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: withMemory(base, score: memory.score + 3)),
            WidgetSnapshotExporter.contentFingerprint(inputs: base)
        )

        let extra = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/extra.jpg"), dateTaken: date(2024, 1, 1))
        var morePhotos = base
        morePhotos = WidgetSnapshotExporter.Inputs(
            allPhotos: base.allPhotos + [extra],
            memories: [
                Memory(
                    id: memory.id, type: memory.type, title: memory.title,
                    subtitle: memory.subtitle, photoIDs: memory.photoIDs + [extra.id],
                    coverPhotoID: cover, dateRange: memory.dateRange, score: memory.score,
                    yearsAgo: memory.yearsAgo, personName: memory.personName
                )
            ],
            allTags: base.allTags,
            rootFolder: base.rootFolder,
            leafFolders: base.leafFolders,
            scheduled: base.scheduled
        )
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: morePhotos),
            WidgetSnapshotExporter.contentFingerprint(inputs: base),
            "same photo count is not enough — ordered ids are hashed"
        )
    }

    func testFingerprintIncludesFolderPathAndScheduledWindow() {
        let base = makeInputs()
        let leaf = base.leafFolders[0]
        let renamedParent = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/lib/Trips-renamed"),
            name: "Trips-renamed",
            subfolders: [leaf],
            photos: []
        )
        let moved = WidgetSnapshotExporter.Inputs(
            allPhotos: base.allPhotos,
            memories: base.memories,
            allTags: base.allTags,
            rootFolder: renamedParent,
            leafFolders: [leaf],
            scheduled: base.scheduled
        )
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: moved),
            WidgetSnapshotExporter.contentFingerprint(inputs: base),
            "pathDescription is displayed in the folder picker"
        )

        var scheduled = base.scheduled[0]
        scheduled = WidgetSnapshotExporter.ScheduledMemory(
            memory: scheduled.memory,
            validFrom: scheduled.validFrom,
            validTo: scheduled.validTo.addingTimeInterval(86400)
        )
        let shifted = WidgetSnapshotExporter.Inputs(
            allPhotos: base.allPhotos,
            memories: base.memories,
            allTags: base.allTags,
            rootFolder: base.rootFolder,
            leafFolders: base.leafFolders,
            scheduled: [scheduled]
        )
        XCTAssertNotEqual(
            WidgetSnapshotExporter.contentFingerprint(inputs: shifted),
            WidgetSnapshotExporter.contentFingerprint(inputs: base)
        )
    }

    // MARK: - Signature commit

    func testSuccessfulExportCommitsSignature() async throws {
        let temp = makeTemp()
        let photoURL = temp.appending("p.jpg")
        try writeTinyJPEG(to: photoURL)
        let inputs = makeInputs(photoURL: photoURL)
        let dest = destinations(in: temp)
        let exporter = WidgetSnapshotExporter()

        let ok = await exporter.export(inputs, destinations: dest)
        XCTAssertTrue(ok)
        let committed = await exporter.lastExportSignature
        XCTAssertEqual(committed, WidgetSnapshotExporter.contentFingerprint(inputs: inputs))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.indexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.memoriesURL.path))
    }

    /// A later export that fails while writing JSON must not delete thumbs
    /// the previous `index.json` still names, and must not replace that
    /// index. Retrying against a writable destination then succeeds.
    func testFailedJSONExportLeavesPriorSnapshotUsableAndRetrySucceeds() async throws {
        let temp = makeTemp()
        let photoA = temp.appending("a.jpg")
        try writeTinyJPEG(to: photoA)
        let firstInputs = makeInputs(photoURL: photoA)
        let dest = destinations(in: temp)
        let exporter = WidgetSnapshotExporter()

        XCTAssertTrue(await exporter.export(firstInputs, destinations: dest))
        let firstSignature = await exporter.lastExportSignature
        XCTAssertEqual(firstSignature, WidgetSnapshotExporter.contentFingerprint(inputs: firstInputs))
        let priorIndex = try Data(contentsOf: dest.indexURL)
        let priorFolders = try Data(contentsOf: dest.foldersURL)
        let priorTags = try Data(contentsOf: dest.tagsURL)
        let priorMemories = try Data(contentsOf: dest.memoriesURL)
        let photoAId = firstInputs.allPhotos[0].id.uuidString
        let priorThumb = dest.thumbsDir.appendingPathComponent(photoAId + ".jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: priorThumb.path))

        let photoB = temp.appending("b.jpg")
        try writeTinyJPEG(to: photoB)
        let secondInputs = makeInputs(photoURL: photoB)
        let failed = WidgetSnapshotExporter.Destinations(
            thumbsDir: dest.thumbsDir,
            indexURL: temp.appending("missing-parent", isDirectory: true)
                .appendingPathComponent("nope")
                .appendingPathComponent("index.json"),
            foldersURL: dest.foldersURL,
            tagsURL: dest.tagsURL,
            memoriesURL: dest.memoriesURL
        )
        XCTAssertFalse(await exporter.export(secondInputs, destinations: failed))
        XCTAssertEqual(
            await exporter.lastExportSignature, firstSignature,
            "failed export must not replace the last committed signature"
        )
        XCTAssertEqual(try Data(contentsOf: dest.indexURL), priorIndex)
        XCTAssertEqual(try Data(contentsOf: dest.foldersURL), priorFolders)
        XCTAssertEqual(try Data(contentsOf: dest.tagsURL), priorTags)
        XCTAssertEqual(try Data(contentsOf: dest.memoriesURL), priorMemories)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: priorThumb.path),
            "prior index still names this thumb; GC must not drop it on a failed export"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let surviving = try decoder.decode(WidgetIndex.self, from: Data(contentsOf: dest.indexURL))
        XCTAssertEqual(surviving.photos.map(\.id), [photoAId])

        XCTAssertTrue(await exporter.export(secondInputs, destinations: dest))
        XCTAssertNotNil(await exporter.lastExportSignature)
        let retried = try decoder.decode(WidgetIndex.self, from: Data(contentsOf: dest.indexURL))
        XCTAssertEqual(retried.photos.map(\.id), [secondInputs.allPhotos[0].id.uuidString])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.thumbsDir.appendingPathComponent(secondInputs.allPhotos[0].id.uuidString + ".jpg").path
        ))
    }

    func testFailedJSONWriteDoesNotCommitSignatureSoRetrySucceeds() async throws {
        let temp = makeTemp()
        let photoURL = temp.appending("p.jpg")
        try writeTinyJPEG(to: photoURL)
        let inputs = makeInputs(photoURL: photoURL)
        let exporter = WidgetSnapshotExporter()

        let missingParent = temp.appending("missing-parent", isDirectory: true)
            .appendingPathComponent("nope")
            .appendingPathComponent("index.json")
        let failed = WidgetSnapshotExporter.Destinations(
            thumbsDir: temp.appending("thumbs-fail", isDirectory: true),
            indexURL: missingParent,
            foldersURL: temp.appending("folders.json"),
            tagsURL: temp.appending("tags.json"),
            memoriesURL: temp.appending("memories.json")
        )
        let first = await exporter.export(inputs, destinations: failed)
        XCTAssertFalse(first)
        let afterFail = await exporter.lastExportSignature
        XCTAssertNil(afterFail, "torn export must not suppress the retry")

        let dest = destinations(in: temp)
        let second = await exporter.export(inputs, destinations: dest)
        XCTAssertTrue(second)
        let afterRetry = await exporter.lastExportSignature
        XCTAssertNotNil(afterRetry)
    }

    func testUnchangedInputsSkipRewriteOnceCommitted() async throws {
        let temp = makeTemp()
        let photoURL = temp.appending("p.jpg")
        try writeTinyJPEG(to: photoURL)
        let inputs = makeInputs(photoURL: photoURL)
        let dest = destinations(in: temp)
        let exporter = WidgetSnapshotExporter()

        XCTAssertTrue(await exporter.export(inputs, destinations: dest))
        let firstGenerated = try String(contentsOf: dest.indexURL, encoding: .utf8)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(await exporter.export(inputs, destinations: dest))
        let secondGenerated = try String(contentsOf: dest.indexURL, encoding: .utf8)
        XCTAssertEqual(firstGenerated, secondGenerated, "committed signature skips a rewrite")
    }

    // MARK: - Fixtures

    private func makeInputs(photoURL: URL = URL(fileURLWithPath: "/lib/p.jpg")) -> WidgetSnapshotExporter.Inputs {
        var photo = PhotoFile.fixture(
            url: photoURL,
            fileSize: 2048,
            dateTaken: date(2024, 3, 15),
            tags: ["People/Ada"],
            fileModificationDate: date(2024, 3, 16)
        )
        photo.fileSize = 2048
        let leaf = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/lib/Trips/Italy"),
            name: "Italy",
            photos: [photo],
            dateModified: date(2024, 3, 16)
        )
        let root = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/lib/Trips"),
            name: "Trips",
            subfolders: [leaf]
        )
        let memory = Memory(
            id: "onThisDay",
            type: .onThisDay,
            title: "This day",
            subtitle: "2024",
            photoIDs: [photo.id],
            coverPhotoID: photo.id,
            dateRange: date(2024, 3, 15)...date(2024, 3, 15),
            score: 12,
            yearsAgo: 1,
            personName: nil
        )
        let scheduled = WidgetSnapshotExporter.ScheduledMemory(
            memory: memory,
            validFrom: date(2024, 3, 16),
            validTo: date(2024, 3, 17)
        )
        return WidgetSnapshotExporter.Inputs(
            allPhotos: [photo],
            memories: [memory],
            allTags: [
                TagSuggestion(
                    id: "people/ada", displayName: "Ada", fullPath: "People/Ada",
                    namespace: "People", count: 1
                )
            ],
            rootFolder: root,
            leafFolders: [leaf],
            scheduled: [scheduled]
        )
    }

    private func replacePhoto(_ inputs: WidgetSnapshotExporter.Inputs, _ photo: PhotoFile) -> WidgetSnapshotExporter.Inputs {
        WidgetSnapshotExporter.Inputs(
            allPhotos: [photo],
            memories: inputs.memories,
            allTags: inputs.allTags,
            rootFolder: inputs.rootFolder,
            leafFolders: inputs.leafFolders,
            scheduled: inputs.scheduled
        )
    }

    private func withMemory(
        _ inputs: WidgetSnapshotExporter.Inputs,
        titled title: String? = nil,
        subtitle: String? = nil,
        score: Double? = nil
    ) -> WidgetSnapshotExporter.Inputs {
        let m = inputs.memories[0]
        let next = Memory(
            id: m.id, type: m.type, title: title ?? m.title,
            subtitle: subtitle ?? m.subtitle, photoIDs: m.photoIDs,
            coverPhotoID: m.coverPhotoID, dateRange: m.dateRange,
            score: score ?? m.score, yearsAgo: m.yearsAgo, personName: m.personName
        )
        return WidgetSnapshotExporter.Inputs(
            allPhotos: inputs.allPhotos,
            memories: [next],
            allTags: inputs.allTags,
            rootFolder: inputs.rootFolder,
            leafFolders: inputs.leafFolders,
            scheduled: inputs.scheduled
        )
    }

    private func destinations(in temp: TempDir) -> WidgetSnapshotExporter.Destinations {
        WidgetSnapshotExporter.Destinations(
            thumbsDir: temp.appending("thumbs", isDirectory: true),
            indexURL: temp.appending("index.json"),
            foldersURL: temp.appending("folders.json"),
            tagsURL: temp.appending("tags.json"),
            memoriesURL: temp.appending("memories.json")
        )
    }

    private func writeTinyJPEG(to url: URL) throws {
        let width = 8
        let height = 8
        let bytesPerPixel = 4
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xC0
            pixels[i + 1] = 0x40
            pixels[i + 2] = 0x20
            pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * bytesPerPixel, space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
