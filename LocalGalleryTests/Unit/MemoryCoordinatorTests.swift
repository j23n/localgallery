import XCTest
@testable import LocalGallery

/// The memories state machine: once-per-day gate (set only after a
/// generation completes), cache + gate persistence across instances, and
/// the hidden/visible filtering. The engine runs for real against a small
/// deterministic library; `FixedClock` pins "today".
@MainActor
final class MemoryCoordinatorTests: XCTestCase {

    /// Clock pinned to 2024-06-11 noon UTC. Fixture photos sit on the same
    /// month/day in 2019 so the onThisDay generator reliably fires.
    private let today = date(2024, 6, 11)

    private struct Harness {
        let coordinator: MemoryCoordinator
        let people: PeopleStore
        let defaults: UserDefaults
        let tmp: TempDir
        let cacheURL: URL
    }

    /// 12 photos on 2019-06-11 spaced 2 minutes apart (beyond the 60s dedup
    /// window, ≥10 after dedup → onThisDay fires), plus optional extras.
    /// Noon UTC like the clock, so `Calendar.current`'s local month/day
    /// shifts the same way for fixtures and "today" in every timezone.
    private func libraryPhotos(extra: [PhotoFile] = []) -> [PhotoFile] {
        let onThisDay = (0..<12).map { i in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/otd-\(i).jpg"),
                dateTaken: date(2019, 6, 11, 12, i * 2)
            )
        }
        return onThisDay + extra
    }

    private func makeHarness(
        photos: [PhotoFile],
        contacts: [ContactInfo] = [],
        defaults: UserDefaults? = nil,
        tmp: TempDir? = nil
    ) -> Harness {
        let defaults = defaults ?? TestUserDefaults.make()
        let tmp = tmp ?? TempDir.make()
        let cacheURL = tmp.appending("memories_cache.json")
        let clock = FixedClock(date: today)

        // The core build is async, but `photo(byID:)` — the only thing the
        // coordinator's `visible` filter reads — is populated synchronously by
        // `build`, so nothing here has to wait for it.
        let index = CoreLibraryIndex()
        index.build(allPhotos: photos)

        let people = PeopleStore(defaults: defaults, clock: clock, index: index)
        let coordinator = MemoryCoordinator(
            defaults: defaults,
            clock: clock,
            cache: JSONDiskCache(url: cacheURL, version: 1, label: "test memories"),
            index: index,
            people: people
        )
        coordinator.makeInputs = { [weak people] in
            MemoryCoordinator.GenerationInputs(
                photos: photos,
                leafFolders: [],
                contacts: contacts,
                personContactLinks: [:],
                mePersonPath: "",
                hiddenPeople: people?.hiddenPeople ?? []
            )
        }
        return Harness(coordinator: coordinator, people: people,
                       defaults: defaults, tmp: tmp, cacheURL: cacheURL)
    }

    private func cleanup(_ h: Harness) {
        TestUserDefaults.cleanup(h.defaults)
        h.tmp.teardown()
    }

    // MARK: Gate

    func testScheduledRefreshGeneratesAndSetsGateOnCompletion() async {
        let h = makeHarness(photos: libraryPhotos())
        defer { cleanup(h) }

        XCTAssertFalse(h.coordinator.hasGeneratedToday)
        await h.coordinator.runScheduledRefresh()

        XCTAssertTrue(h.coordinator.hasGeneratedToday)
        // Sorted, not in rail order: the twelve 2019 photos clear both the
        // on-this-day floor and the 5-year milestone, and which of the two
        // sorts first is the seeded jitter's business, not this test's.
        XCTAssertEqual(h.coordinator.all.map(\.id).sorted(),
                       ["onThisDay-2024-06-11", "yearsAgo-5-2024-06-11"])
    }

    func testGenerateIfNeededPublishesAndGatesEventually() async throws {
        let h = makeHarness(photos: libraryPhotos())
        defer { cleanup(h) }

        h.coordinator.generateIfNeeded()
        // The generation Task is fire-and-forget; poll briefly.
        var attempts = 0
        while !h.coordinator.hasGeneratedToday && attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        XCTAssertTrue(h.coordinator.hasGeneratedToday)
        XCTAssertFalse(h.coordinator.all.isEmpty)
    }

    func testGateAndCachePersistAcrossInstances() async {
        let h = makeHarness(photos: libraryPhotos())
        defer { cleanup(h) }
        await h.coordinator.runScheduledRefresh()
        let generated = h.coordinator.all

        // A "relaunch": fresh coordinator over the same defaults + cache file.
        // The JSONDiskCache save is debounce-free but async — give it a beat.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: h.cacheURL.path) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let relaunched = makeHarness(photos: libraryPhotos(),
                                     defaults: h.defaults, tmp: h.tmp)
        XCTAssertTrue(relaunched.coordinator.hasGeneratedToday,
                      "generated-day must survive relaunch via UserDefaults")
        XCTAssertEqual(relaunched.coordinator.all.map(\.id), generated.map(\.id),
                       "memories must reload from the disk cache")
    }

    // MARK: Visibility

    func testHiddenMemoryIsFilteredFromVisible() async {
        let h = makeHarness(photos: libraryPhotos())
        defer { cleanup(h) }
        await h.coordinator.runScheduledRefresh()
        // The library produces both an on-this-day and a 5-years-ago memory,
        // so this asserts the hidden one is subtracted rather than that the
        // list empties.
        let all = h.coordinator.all.map(\.id)
        guard let id = all.first else { return XCTFail("no memory generated") }

        XCTAssertEqual(h.coordinator.visible.map(\.id), all)
        h.coordinator.hide(id)
        XCTAssertEqual(h.coordinator.visible.map(\.id), all.filter { $0 != id })
        h.coordinator.unhide(id)
        XCTAssertEqual(h.coordinator.visible.map(\.id), all)
    }

    func testBirthdayMemoryOfHiddenPersonIsFilteredFromVisible() async {
        let alice = ContactInfo.fixture(id: "c1", givenName: "Alice", familyName: "Anderson",
                                        birthday: DateComponents(month: 6, day: 11))
        let tagged = (0..<2).map { i in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/alice-\(i).jpg"),
                dateTaken: date(2021, 2, 1, 10, i * 2),
                tags: ["People/Alice Anderson"]
            )
        }
        // No lowered-name index is passed: the core derives it from
        // `contacts` the way `ContactLinker.index` does, so Alice's tag
        // auto-matches her contact by name.
        let h = makeHarness(photos: libraryPhotos(extra: tagged), contacts: [alice])
        defer { cleanup(h) }

        await h.coordinator.runScheduledRefresh()
        let birthdayID = "birthday-People/Alice Anderson"
        XCTAssertTrue(h.coordinator.all.contains { $0.id == birthdayID },
                      "expected a birthday memory; got \(h.coordinator.all.map(\.id))")
        XCTAssertTrue(h.coordinator.visible.contains { $0.id == birthdayID })

        // Hiding the person retroactively suppresses their cached birthday
        // memory without waiting for a regeneration.
        h.people.hidePerson("People/Alice Anderson")
        XCTAssertFalse(h.coordinator.visible.contains { $0.id == birthdayID })
    }

    // MARK: Seen bookkeeping

    func testMarkSeenRecordsTheClockDate() {
        let h = makeHarness(photos: libraryPhotos())
        defer { cleanup(h) }
        h.coordinator.markSeen("onThisDay-2024-06-11")
        XCTAssertEqual(h.coordinator.seenMemoryIDs["onThisDay-2024-06-11"], today)
    }
}
