import Foundation
import XCTest
@testable import LocalGallery

@MainActor
final class LibraryAnalysisTests: XCTestCase {
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    private func makeAnalysis(_ temp: TempDir) -> LibraryAnalysis {
        let tagging = TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true),
            bundledPackDirectory: nil,
            refresh: SidecarRefreshCoalescer(interval: TaggingService.refreshInterval)
        )
        let faces = FaceService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            refresh: SidecarRefreshCoalescer(interval: FaceService.refreshInterval)
        )
        let places = GeocodingService(cacheURL: temp.appending("geocode-cache.json"))
        return LibraryAnalysis(tagging: tagging, faces: faces, places: places)
    }

    func testStartOneWithNothingEligibleReturnsWithoutRunning() async {
        let analysis = makeAnalysis(makeTemp())
        analysis.photos = { [] }
        let photo = PhotoFile.fixture(url: URL(fileURLWithPath: "/tmp/plain.jpg"))
        await analysis.startOne(photo, phases: [.tagging, .faces, .places])
        XCTAssertFalse(analysis.isRunning)
        XCTAssertNil(analysis.lastSummary)
    }

    func testStartWithNothingToDoLeavesAnEmptySummary() async {
        let analysis = makeAnalysis(makeTemp())
        analysis.photos = { [] }
        analysis.activity.record(.place(
            url: URL(fileURLWithPath: "/tmp/last-run.jpg"),
            path: "Places/Italy/Rome",
            outcome: .written
        ))
        await analysis.start()
        XCTAssertFalse(analysis.isRunning)
        XCTAssertEqual(analysis.lastSummary, LibraryAnalysis.Summary())
        XCTAssertNil(analysis.progress)
        XCTAssertEqual(
            analysis.activity.entries.count,
            1,
            "a no-op start must keep the last run's activity"
        )
    }

    /// "Nothing to do" is the scan result. Unlabeled groups from an earlier
    /// run still have to be published — FaceService.finish() is the usual
    /// path, and this start returns before any phase runs.
    func testStartWithNothingToDoStillRefreshesClusters() async {
        let temp = makeTemp()
        let tagging = TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true),
            bundledPackDirectory: nil,
            refresh: SidecarRefreshCoalescer(interval: TaggingService.refreshInterval)
        )
        let faces = FaceService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            refresh: SidecarRefreshCoalescer(interval: FaceService.refreshInterval)
        )
        var checks = 0
        faces.ensurePackChecked = { checks += 1 }
        let places = GeocodingService(cacheURL: temp.appending("geocode-cache.json"))
        let analysis = LibraryAnalysis(tagging: tagging, faces: faces, places: places)
        analysis.photos = { [] }

        await analysis.start()

        XCTAssertEqual(analysis.lastSummary, LibraryAnalysis.Summary())
        XCTAssertEqual(checks, 1, "a no-op scan never asked faces to refresh")
    }

    func testPlacesPhaseRunsWithoutAModelPack() async throws {
        let temp = makeTemp()
        let tagging = TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true),
            bundledPackDirectory: nil,
            refresh: SidecarRefreshCoalescer(interval: TaggingService.refreshInterval)
        )
        let faces = FaceService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            refresh: SidecarRefreshCoalescer(interval: FaceService.refreshInterval)
        )
        let places = GeocodingService(cacheURL: temp.appending("geocode-cache.json"))
        places.wait = { _ in }
        places.lookup = { lat, lon in
            GeocodingService.CacheEntry(
                latitude: lat,
                longitude: lon,
                path: "Places/France/Paris",
                country: "France",
                state: nil,
                city: "Paris",
                sublocation: nil,
                countryCode: "FR"
            )
        }
        let photoURL = temp.appending("eiffel.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data("jpeg".utf8)))
        let photo = PhotoFile.fixture(url: photoURL, gps: (lat: 48.8584, lon: 2.2945))
        let run = LibraryAnalysis(tagging: tagging, faces: faces, places: places)
        run.photos = { [photo] }
        var refreshed = false
        run.onSidecarsWritten = { refreshed = true }
        run.activity.record(.place(
            url: URL(fileURLWithPath: "/tmp/old.jpg"),
            path: "Places/Old",
            outcome: .written
        ))

        await run.start()

        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.lastSummary?.places?.written, 1)
        XCTAssertNil(run.lastSummary?.tagging)
        XCTAssertNil(run.lastSummary?.faces)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appending("eiffel.jpg.xmp").path))
        XCTAssertEqual(run.activity.entries.count, 1)
        XCTAssertEqual(run.activity.entries.first?.filename, "eiffel.jpg")
        XCTAssertEqual(run.activity.entries.first?.phase, .places)
        XCTAssertEqual(run.activity.entries.first?.tags, ["Places/France/Paris"])
    }

    func testForcePlacesReconsidersAnAlreadyPlacedPhoto() async throws {
        let temp = makeTemp()
        let analysis = makeAnalysis(temp)
        let places = GeocodingService(cacheURL: temp.appending("geocode-cache.json"))
        places.wait = { _ in }
        places.lookup = { lat, lon in
            GeocodingService.CacheEntry(
                latitude: lat,
                longitude: lon,
                path: "Places/France/Paris",
                country: "France",
                state: nil,
                city: "Paris",
                sublocation: nil,
                countryCode: "FR"
            )
        }
        let tagging = TaggingService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            modelPacksDirectory: temp.appending("ModelPacks", isDirectory: true),
            bundledPackDirectory: nil,
            refresh: SidecarRefreshCoalescer(interval: TaggingService.refreshInterval)
        )
        let faces = FaceService(
            cacheDatabaseURL: temp.appending("gallery-cache.sqlite"),
            refresh: SidecarRefreshCoalescer(interval: FaceService.refreshInterval)
        )
        let run = LibraryAnalysis(tagging: tagging, faces: faces, places: places)
        let photoURL = temp.appending("rome.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data("jpeg".utf8)))
        run.photos = {
            [PhotoFile.fixture(
                url: photoURL,
                tags: ["Places/Italy/Lazio/Rome"],
                gps: (lat: 41.9, lon: 12.5)
            )]
        }

        await run.start()
        XCTAssertEqual(
            run.lastSummary,
            LibraryAnalysis.Summary(),
            "a Places name already on the library row is not the Scan work queue"
        )

        await run.start(phases: [.places], force: true)
        XCTAssertEqual(run.lastSummary?.places?.written, 1)
        XCTAssertEqual(run.lastSummary?.places?.processed, 1)
    }

    func testScanSkipsAnyPlacesNameAlreadyOnTheLibraryRow() async {
        let temp = makeTemp()
        let run = makeAnalysis(temp)
        let photoURL = temp.appending("paris.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data("jpeg".utf8)))
        run.photos = {
            [PhotoFile.fixture(
                url: photoURL,
                tags: ["Places/France/Paris"],
                gps: (lat: 48.8584, lon: 2.2945)
            )]
        }

        await run.start()
        XCTAssertEqual(
            run.lastSummary,
            LibraryAnalysis.Summary(),
            "a rescan-loaded Places/Paris name must not put the photo back up for places"
        )
    }

    func testProgressCountTextIsTheCurrentPhaseWorkQueue() {
        let start = Date()
        let progress = LibraryAnalysis.Progress(
            phase: .faces,
            done: 5,
            total: 10,
            overallDone: 5,
            overallTotal: 20_592,
            startedAt: start
        )
        XCTAssertEqual(progress.shortLabel, "Faces")
        XCTAssertEqual(progress.label, "Finding faces…")
        XCTAssertEqual(
            progress.countText,
            "5 / 10",
            "the bar is photos that still need this pass, not the whole library"
        )
        XCTAssertNil(
            LibraryAnalysis.Progress(
                phase: .tagging,
                done: 0,
                total: 0,
                overallDone: 0,
                overallTotal: 0,
                startedAt: start
            ).countText,
            "no count until the engine has sized the work queue"
        )
    }
}
