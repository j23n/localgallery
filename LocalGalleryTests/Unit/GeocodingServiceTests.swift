import CoreLocation
import Foundation
import XCTest
@testable import LocalGallery

@MainActor
final class GeocodingServiceTests: XCTestCase {
    private func makeTemp() -> TempDir {
        let temp = TempDir.make()
        addTeardownBlock { temp.teardown() }
        return temp
    }

    /// Live lookups are paced at 1/s; tests replace `wait` so they do not
    /// actually sleep. Rate-limit tests install a recorder instead.
    private func makeService(
        _ temp: TempDir,
        cacheName: String = "geocode-cache.json",
        wait: @escaping (TimeInterval) async -> Void = { _ in }
    ) -> GeocodingService {
        let service = GeocodingService(cacheURL: temp.appending(cacheName))
        service.wait = wait
        return service
    }

    private func paris(lat: Double, lon: Double) -> GeocodingService.CacheEntry {
        GeocodingService.CacheEntry(
            latitude: lat,
            longitude: lon,
            path: "Places/France/Île-de-France/Paris",
            country: "France",
            state: "Île-de-France",
            city: "Paris",
            sublocation: nil,
            countryCode: "FR"
        )
    }

    private func networkError() -> NSError {
        NSError(domain: kCLErrorDomain, code: CLError.Code.network.rawValue)
    }

    func testEligibilityRequiresDownloadedStillWithGpsAndNoPlacesTag() throws {
        let local = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/a.jpg"),
            gps: (lat: 48.8584, lon: 2.2945)
        )
        XCTAssertTrue(GeocodingService.isEligible(local))
        XCTAssertTrue(GeocodingService.needsLibraryPlaces(local))

        let video = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/clip.mov"),
            isVideo: true,
            gps: (lat: 48.8584, lon: 2.2945)
        )
        XCTAssertFalse(GeocodingService.isEligible(video))

        var placeholder = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/cloud.jpg"),
            gps: (lat: 48.8584, lon: 2.2945)
        )
        placeholder.locality = .remote(downloaded: false)
        XCTAssertFalse(GeocodingService.isEligible(placeholder))

        let noGps = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/b.jpg"))
        XCTAssertFalse(GeocodingService.isEligible(noGps))

        let temp = makeTemp()
        let placedURL = temp.appending("placed.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: placedURL.path, contents: Data()))
        try writePlacesSidecar(at: placedURL, tags: ["Places/Italy/Lazio/Rome"])
        let alreadyPlaced = PhotoFile.fixture(
            url: placedURL,
            tags: ["Places/Italy/Lazio/Rome"],
            gps: (lat: 41.9, lon: 12.5)
        )
        XCTAssertFalse(GeocodingService.isEligible(alreadyPlaced))
        XCTAssertFalse(
            GeocodingService.needsLibraryPlaces(alreadyPlaced),
            "a library row that already carries Places/Rome is not up for Scan"
        )

        let memoryOnly = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/c.jpg"),
            tags: ["Places/Italy/Lazio/Rome"],
            gps: (lat: 41.9, lon: 12.5)
        )
        XCTAssertTrue(
            GeocodingService.isEligible(memoryOnly),
            "Places tags that are not on a sidecar do not skip the write path — a geocode will persist one"
        )
        XCTAssertFalse(
            GeocodingService.needsLibraryPlaces(memoryOnly),
            "after a rescan the Places name is on the row; Scan must not queue the whole library again"
        )

        let countryInMemory = PhotoFile.fixture(
            url: URL(fileURLWithPath: "/lib/d.jpg"),
            tags: ["Places/France"],
            gps: (lat: 48.8584, lon: 2.2945)
        )
        XCTAssertFalse(
            GeocodingService.needsLibraryPlaces(countryInMemory),
            "any Places/* name on the library row means the photo is already place-tagged"
        )

        let countryURL = temp.appending("country.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: countryURL.path, contents: Data()))
        try writePlacesSidecar(at: countryURL, tags: ["Places/France"])
        let countryOnly = PhotoFile.fixture(
            url: countryURL,
            tags: ["Places/France"],
            gps: (lat: 48.8584, lon: 2.2945)
        )
        XCTAssertTrue(
            GeocodingService.isEligible(countryOnly),
            "a country-only Places tag must stay eligible so a later pass can add the city"
        )

        XCTAssertTrue(
            GeocodingService.isEligible(alreadyPlaced, force: true),
            "force must re-geocode a photo that already has a city"
        )
        XCTAssertTrue(
            GeocodingService.needsLibraryPlaces(alreadyPlaced, force: true),
            "Drop and Rescan must put an already-placed photo back on the queue"
        )
        XCTAssertFalse(
            GeocodingService.isEligible(video, force: true),
            "force still skips videos"
        )
        XCTAssertFalse(
            GeocodingService.isEligible(placeholder, force: true),
            "force still skips undownloaded placeholders"
        )
        XCTAssertFalse(
            GeocodingService.isEligible(noGps, force: true),
            "force still skips photos without GPS"
        )
    }

    func testPlacesPathCollapsesMissingLevels() {
        XCTAssertEqual(
            GeocodingService.placesPath(
                country: "Italy",
                state: "Lazio",
                city: "Rome",
                sublocation: "Trastevere"
            ),
            "Places/Italy/Lazio/Rome/Trastevere"
        )
        XCTAssertEqual(
            GeocodingService.placesPath(
                country: "Italy",
                state: nil,
                city: "Rome",
                sublocation: nil
            ),
            "Places/Italy/Rome"
        )
        XCTAssertEqual(
            GeocodingService.placesPath(
                country: "  ",
                state: nil,
                city: "Rome",
                sublocation: nil
            ),
            "Places/Rome"
        )
        XCTAssertNil(
            GeocodingService.placesPath(
                country: nil,
                state: nil,
                city: nil,
                sublocation: nil
            )
        )
    }

    func testHaversineInsideCacheRadiusIsAHit() {
        // Two points ~30 m apart on the Champ de Mars.
        let km = GeocodingService.haversineKm(48.8584, 2.2945, 48.8586, 2.2947)
        XCTAssertLessThan(km, GeocodingService.cacheRadiusKm)
        XCTAssertGreaterThan(km, 0)
    }

    func testResolveReusesACachedLookupWithinHalfAKilometre() async throws {
        let service = makeService(makeTemp())
        var lookups = 0
        service.lookup = { lat, lon in
            lookups += 1
            if lookups == 1 {
                return GeocodingService.CacheEntry(
                    latitude: lat,
                    longitude: lon,
                    path: "Places/France/Île-de-France/Paris",
                    country: "France",
                    state: "Île-de-France",
                    city: "Paris",
                    sublocation: nil,
                    countryCode: "FR"
                )
            }
            return GeocodingService.CacheEntry(
                latitude: lat,
                longitude: lon,
                path: "Places/Italy/Lazio/Rome",
                country: "Italy",
                state: "Lazio",
                city: "Rome",
                sublocation: nil,
                countryCode: "IT"
            )
        }

        let first = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(first?.path, "Places/France/Île-de-France/Paris")

        let nearby = try await service.resolve(latitude: 48.8586, longitude: 2.2947)
        XCTAssertEqual(lookups, 1, "a second photo from the same street must not hit the geocoder")
        XCTAssertEqual(nearby?.path, first?.path)

        let far = try await service.resolve(latitude: 41.9028, longitude: 12.4964)
        XCTAssertEqual(lookups, 2)
        XCTAssertEqual(far?.country, "Italy")
    }

    func testCacheSurvivesANewServiceInstance() async throws {
        let temp = makeTemp()
        let url = temp.appending("geocode-cache.json")
        let first = GeocodingService(cacheURL: url)
        first.wait = { _ in }
        first.lookup = { lat, lon in
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
        _ = try await first.resolve(latitude: 48.8584, longitude: 2.2945)

        let second = GeocodingService(cacheURL: url)
        second.wait = { _ in }
        var lookups = 0
        second.lookup = { _, _ in
            lookups += 1
            return nil
        }
        let hit = try await second.resolve(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(lookups, 0, "the on-disk cache must satisfy a relaunch")
        XCTAssertEqual(hit?.city, "Paris")
    }

    func testWritePlacesCreatesASidecarAndASecondWriteIsANoOp() throws {
        let temp = makeTemp()
        let photo = temp.appending("a.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photo.path, contents: Data("jpeg".utf8)))

        let place = PlaceWrite(
            path: "Places/Italy/Lazio/Rome",
            country: "Italy",
            state: "Lazio",
            city: "Rome",
            sublocation: nil,
            countryCode: "IT"
        )
        XCTAssertTrue(try writePlaces(imagePath: photo.path, place: place))
        XCTAssertFalse(try writePlaces(imagePath: photo.path, place: place))

        let xml = try String(contentsOf: temp.appending("a.jpg.xmp"), encoding: .utf8)
        XCTAssertTrue(xml.contains("Places/Italy/Lazio/Rome"))
        XCTAssertTrue(xml.contains("photoshop:Country"))
        XCTAssertTrue(xml.contains("Italy"))
    }

    func testGeocodeWritesPlacesFromAnInjectedLookup() async throws {
        let temp = makeTemp()
        let photoURL = temp.appending("eiffel.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photoURL.path, contents: Data("jpeg".utf8)))
        let photo = PhotoFile.fixture(url: photoURL, gps: (lat: 48.8584, lon: 2.2945))

        let service = makeService(temp)
        service.lookup = { lat, lon in
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

        let summary = await service.geocode([photo])
        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(summary.written, 1)
        XCTAssertFalse(summary.cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appending("eiffel.jpg.xmp").path))
    }

    func testLiveLookupsArePacedAtOnePerSecond() async throws {
        let frozen = Date(timeIntervalSince1970: 1_000)
        var waited: TimeInterval = 0
        let service = makeService(makeTemp()) { waited += $0 }
        service.now = { frozen }
        service.lookup = { lat, lon in self.paris(lat: lat, lon: lon) }

        _ = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(waited, 0, "the first live lookup is free")

        _ = try await service.resolve(latitude: 41.9028, longitude: 12.4964)
        XCTAssertEqual(
            waited,
            GeocodingService.minLookupInterval,
            accuracy: 0.001,
            "a second distinct coordinate must wait out the 1s floor"
        )
    }

    func testCacheHitDoesNotConsumeTheRateLimit() async throws {
        let frozen = Date(timeIntervalSince1970: 1_000)
        var waited: TimeInterval = 0
        let service = makeService(makeTemp()) { waited += $0 }
        service.now = { frozen }
        service.lookup = { lat, lon in self.paris(lat: lat, lon: lon) }

        _ = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
        _ = try await service.resolve(latitude: 48.8586, longitude: 2.2947)
        XCTAssertEqual(waited, 0, "a street-level cache hit must not sleep")
    }

    func testNetworkThrottleIsRetriedThenSucceeds() async throws {
        let service = makeService(makeTemp())
        var calls = 0
        service.lookup = { lat, lon in
            calls += 1
            if calls < 3 { throw self.networkError() }
            return self.paris(lat: lat, lon: lon)
        }

        let hit = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(hit?.city, "Paris")
    }

    func testRetryBudgetExhaustionFailsTheLookup() async {
        let service = makeService(makeTemp())
        var calls = 0
        service.lookup = { _, _ in
            calls += 1
            throw self.networkError()
        }

        do {
            _ = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
            XCTFail("exhausted retries must throw")
        } catch {
            XCTAssertTrue(GeocodingService.isRetryable(error))
        }
        XCTAssertEqual(calls, GeocodingService.maxLookupAttempts)
    }

    func testNoResultIsNotRetried() async {
        let service = makeService(makeTemp())
        var calls = 0
        service.lookup = { _, _ in
            calls += 1
            throw NSError(domain: kCLErrorDomain, code: CLError.Code.geocodeFoundNoResult.rawValue)
        }

        do {
            _ = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
            XCTFail("a miss must surface, not be swallowed")
        } catch {
            XCTAssertFalse(GeocodingService.isRetryable(error))
        }
        XCTAssertEqual(calls, 1)
    }

    func testNilPlacemarkIsASkipNotARetry() async throws {
        let service = makeService(makeTemp())
        var calls = 0
        service.lookup = { _, _ in
            calls += 1
            return nil
        }
        let hit = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
        XCTAssertNil(hit)
        XCTAssertEqual(calls, 1)
    }

    func testIsRetryableCoversThrottleAndTransportOnly() {
        XCTAssertTrue(GeocodingService.isRetryable(networkError()))
        XCTAssertTrue(
            GeocodingService.isRetryable(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )
        )
        XCTAssertFalse(
            GeocodingService.isRetryable(
                NSError(domain: kCLErrorDomain, code: CLError.Code.geocodeFoundNoResult.rawValue)
            )
        )
        XCTAssertFalse(
            GeocodingService.isRetryable(
                NSError(domain: kCLErrorDomain, code: CLError.Code.geocodeCanceled.rawValue)
            )
        )
        XCTAssertTrue(GeocodingService.isRetryable(GeocodingService.LookupError.timedOut))
        XCTAssertFalse(GeocodingService.isRetryable(
            PlacesError.InvalidTag(tag: "Places/", reason: "Places/ with no country is not a place")
        ))
    }

    func testBackoffDoublesThenCaps() {
        XCTAssertEqual(GeocodingService.backoff(afterFailures: 1), 1)
        XCTAssertEqual(GeocodingService.backoff(afterFailures: 2), 2)
        XCTAssertEqual(GeocodingService.backoff(afterFailures: 3), 4)
        XCTAssertEqual(GeocodingService.backoff(afterFailures: 5), 16)
        XCTAssertEqual(GeocodingService.backoff(afterFailures: 8), 16)
    }

    // MARK: - City extraction

    func testPostalCityFillsInWhenLocalityIsMissing() {
        let entry = GeocodingService.place(
            from: GeocodingService.PlacemarkParts(
                country: "France",
                state: "Île-de-France",
                locality: nil,
                postalCity: "Paris",
                isoCountryCode: "FR"
            ),
            latitude: 48.8584,
            longitude: 2.2945
        )
        XCTAssertEqual(entry?.path, "Places/France/Île-de-France/Paris")
        XCTAssertEqual(entry?.city, "Paris")
        XCTAssertEqual(entry?.countryCode, "FR")
    }

    func testSubAdministrativeAreaIsTheCityWhenPostalCityIsMissingToo() {
        let entry = GeocodingService.place(
            from: GeocodingService.PlacemarkParts(
                country: "France",
                state: "Île-de-France",
                subAdministrativeArea: "Paris",
                isoCountryCode: "FR"
            ),
            latitude: 48.8584,
            longitude: 2.2945
        )
        XCTAssertEqual(entry?.city, "Paris")
        XCTAssertEqual(entry?.path, "Places/France/Île-de-France/Paris")
    }

    func testLocalityWinsOverTheFallbacks() {
        let entry = GeocodingService.place(
            from: GeocodingService.PlacemarkParts(
                country: "United States",
                state: "CA",
                subAdministrativeArea: "San Francisco County",
                locality: "San Francisco",
                postalCity: "San Francisco",
                isoCountryCode: "US"
            ),
            latitude: 37.77,
            longitude: -122.42
        )
        XCTAssertEqual(entry?.city, "San Francisco")
        XCTAssertEqual(entry?.state, "CA")
    }

    func testCityMatchingCountryOrStateIsDropped() {
        let singapore = GeocodingService.place(
            from: GeocodingService.PlacemarkParts(
                country: "Singapore",
                locality: "Singapore",
                isoCountryCode: "SG"
            ),
            latitude: 1.29,
            longitude: 103.85
        )
        XCTAssertEqual(singapore?.path, "Places/Singapore")
        XCTAssertNil(singapore?.city)

        let tokyo = GeocodingService.place(
            from: GeocodingService.PlacemarkParts(
                country: "Japan",
                state: "Tokyo",
                locality: "Tokyo",
                isoCountryCode: "JP"
            ),
            latitude: 35.68,
            longitude: 139.69
        )
        XCTAssertEqual(tokyo?.path, "Places/Japan/Tokyo")
        XCTAssertNil(tokyo?.city)
    }

    func testABareLocalityArrayCacheIsNotReused() async throws {
        let temp = makeTemp()
        let url = temp.appending("geocode-cache.json")
        let v1 = [
            GeocodingService.CacheEntry(
                latitude: 48.8584,
                longitude: 2.2945,
                path: "Places/France",
                country: "France",
                state: nil,
                city: nil,
                sublocation: nil,
                countryCode: "FR"
            )
        ]
        try JSONEncoder().encode(v1).write(to: url)
        let service = GeocodingService(cacheURL: url)
        service.wait = { _ in }
        var lookups = 0
        service.lookup = { lat, lon in
            lookups += 1
            return self.paris(lat: lat, lon: lon)
        }
        let hit = try await service.resolve(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(lookups, 1, "v1 cache rows must not block a city re-query")
        XCTAssertEqual(hit?.city, "Paris")
    }

    func testACountryOnlyPlacesTagIsExtendedWithTheCity() throws {
        let temp = makeTemp()
        let photo = temp.appending("eiffel.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photo.path, contents: Data("jpeg".utf8)))
        let countryOnly = PlaceWrite(
            path: "Places/France",
            country: "France",
            state: nil,
            city: nil,
            sublocation: nil,
            countryCode: "FR"
        )
        XCTAssertTrue(try writePlaces(imagePath: photo.path, place: countryOnly))

        let withCity = PlaceWrite(
            path: "Places/France/Île-de-France/Paris",
            country: "France",
            state: "Île-de-France",
            city: "Paris",
            sublocation: nil,
            countryCode: "FR"
        )
        XCTAssertTrue(try writePlaces(imagePath: photo.path, place: withCity))

        let xml = try String(contentsOf: temp.appending("eiffel.jpg.xmp"), encoding: .utf8)
        XCTAssertTrue(xml.contains("Places/France/Île-de-France/Paris"))
        XCTAssertFalse(xml.contains("<rdf:li>Places/France</rdf:li>"))
        XCTAssertTrue(xml.contains("photoshop:City"))
        XCTAssertTrue(xml.contains("Paris"))
    }

    func testADifferentCountryIsNotOverwritten() throws {
        let temp = makeTemp()
        let photo = temp.appending("a.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: photo.path, contents: Data("jpeg".utf8)))
        XCTAssertTrue(try writePlaces(
            imagePath: photo.path,
            place: PlaceWrite(
                path: "Places/Italy/Rome",
                country: "Italy",
                state: nil,
                city: "Rome",
                sublocation: nil,
                countryCode: "IT"
            )
        ))
        XCTAssertFalse(try writePlaces(
            imagePath: photo.path,
            place: PlaceWrite(
                path: "Places/France/Paris",
                country: "France",
                state: nil,
                city: "Paris",
                sublocation: nil,
                countryCode: "FR"
            )
        ))
        let xml = try String(contentsOf: temp.appending("a.jpg.xmp"), encoding: .utf8)
        XCTAssertTrue(xml.contains("Places/Italy/Rome"))
        XCTAssertFalse(xml.contains("Places/France/Paris"))
    }

    private func writePlacesSidecar(at image: URL, tags: [String]) throws {
        let items = tags.map { "<rdf:li>\($0)</rdf:li>" }.joined()
        let xmp = """
        <x:xmpmeta xmlns:x='adobe:ns:meta/'>
        <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
         <rdf:Description rdf:about='' xmlns:digiKam='http://www.digikam.org/ns/1.0/'>
          <digiKam:TagsList><rdf:Seq>\(items)</rdf:Seq></digiKam:TagsList>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(xmp.utf8).write(to: URL(fileURLWithPath: image.path + ".xmp"))
    }

    func testStrictPlacesPrefix() {
        XCTAssertTrue(isStrictPlacesPrefix("Places/France", of: "Places/France/Île-de-France/Paris"))
        XCTAssertTrue(isStrictPlacesPrefix("Places/France/Île-de-France", of: "Places/France/Île-de-France/Paris"))
        XCTAssertFalse(isStrictPlacesPrefix("Places/France/Paris", of: "Places/France/Île-de-France/Paris"))
        XCTAssertFalse(isStrictPlacesPrefix("Places/France", of: "Places/France"))
        XCTAssertFalse(isStrictPlacesPrefix("Places/Italy", of: "Places/France/Paris"))
    }
}
