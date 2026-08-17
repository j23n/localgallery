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
    /// Scheduled ids the live run did NOT produce. Empty in every scenario
    /// since `_plans/10-widget-timezone-fix.md`; the notes on
    /// `asia-tokyo-horizon` record what it used to hold.
    let scheduledButNotGeneratedLive: [String]
}

struct ConfScheduledScenario: Codable, Equatable {
    let name: String
    let notes: [String]
    /// Provenance for the two offset fields below: the IANA zone the harness
    /// moved the process to. It is what makes the numbers legible.
    let timeZone: String
    /// `Calendar.current.timeZone.secondsFromGMT(for: today)`.
    let timeZoneOffsetSeconds: Int
    /// What `CoreMemories.horizonOffsets(for: today)` resolved — one entry per
    /// day from today, sampled at that day's local noon, two entries past the
    /// horizon so the last window can close. Recorded because the Rust crate
    /// has no zone database and `europe-berlin-dst-fallback-horizon` changes
    /// offset *inside* the horizon.
    let horizonOffsetSeconds: [Int]
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
/// `CoreMemories.generate`.
///
/// `_plans/10-widget-timezone-fix.md` then regenerated the fixture: a memory
/// id's date is the local calendar day it is about, where it used to be that
/// instant rendered in GMT. Three zone scenarios were added with it — an
/// evening behind GMT, a horizon that straddles a DST fallback, and a
/// 45-minute offset — because the original four are all DST-free and all set
/// at local noon, which is precisely where the old bug was invisible.
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

    /// The same shape a month later, for the Berlin scenario: content on the
    /// day before the 2024 fallback, on the day of it, and three days after —
    /// so the windows either side of the transition are both observable and
    /// their contiguity is a fact about the fixture rather than about the
    /// arithmetic alone.
    ///
    /// Every series sits at 10:00Z, i.e. 11:00 or 12:00 local depending on
    /// which side of a transition it falls. That margin is deliberate: the
    /// Rust conformance harness buckets fixture photos at the run's single
    /// offset while the app resolves one per photo, and a photo near midnight
    /// would land on different days under the two.
    private func octoberLibrary() -> [PhotoFile] {
        series("oct-2019", count: 12, start: MemoriesConformance.utc(2019, 10, 27, 10, 0))
            + series("oct-2020", count: 11, start: MemoriesConformance.utc(2020, 10, 26, 10, 0))
            + series("oct-2021", count: 11, start: MemoriesConformance.utc(2021, 10, 27, 10, 0))
            + series("oct-2022", count: 11, start: MemoriesConformance.utc(2022, 10, 30, 10, 0))
    }

    private func specs() -> [Spec] {
        let today = MemoriesConformance.utc(2024, 6, 8, 12, 0)
        let ada = contact("c-ada", "Ada", "Lovelace", month: 6, day: 13)
        let grace = contact("c-grace", "Grace", "Hopper", month: 12, day: 9)
        // Same person, a birthday inside the October horizon.
        let october = contact("c-ada", "Ada", "Lovelace", month: 10, day: 29)
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
                    "The zone the bug in `_plans/10-widget-timezone-fix.md` was found in. `computeScheduledMemories` walks days from local midnight; the memory id used to be rendered by an ISO8601DateFormatter pinned to GMT, and in a zone ahead of GMT local midnight belongs to the PREVIOUS GMT day. This scenario recorded the consequence: three of the seven days with an empty `matchedIDs`, and day +4 pre-publishing `onThisDay-2024-06-11` — the same id day +3's live run produced, with different photos behind it.",
                    "The id is now the local calendar day the memory is about, so both halves agree by construction and every pre-published id resolves. This scenario is the regression test for that; it is the one place the old failure was written down.",
                ],
                timeZone: "Asia/Tokyo",
                today: MemoriesConformance.utc(2024, 6, 8, 3, 0),   // 12:00 JST
                photos: calendarLibrary() + adaPhotos,
                contacts: [ada]
            ),
            Spec(
                name: "america-los-angeles-evening-horizon",
                notes: [
                    "The mirrored failure, behind GMT. The horizon was always right here — local midnight of a day is still that day in GMT — but the LIVE id rolled forward once local time passed 24−h, so from 17:00 onwards Los Angeles generated `onThisDay-<D+1>` for a memory about day D and the pre-published id for D matched nothing.",
                    "`today` is 18:00 local, and the parity block runs the live pipeline at the scenario's own hour rather than at noon. Noon is the one hour at which both halves of the bug cancel out in every zone, which is why the original four scenarios — all set at local noon — could not see this.",
                ],
                timeZone: "America/Los_Angeles",
                today: MemoriesConformance.utc(2024, 6, 9, 1, 0),   // 18:00 PDT on 06-08
                photos: calendarLibrary() + adaPhotos,
                contacts: [ada]
            ),
            Spec(
                name: "europe-berlin-dst-fallback-horizon",
                notes: [
                    "The clocks go back at 03:00 CEST on 2024-10-27, three days into this horizon. The offsets are sampled at each day's local noon, so `horizonOffsetSeconds` is +2 for days 0–2 and +1 from day 3 on, and each window opens at the midnight of ITS day rather than at the run's offset.",
                    "The two calendars in `compute_scheduled` are deliberately different: the window uses the day's own offset, the instant handed to the generators uses the run's, and the id comes from neither — it is formatted from the civil y/m/d. Collapsing them back into one reintroduces the bug on two days a year.",
                    "This is also the only scenario whose photo offsets differ from the run's: the October photos from 2019, 2020 and 2022 fall on the CET side of their year's transition. They sit at 10:00Z so the hour cannot move them onto another day.",
                    "Day +2 (the 26th, CEST) and day +3 (the 27th, CET) both carry content, so the fixture shows the 26th's `validTo` and the 27th's `validFrom` as the same instant. The horizon has no gap and no overlap across the transition — a single `now` offset would leave an hour of both.",
                ],
                timeZone: "Europe/Berlin",
                today: MemoriesConformance.utc(2024, 10, 24, 10, 0),   // 12:00 CEST
                photos: octoberLibrary() + adaPhotos,
                contacts: [october]
            ),
            Spec(
                name: "asia-kathmandu-horizon",
                notes: [
                    "A 45-minute offset. Every piece of the horizon's arithmetic is in seconds and nothing else in this fixture proves it: the windows here open at :15 past the hour, not on it.",
                    "`today` is 00:45 local, so the local day is already one ahead of the GMT one and day +2 is 2024-06-11 rather than 06-10. Both halves used to name the GMT day and therefore agreed with each other while being a day wrong — the symptom parity alone cannot catch.",
                ],
                timeZone: "Asia/Kathmandu",
                today: MemoriesConformance.utc(2024, 6, 8, 19, 0),   // 00:45 NPT on 06-09
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
        //
        // At the scenario's OWN time of day, not at noon. Noon is the one hour
        // at which a GMT-rendered id and a local calendar day agree in every
        // zone, so a parity block that only ever looked there was blind to the
        // evening failure behind GMT. Every scenario written before
        // `america-los-angeles-evening-horizon` sits at local noon, so their
        // blocks are unaffected.
        let secondsIntoDay = spec.today.timeIntervalSince(startOfToday)
        var parity: [ConfParityDay] = []
        for offset in 1...Self.horizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            let sameHour = day.addingTimeInterval(secondsIntoDay)
            let live = await CoreMemories.generate(CoreMemories.Inputs(
                photos: spec.photos,
                contacts: spec.contacts,
                personContactLinks: spec.links,
                birthdaysEnabled: spec.birthdaysEnabled,
                now: sameHour,
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
            timeZoneOffsetSeconds: cal.timeZone.secondsFromGMT(for: spec.today),
            horizonOffsetSeconds: CoreMemories.horizonOffsets(for: spec.today).map(Int.init),
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
            schema: 2,
            environment: ConfEnvironment.current(notes: [
                "Same locale caveat as memory_engine.json: subtitles are ICU-formatted.",
            ]),
            notes: [
                "Produced by LocalGalleryTests/Unit/ScheduledMemoriesConformanceTests.swift from GalleryStore.computeScheduledMemories, which since Phase 4 is the Rust core reached through CoreMemories.",
                "The horizon is offsets 1…7 from Calendar.current.startOfDay(for: clock.now()). Day 0 is excluded — it is already in memories.visible.",
                "Each item's window is [midnight(+n), midnight(+n+1)) in the offset in force ON THAT DAY, which is why `horizonOffsetSeconds` is recorded. The scheduled pass runs the SAME finalize as the daily pipeline, which is what makes the ids and the content match.",
                "Only calendar-tied types are pre-published: onThisDay, yearsAgo, birthdays. No trips, folder events or density.",
                "`parity` is the acceptance gate: day-N pre-published id == the id generated live on day N. The live half runs at the scenario's own wall-clock time, because at noon the two halves of the pre-_plans/10 id bug cancelled out in every zone.",
                "Schema 2 regenerated by _plans/10-widget-timezone-fix.md: a memory id's date is now the local calendar day it is about, where it used to be that instant rendered in GMT. Only the non-UTC scenarios moved.",
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

    /// The acceptance criterion, asserted in **every** zone since
    /// `_plans/10-widget-timezone-fix.md`. Before it, this held in UTC alone
    /// and the filter here said so.
    func testPrePublishedIDsMatchTheLiveRunOnTheirDay() async throws {
        for scenario in await dump().scenarios {
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

    /// The invariant `asia-tokyo-horizon` should always have had: an id belongs
    /// to one horizon day. Day +4 used to pre-publish the very id day +3
    /// generated live, with different photos behind it.
    func testNoTwoHorizonDaysShareAnID() async throws {
        for scenario in await dump().scenarios {
            var seen: [String: Int] = [:]
            for item in scenario.scheduled {
                if let other = seen.updateValue(item.dayOffset, forKey: item.memory.id) {
                    XCTFail("\(scenario.name): `\(item.memory.id)` is pre-published for "
                            + "both +\(other) and +\(item.dayOffset)")
                }
            }
        }
    }

    /// The offsets the fixture records are the ones the app resolves, and the
    /// table reaches two days past the horizon so the last window can close.
    /// A short table degrades to the `now` offset silently, which would hide a
    /// DST bug rather than fail on it.
    func testRecordedOffsetsAreTheOnesTheAppResolves() async throws {
        for scenario in await dump().scenarios {
            let zone = try XCTUnwrap(TimeZone(identifier: scenario.timeZone))
            let today = try XCTUnwrap(MemoriesConformance.utcFormatter.date(from: scenario.today))
            XCTAssertEqual(scenario.timeZoneOffsetSeconds, zone.secondsFromGMT(for: today),
                           scenario.name)
            XCTAssertEqual(scenario.horizonOffsetSeconds.count, Self.horizonDays + 2,
                           "\(scenario.name): one entry per horizon day plus today plus the close")
        }
    }
}
