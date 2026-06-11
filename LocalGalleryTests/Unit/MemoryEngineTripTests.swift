import XCTest
@testable import LocalGallery

/// Trip detection: home-region clustering, away-run segmentation, and the
/// pure title-composition helpers. Country-name assertions are avoided where
/// they'd depend on `Locale.current`; the Places-prefix path is asserted
/// instead.
final class MemoryEngineTripTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private let home = (lat: 52.5, lon: 13.4)   // ~Berlin
    private let away = (lat: 41.9, lon: 12.5)   // ~Rome, far outside the home bins

    /// One geo-tagged photo per distinct day at `coordinate`, starting at
    /// `start`, `stride` days apart — enough span/distinct-days to qualify a
    /// cell as home when count is high.
    private func geoRun(
        at coordinate: (lat: Double, lon: Double),
        days: Int,
        start: Date,
        prefix: String,
        tags: [String] = [],
        countryCode: String? = nil,
        strideDays: Int = 1
    ) -> [(PhotoFile, Date)] {
        (0..<days).map { i in
            let d = start.addingTimeInterval(Double(i * strideDays) * 86_400)
            let photo = PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/\(prefix)-\(i).jpg"),
                dateTaken: d,
                tags: tags,
                countryCode: countryCode,
                gps: coordinate
            )
            return (photo, d)
        }
    }

    // MARK: Home detection

    func testHomeCellQualifiesAndTripClusterDoesNot() {
        // Home: 40 distinct days spread across ~400 days (span ≥180, ≥30 days).
        let homePhotos = geoRun(at: home, days: 40, start: date(2022, 1, 1), prefix: "home", strideDays: 10)
        // Trip: 10 dense days — wide enough library that thresholds stay strict.
        let tripPhotos = geoRun(at: away, days: 10, start: date(2023, 5, 1), prefix: "trip")

        let regions = MemoryEngine.detectHomeRegions(
            in: (homePhotos + tripPhotos).sorted { $0.1 < $1.1 },
            calendar: utc
        )
        XCTAssertFalse(regions.isEmpty)
        XCTAssertTrue(regions.contains(lat: home.lat, lon: home.lon))
        XCTAssertFalse(regions.contains(lat: away.lat, lon: away.lon))
    }

    // MARK: Trip generation

    func testAwayRunProducesATripMemory() {
        let today = date(2024, 6, 11)
        let homePhotos = geoRun(at: home, days: 40, start: date(2022, 1, 1), prefix: "home", strideDays: 10)
        // 16 away photos over 4 days (4/day, hours apart — beyond the 60s
        // dedup window), in a past month so the current-month guard passes.
        var awayPhotos: [(PhotoFile, Date)] = []
        for dayOffset in 0..<4 {
            for shot in 0..<4 {
                let d = date(2023, 5, 1 + dayOffset, 9 + shot * 2)
                let photo = PhotoFile.fixture(
                    url: URL(fileURLWithPath: "/lib/away-\(dayOffset)-\(shot).jpg"),
                    dateTaken: d,
                    gps: away
                )
                awayPhotos.append((photo, d))
            }
        }

        let trips = MemoryEngine.generateTripMemories(
            from: (homePhotos + awayPhotos).sorted { $0.1 < $1.1 },
            calendar: utc,
            today: today,
            mePersonPath: ""
        )
        XCTAssertEqual(trips.count, 1)
        guard let trip = trips.first else { return }
        XCTAssertEqual(trip.type, .trip)
        XCTAssertTrue(trip.id.hasPrefix("trip-2023-5-"))
        // No country codes, no Places tags, no people → generic title.
        XCTAssertEqual(trip.title, "A trip")
        XCTAssertEqual(Set(trip.photoIDs), Set(awayPhotos.map(\.0.id)))
    }

    // MARK: Labeling helpers (pure)

    func testTripLabelPrefersSharedPlacesLeafWhenOneCountryDominates() {
        let photos = (0..<10).map { i in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/tuscany-\(i).jpg"),
                tags: ["Places/Italy/Tuscany"],
                countryCode: "IT"
            )
        }
        XCTAssertEqual(MemoryEngine.tripLabel(for: photos), "Tuscany")
    }

    func testComposeTripTitleCoversAllFourShapes() {
        XCTAssertEqual(MemoryEngine.composeTripTitle(location: "Tuscany", peopleSuffix: "Anna & Bob"),
                       "Tuscany with Anna & Bob")
        XCTAssertEqual(MemoryEngine.composeTripTitle(location: "Tuscany", peopleSuffix: nil),
                       "A trip to Tuscany")
        XCTAssertEqual(MemoryEngine.composeTripTitle(location: nil, peopleSuffix: "Anna & Bob"),
                       "A trip with Anna & Bob")
        XCTAssertEqual(MemoryEngine.composeTripTitle(location: nil, peopleSuffix: nil),
                       "A trip")
    }

    func testTripPeopleSuffixExcludesMeAndHidden() {
        let photos = (0..<4).map { i in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/people-\(i).jpg"),
                tags: ["People/Me", "People/Anna", "People/Bob"]
            )
        }
        let suffix = MemoryEngine.tripPeopleSuffix(
            for: photos,
            mePersonPath: "People/Me",
            excludedPaths: ["People/Bob"]
        )
        XCTAssertEqual(suffix, "Anna")
    }

    func testDisambiguateFirstNames() {
        // Unique first names pass through as bare first names.
        XCTAssertEqual(MemoryEngine.disambiguateFirstNames(["Anna Smith", "Bob"]),
                       ["Anna", "Bob"])
        // First-name collision with distinct last initials → "First L." form.
        XCTAssertEqual(MemoryEngine.disambiguateFirstNames(["Anna Smith", "Anna Jones"]),
                       ["Anna S.", "Anna J."])
        // Collision without usable initials falls back to bare first names.
        XCTAssertEqual(MemoryEngine.disambiguateFirstNames(["Anna", "Anna"]),
                       ["Anna", "Anna"])
    }

    func testJoinNames() {
        XCTAssertEqual(MemoryEngine.joinNames([]), "")
        XCTAssertEqual(MemoryEngine.joinNames(["Anna"]), "Anna")
        XCTAssertEqual(MemoryEngine.joinNames(["Anna", "Bob"]), "Anna & Bob")
        XCTAssertEqual(MemoryEngine.joinNames(["Anna", "Bob", "Cleo"]), "Anna, Bob & Cleo")
    }

    func testDeepestSharedPlacesPrefix() {
        let rome = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/rome.jpg"),
                                     tags: ["Places/Italy/Lazio/Rome"])
        let milan = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/milan.jpg"),
                                      tags: ["Places/Italy/Lombardy/Milan"])
        let untagged = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/untagged.jpg"))
        let bern = PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/bern.jpg"),
                                     tags: ["Places/Switzerland/Bern"])

        // Shared country; the untagged photo is skipped, not range-limiting.
        XCTAssertEqual(MemoryEngine.deepestSharedPlacesPrefix(in: [rome, milan, untagged]), ["Italy"])
        // Disjoint countries → no shared prefix.
        XCTAssertEqual(MemoryEngine.deepestSharedPlacesPrefix(in: [rome, bern]), [])
        // No Places tags at all → [].
        XCTAssertEqual(MemoryEngine.deepestSharedPlacesPrefix(in: [untagged]), [])
    }
}
