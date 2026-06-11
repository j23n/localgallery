import XCTest
@testable import LocalGallery

/// Calendar-tied generators (`generateOnThisDay` / `generateYearsAgo`) are
/// pure over their inputs — test them directly with an explicit UTC calendar
/// so assertions don't depend on the machine's timezone (the `date(...)`
/// fixture helper builds UTC dates).
final class MemoryEngineCalendarTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    /// Photos on the reference day's month/day in past years, spaced beyond
    /// the 60s dedup window so every fixture survives.
    private func onThisDayPhotos(years: [Int], month: Int, day: Int, perYear: Int = 1) -> [(PhotoFile, Date)] {
        var out: [(PhotoFile, Date)] = []
        for year in years {
            for i in 0..<perYear {
                let d = date(year, month, day, 10, i * 2) // 2-min spacing
                let photo = PhotoFile.fixture(
                    url: URL(fileURLWithPath: "/lib/otd-\(year)-\(i).jpg"),
                    dateTaken: d
                )
                out.append((photo, d))
            }
        }
        return out
    }

    func testOnThisDayIDIsDateQualifiedAndDeterministic() {
        let day = date(2024, 6, 11)
        let photos = onThisDayPhotos(years: [2019, 2020, 2021], month: 6, day: 11)
        let memory = MemoryEngine.generateOnThisDay(for: day, in: photos, calendar: utc, minPhotos: 3)
        XCTAssertNotNil(memory)
        // Date-qualified id: a constant "onThisDay" id would let one viewing
        // suppress every future day's memory via the 6-month seen-penalty.
        XCTAssertEqual(memory?.id, "onThisDay-2024-06-11")
        XCTAssertEqual(memory?.type, .onThisDay)

        // Same inputs, same day → same id (the widget's pre-published
        // scheduled memory relies on this for deep-link resolution).
        let again = MemoryEngine.generateOnThisDay(for: day, in: photos, calendar: utc, minPhotos: 3)
        XCTAssertEqual(memory?.id, again?.id)
    }

    func testOnThisDayExcludesCurrentYearAndOtherDays() {
        let day = date(2024, 6, 11)
        var photos = onThisDayPhotos(years: [2019, 2020, 2021], month: 6, day: 11)
        // Same month/day, current year — must not count toward the memory.
        photos += onThisDayPhotos(years: [2024], month: 6, day: 11)
        // Different day entirely — must not count.
        photos += onThisDayPhotos(years: [2019], month: 6, day: 12)

        let memory = MemoryEngine.generateOnThisDay(for: day, in: photos, calendar: utc, minPhotos: 3)
        XCTAssertEqual(memory?.photoIDs.count, 3)
        let included = Set(memory?.photoIDs ?? [])
        let currentYearPhoto = photos.first { utc.component(.year, from: $0.1) == 2024 }
        XCTAssertNotNil(currentYearPhoto)
        XCTAssertFalse(included.contains(currentYearPhoto!.0.id))
    }

    func testOnThisDayRespectsMinPhotosAfterDedup() {
        let day = date(2024, 6, 11)
        // Three shots within one 60s window collapse to one — below minPhotos 2.
        let base = date(2019, 6, 11, 10, 0)
        let burst = (0..<3).map { i -> (PhotoFile, Date) in
            let d = base.addingTimeInterval(Double(i) * 10)
            return (PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/burst-\(i).jpg"), dateTaken: d), d)
        }
        XCTAssertNil(MemoryEngine.generateOnThisDay(for: day, in: burst, calendar: utc, minPhotos: 2))
    }

    func testYearsAgoPicksExactMilestoneYear() {
        let day = date(2024, 6, 11)
        // 2019 = 5 years ago (a milestone); 2018 = 6 years ago (not one).
        var photos = onThisDayPhotos(years: [2019], month: 6, day: 11, perYear: 3)
        photos += onThisDayPhotos(years: [2018], month: 6, day: 11, perYear: 3)

        let memories = MemoryEngine.generateYearsAgo(for: day, in: photos, calendar: utc, minPhotos: 2)
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.id, "yearsAgo-5-2024-06-11")
        XCTAssertEqual(memories.first?.yearsAgo, 5)
        XCTAssertEqual(memories.first?.title, "On this day in 2019")
    }

    func testYearsAgoDateRangeIsAscending() {
        let day = date(2024, 6, 11)
        let photos = onThisDayPhotos(years: [2023], month: 6, day: 11, perYear: 4)
        let memories = MemoryEngine.generateYearsAgo(for: day, in: photos, calendar: utc, minPhotos: 2)
        guard let range = memories.first?.dateRange else {
            return XCTFail("expected a 1-year-ago memory with a date range")
        }
        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
    }
}
