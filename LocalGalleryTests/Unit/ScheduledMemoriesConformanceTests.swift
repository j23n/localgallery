import XCTest
@testable import LocalGallery

// MARK: - Fixture shape

struct ConfScheduledItem: Codable, Equatable {
    /// 1…7. `computeScheduledMemories` deliberately skips day 0 — today is
    /// already in `memories.visible`.
    let dayOffset: Int
    let validFrom: String
    let validTo: String
    let memory: ConfMemory
}

/// The finalize-path invariant: a memory pre-published for day N must carry
/// the same id — and the same content — as the one the app generates live on
/// day N. Widget deep links resolve by id, so a drift here is a dead tap.
struct ConfParityDay: Codable, Equatable {
    let dayOffset: Int
    let scheduledIDs: [String]
    let liveGeneratedIDs: [String]
    let matchedIDs: [String]
    /// Every matched id compares equal on title, subtitle, ordered photo ids,
    /// cover and score.
    let contentIdenticalForMatchedIDs: Bool
    /// Scheduled ids the live run did NOT produce. Expected to be empty in the
    /// UTC scenarios; see the notes for the case where it is not.
    let scheduledButNotGeneratedLive: [String]
}

struct ConfScheduledScenario: Codable, Equatable {
    let name: String
    let notes: [String]
    let timeZone: String
    let today: String
    let horizonDays: Int
    let photos: [ConfPhoto]
    let contacts: [ConfContact]
    let personContactLinks: [ConfLink]
    let birthdaysEnabled: Bool
    let scheduled: [ConfScheduledItem]
    let parity: [ConfParityDay]
}

struct ConfScheduledDump: Codable, Equatable {
    let schema: Int
    let environment: ConfEnvironment
    let notes: [String]
    let scenarios: [ConfScheduledScenario]
}

// MARK: - Harness

/// `GalleryStore.computeScheduledMemories` over a 7-day horizon, plus the
/// day-N parity check the widget pipeline depends on.
///
/// The scheduled pass is the *other* caller of the calendar generators and of
/// `finalize`, and it is the one `_plans/06-performance-baseline.md`
/// Finding 3 is about. The fixture pins its OUTPUT — per day, the memories and
/// their validity windows — and says nothing about how it gets there, so the
/// port is free to (and does) group people→photos once per call, early-exit on
/// days with no birthdays, and run off the main thread.
///
/// Since Phase 4 step 4 the harness drives the Rust core:
/// `GalleryStore.computeScheduledMemories` is now an `async` call into
/// `CoreMemories.computeScheduled`, and the live-run comparison goes through
/// `CoreMemories.generate`. The fixture and every assertion are unchanged.
@MainActor
final class ScheduledMemoriesConformanceTests: XCTestCase {

    private static let fixtureName = "scheduled_memories.json"
    private static let horizonDays = 7

    private struct Spec {
        var name: String
        var notes: [String]
        var timeZone: String = "UTC"
        var today: Date
        var photos: [PhotoFile]
        var contacts: [ContactInfo] = []
        var links: [String: PersonLink] = [:]
        var birthdaysEnabled: Bool = true
    }

    // MARK: Library

    private func series(
        _ prefix: String, count: Int, start: Date,
        stepSeconds: TimeInterval = 120, tags: [String] = []
    ) -> [PhotoFile] {
        (0..<count).map { i in
            confPhoto("/fixtures/lib/\(prefix)-\(i).jpg",
                      date: start.addingTimeInterval(Double(i) * stepSeconds),
                      tags: tags)
        }
    }

    private func contact(_ id: String, _ given: String, _ family: String, month: Int, day: Int) -> ContactInfo {
        ContactInfo(id: id, givenName: given, familyName: family,
                    birthday: DateComponents(month: month, day: day))
    }

    /// Calendar-tied content on 2024-06-11 (offset +3 from the 06-08 clock)
    /// and on 2024-06-14 (offset +6), so the horizon has both a populated and
    /// an empty stretch.
    private func calendarLibrary() -> [PhotoFile] {
        series("otd-2019", count: 12, start: MemoriesConformance.utc(2019, 6, 11, 12, 0))
            + series("otd-2021", count: 11, start: MemoriesConformance.utc(2021, 6, 11, 15, 0))
            + series("otd-2023", count: 11, start: MemoriesConformance.utc(2023, 6, 14, 9, 0))
    }

    private func specs() -> [Spec] {
        let today = MemoriesConformance.utc(2024, 6, 8, 12, 0)
        let ada = contact("c-ada", "Ada", "Lovelace", month: 6, day: 13)
        let grace = contact("c-grace", "Grace", "Hopper", month: 12, day: 9)
        let adaPhotos = series("ada", count: 4, start: MemoriesConformance.utc(2022, 1, 4, 10, 0),
                               stepSeconds: 86_400, tags: ["People/Ada Lovelace"])

        return [
            Spec(
                name: "no-birthday-in-the-horizon",
                notes: [
                    "Grace's birthday (12-09) is outside the 06-09…06-15 window, so not one of the seven days produces a birthday memory. This is the common case and the one Finding 3 says must cost ~nothing: the person→photo grouping is day-independent, and today it runs seven times anyway.",
                    "The photo work still happens on every day of the horizon — only the birthday branch is empty. A port that early-exits must early-exit on the BIRTHDAY check, not on the day.",
                ],
                today: today,
                photos: calendarLibrary() + adaPhotos,
                contacts: [grace]
            ),
            Spec(
                name: "birthday-mid-horizon",
                notes: [
                    "Ada's birthday lands on 2024-06-13, offset +5. Exactly one of the seven days produces a birthday memory; the other six are the early-exit case.",
                    "Birthday memories are built from ALL photos rather than the (month, day) bucket, so they are the one scheduled item whose cost is proportional to the whole library.",
                ],
                today: today,
                photos: calendarLibrary() + adaPhotos,
                contacts: [ada, grace]
            ),
            Spec(
                name: "birthdays-toggle-off",
                notes: ["With the toggle off the birthday branch is skipped entirely, so 06-13 looks exactly like the other six days."],
                today: today,
                photos: calendarLibrary() + adaPhotos,
                contacts: [ada],
                birthdaysEnabled: false
            ),
            Spec(
                name: "asia-tokyo-horizon",
                notes: [
                    "Non-UTC horizon. `computeScheduledMemories` walks days from `Calendar.current.startOfDay(for: now)` — local midnight — while the memory ID is rendered by an ISO8601DateFormatter pinned to GMT. In a zone ahead of GMT the local midnight belongs to the PREVIOUS GMT day, so the scheduled id can name a different date than the one the live run on that day produces.",
                    "Whatever `parity` records here is the shipped behaviour, not an aspiration. Read it before changing anything about the id format.",
                ],
                timeZone: "Asia/Tokyo",
                today: MemoriesConformance.utc(2024, 6, 8, 3, 0),   // 12:00 JST
                photos: calendarLibrary() + adaPhotos,
                contacts: [ada]
            ),
        ]
    }

    // MARK: Runner

    private func run(_ spec: Spec) async -> ConfScheduledScenario {
        let harness = TestGalleryStore.make(clock: FixedClock(date: spec.today), contacts: spec.contacts)
        defer { harness.teardown() }
        let store = harness.store
        await store.loadContacts()
        store.personContactLinks = spec.links
        store.memories.birthdaysEnabled = spec.birthdaysEnabled
        store.apply(.scanResult(photos: spec.photos, root: nil, persistCache: false))

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: spec.today)
        let scheduled = await store.computeScheduledMemories(photos: spec.photos)

        let items: [ConfScheduledItem] = scheduled.map { item in
            let offset = cal.dateComponents([.day], from: startOfToday, to: item.validFrom).day ?? -1
            return ConfScheduledItem(
                dayOffset: offset,
                validFrom: MemoriesConformance.iso(item.validFrom),
                validTo: MemoriesConformance.iso(item.validTo),
                memory: ConfMemory(item.memory)
            )
        }

        // Parity: run the *live* pipeline on each horizon day and compare.
        var parity: [ConfParityDay] = []
        for offset in 1...Self.horizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: startOfToday),
                  let noon = cal.date(byAdding: .hour, value: 12, to: day) else { continue }
            let live = await CoreMemories.generate(CoreMemories.Inputs(
                photos: spec.photos,
                contacts: spec.contacts,
                personContactLinks: spec.links,
                birthdaysEnabled: spec.birthdaysEnabled,
                now: noon,
                seed: WidgetDayKey.string(for: day)
            ))
            let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, ConfMemory($0)) })
            let scheduledForDay = items.filter { $0.dayOffset == offset }
            let matched = scheduledForDay.filter { liveByID[$0.memory.id] != nil }
            parity.append(ConfParityDay(
                dayOffset: offset,
                scheduledIDs: scheduledForDay.map(\.memory.id),
                liveGeneratedIDs: live.map(\.id),
                matchedIDs: matched.map(\.memory.id),
                contentIdenticalForMatchedIDs: matched.allSatisfy { liveByID[$0.memory.id] == $0.memory },
                scheduledButNotGeneratedLive: scheduledForDay
                    .filter { liveByID[$0.memory.id] == nil }
                    .map(\.memory.id)
            ))
        }

        let links: [ConfLink] = spec.links.keys.sorted().map { path in
            switch spec.links[path] {
            case .manual(let id): return ConfLink(personPath: path, kind: "manual", contactID: id)
            case .disabled, nil:  return ConfLink(personPath: path, kind: "disabled", contactID: nil)
            }
        }

        return ConfScheduledScenario(
            name: spec.name,
            notes: spec.notes,
            timeZone: spec.timeZone,
            today: MemoriesConformance.iso(spec.today),
            horizonDays: Self.horizonDays,
            photos: spec.photos.map(ConfPhoto.init),
            contacts: spec.contacts.map(ConfContact.init),
            personContactLinks: links,
            birthdaysEnabled: spec.birthdaysEnabled,
            scheduled: items,
            parity: parity
        )
    }

    private func dump() async -> ConfScheduledDump {
        var scenarios: [ConfScheduledScenario] = []
        for spec in specs() {
            // Inline rather than `MemoriesConformance.withTimeZone`: the
            // closure would have to carry a non-Sendable @MainActor body
            // across an async call, which strict concurrency (rightly) refuses.
            let previous = NSTimeZone.default
            NSTimeZone.default = TimeZone(identifier: spec.timeZone) ?? previous
            scenarios.append(await run(spec))
            NSTimeZone.default = previous
        }
        return ConfScheduledDump(
            schema: 1,
            environment: ConfEnvironment.current(notes: [
                "Same locale caveat as memory_engine.json: subtitles are ICU-formatted.",
            ]),
            notes: [
                "Produced by LocalGalleryTests/Unit/ScheduledMemoriesConformanceTests.swift from the shipping Swift GalleryStore.computeScheduledMemories, BEFORE the Rust port.",
                "The horizon is offsets 1…7 from Calendar.current.startOfDay(for: clock.now()). Day 0 is excluded — it is already in memories.visible.",
                "Each item's window is [startOfDay(+n), startOfDay(+n+1)). The scheduled pass runs the SAME MemoryEngine.finalize as the daily pipeline, which is what makes the ids and the content match.",
                "Only calendar-tied types are pre-published: onThisDay, yearsAgo, birthdays. No trips, folder events or density.",
                "`parity` is the acceptance gate from the plan: day-N pre-published id == the id generated live on day N.",
            ],
            scenarios: scenarios
        )
    }

    // MARK: Tests

    func testScheduledMemoriesMatchTheCommittedFixture() async throws {
        try ConformanceFixtures.assertMatches(
            await dump(), fixture: Self.fixtureName, in: MemoriesConformance.directory
        )
    }

    func testCommittedFixtureIsCanonical() throws {
        try ConformanceFixtures.assertCommittedBytesAreCanonical(
            ConfScheduledDump.self, fixture: Self.fixtureName, in: MemoriesConformance.directory
        )
    }

    /// The plan's acceptance criterion, asserted rather than merely recorded —
    /// for the UTC scenarios, where the id's GMT rendering and the local day
    /// agree.
    func testPrePublishedIDsMatchTheLiveRunOnTheirDay() async throws {
        for scenario in await dump().scenarios where scenario.timeZone == "UTC" {
            for day in scenario.parity {
                XCTAssertTrue(
                    day.contentIdenticalForMatchedIDs,
                    "\(scenario.name) day +\(day.dayOffset): a pre-published memory differs from the live one"
                )
                XCTAssertEqual(
                    day.scheduledButNotGeneratedLive, [],
                    "\(scenario.name) day +\(day.dayOffset): pre-published ids the live run never produces"
                )
            }
            let populated = scenario.parity.filter { !$0.scheduledIDs.isEmpty }
            XCTAssertFalse(populated.isEmpty, "\(scenario.name) pre-published nothing at all")
        }
    }

    /// The horizon shape itself: seven days, day 0 excluded, windows contiguous.
    func testHorizonShape() async throws {
        for scenario in await dump().scenarios {
            XCTAssertEqual(scenario.parity.map(\.dayOffset), Array(1...Self.horizonDays))
            for item in scenario.scheduled {
                XCTAssertTrue((1...Self.horizonDays).contains(item.dayOffset),
                              "\(scenario.name): day 0 must not be pre-published")
                XCTAssertLessThan(item.validFrom, item.validTo)
                XCTAssertTrue(["onThisDay", "yearsAgo", "birthday"].contains(item.memory.type),
                              "\(scenario.name): only calendar-tied types are pre-published")
            }
        }
    }
}
