import XCTest
@testable import LocalGallery

/// The memory engine over a set of synthetic libraries, dumped as JSON.
///
/// The fixture was produced from the shipping **Swift** `MemoryEngine` before
/// the port; since Phase 4 step 4 this harness drives the **Rust core** through
/// `CoreMemories.generate` instead, and the assertions below are unchanged. A
/// green run therefore means the FFI path reproduces the deleted Swift engine
/// scenario for scenario, which is the exit criterion of the phase.
///
/// This is the Phase-4 spec: `_plans/05-phase-4-indexes-memories.md` §1. Every
/// scenario records the *complete* input snapshot (`MemoryCoordinator
/// .GenerationInputs` plus the clock, seed, seen/cool-down state and the
/// process time zone) and the *complete* selected output, so the Rust port can
/// be driven from the same numbers rather than from a reading of the Swift.
///
/// Two things this file is careful about:
///
///  - **Scores are pinned, not just selections.** `Memory.score` is the score
///    *before* the daily jitter, and it survives into the output, so a port
///    that gets the ladder wrong fails here even when its selection happens to
///    agree. The jitter itself is never stored on a `Memory`; what it does
///    observably is order the list, which is pinned as array order.
///  - **No scenario may depend on Swift `Dictionary` iteration order.** Two
///    stages of the engine walk dictionaries (`generateBirthdayMemories`'s
///    person bundles, the density loop's day buckets), and Swift's `Hasher` is
///    seeded per process, so candidate *order* out of those loops is not
///    reproducible — and candidate order decides which jitter draw each
///    candidate receives. Every scenario below is built so at most one memory
///    comes out of each of those two loops. `testScenariosAreOrderStable`
///    re-runs every scenario and fails if one is not reproducible.
final class MemoryEngineConformanceTests: XCTestCase {

    private static let fixtureName = "memory_engine.json"

    // MARK: - Scenario definition

    private struct ScenarioSpec {
        var name: String
        var notes: [String]
        var timeZone: String = "UTC"
        var now: Date = MemoriesConformance.utc(2024, 6, 11, 12, 0)
        var seed: String = "2024-06-11"
        var birthdaysEnabled: Bool = true
        var mePersonPath: String = ""
        var hiddenPeople: Set<String> = []
        var photos: [PhotoFile] = []
        var leafFolders: [PhotoFolder] = []
        var contacts: [ContactInfo] = []
        var links: [String: PersonLink] = [:]
        var seen: [String: Date] = [:]
        var surfaced: [String: Date] = [:]
    }

    // MARK: - Library builders

    /// `count` photos starting at `start`, `stepSeconds` apart. The step is
    /// what decides whether `dedupByTimeWindow` (60 s) keeps them.
    private func series(
        _ prefix: String,
        count: Int,
        start: Date,
        stepSeconds: TimeInterval = 120,
        tags: [String] = [],
        countryCode: String? = nil,
        gps: (lat: Double, lon: Double)? = nil
    ) -> [PhotoFile] {
        (0..<count).map { i in
            confPhoto(
                "/fixtures/lib/\(prefix)-\(i).jpg",
                date: start.addingTimeInterval(Double(i) * stepSeconds),
                tags: tags,
                countryCode: countryCode,
                gps: gps
            )
        }
    }

    private func folder(_ name: String, path: String, photos: [PhotoFile]) -> PhotoFolder {
        PhotoFolder.fixture(url: URL(fileURLWithPath: path), name: name, photos: photos)
    }

    /// The 12-photo "on this day" core several scenarios share: 2019-06-11,
    /// 2 minutes apart, so it survives the dedup window and clears
    /// `minOnThisDayPhotos` (10).
    private func onThisDayCore() -> [PhotoFile] {
        series("otd", count: 12, start: MemoriesConformance.utc(2019, 6, 11, 12, 0))
    }

    private func contact(_ id: String, _ given: String, _ family: String, month: Int?, day: Int?) -> ContactInfo {
        ContactInfo(
            id: id, givenName: given, familyName: family,
            birthday: month.map { DateComponents(month: $0, day: day) }
        )
    }

    // MARK: - The trip library

    /// Berlin "home" (60 photos, one a day, spanning 18 months) plus a
    /// 40-photo Argentina→Chile trip. Sized so `detectHomeRegions` actually
    /// fires (span ≥ 180 d and ≥ 17 distinct days in one 0.1° cell) rather
    /// than falling through to the global-median fallback.
    private func tripLibrary() -> [PhotoFile] {
        var out: [PhotoFile] = []
        let homeStart = MemoriesConformance.utc(2022, 1, 5, 12, 0)
        for i in 0..<60 {
            out.append(confPhoto(
                "/fixtures/lib/home-\(i).jpg",
                date: homeStart.addingTimeInterval(Double(i) * 9 * 86_400),  // every 9 days
                countryCode: "DE",
                gps: (52.52, 13.40)
            ))
        }
        // 8 days away: 4 in Argentina, then 4 in Chile, 5 photos a day at
        // 10:00…14:00 so no gap exceeds the 48 h trip-split threshold.
        var index = 0
        for day in 0..<8 {
            let country = day < 4 ? "AR" : "CL"
            let coords = day < 4 ? (-34.60, -58.38) : (-33.45, -70.67)
            let place = day < 4 ? "Places/Argentina/Buenos Aires" : "Places/Chile/Santiago"
            for hour in 10...14 {
                var tags = [place]
                // People/* on the trip: pins the "with <names>" suffix, the
                // me-exclusion, and that person tags without contacts produce
                // no birthday memory.
                tags.append("People/Self")
                if index % 3 == 0 { tags.append("People/Anna Meyer") }
                if index % 4 == 0 { tags.append("People/Ben Meyer") }
                out.append(confPhoto(
                    "/fixtures/lib/trip-\(index).jpg",
                    date: MemoriesConformance.utc(2023, 9, 1 + day, hour, 0),
                    tags: tags,
                    countryCode: country,
                    gps: (coords.0, coords.1)
                ))
                index += 1
            }
        }
        return out
    }

    // MARK: - Scenarios

    private func scenarios() -> [ScenarioSpec] {
        var out: [ScenarioSpec] = []

        out.append(ScenarioSpec(
            name: "empty-library",
            notes: ["The engine itself tolerates an empty library — the once-per-day gate that skips it lives in MemoryCoordinator, which stays in Swift."],
            photos: []
        ))

        out.append(ScenarioSpec(
            name: "on-this-day-and-years-ago-overlap",
            notes: [
                "One photo set feeds TWO memories: onThisDay (any past year) and yearsAgo-5 (2019 exactly). They are not mutually exclusive and they are not one cluster.",
                "onThisDay score = 50 + 5 × distinct years = 55. yearsAgo score = 40 for milestones 5..9.",
            ],
            photos: onThisDayCore()
        ))

        out.append(ScenarioSpec(
            name: "years-ago-milestone-ladder",
            notes: [
                "Milestones are exactly [1, 2, 3, 5, 10, 15, 20]. The 2018 set (6 years ago) produces nothing, which is the point of including it.",
                "Score bands: 35 below 5 years, 40 for 5..9, 45 for 10 and up.",
                "onThisDay counts DISTINCT YEARS, not photos: four years present → 50 + 20 = 70.",
            ],
            photos: series("y1", count: 11, start: MemoriesConformance.utc(2023, 6, 11, 12, 0))
                + series("y3", count: 11, start: MemoriesConformance.utc(2021, 6, 11, 12, 0))
                + series("y6", count: 11, start: MemoriesConformance.utc(2018, 6, 11, 12, 0))
                + series("y10", count: 11, start: MemoriesConformance.utc(2014, 6, 11, 12, 0))
        ))

        // --- folder events -------------------------------------------------
        let fA = series("famA", count: 16, start: MemoriesConformance.utc(2023, 2, 1, 9, 0), stepSeconds: 3 * 3600)
        let fB = series("famB", count: 18, start: MemoriesConformance.utc(2023, 3, 5, 9, 0), stepSeconds: 6 * 3600)
        let fC = series("famC", count: 20, start: MemoriesConformance.utc(2023, 4, 10, 9, 0), stepSeconds: 90 * 60)
        out.append(ScenarioSpec(
            name: "folder-events",
            notes: [
                "Folder events need ≥15 dated photos after dedup and a last date outside the current month+year.",
                "Score = 10 + min(daySpan, 14); the cover is photos[count / 3], not the middle.",
                "Photo order inside a folder memory is date-ascending after dedup, regardless of the folder's own order.",
            ],
            photos: fA + fB + fC,
            leafFolders: [
                folder("February", path: "/fixtures/lib/February", photos: fA),
                folder("March", path: "/fixtures/lib/March", photos: fB),
                folder("April", path: "/fixtures/lib/April", photos: fC),
            ]
        ))

        let dupSmall = series("dupS", count: 16, start: MemoriesConformance.utc(2023, 5, 2, 9, 0), stepSeconds: 3 * 3600)
        let dupLarge = series("dupL", count: 22, start: MemoriesConformance.utc(2023, 7, 4, 9, 0), stepSeconds: 3 * 3600)
        out.append(ScenarioSpec(
            name: "folder-name-dedupe-keeps-the-biggest",
            notes: [
                "Two leaf folders with the same NAME collapse to one memory — the one with more photos wins, compared after finalize (i.e. after the 75-photo cap).",
                "The comparison key is title.lowercased(), so 'Unsorted' and 'unsorted' are the same folder for this purpose.",
            ],
            photos: dupSmall + dupLarge,
            leafFolders: [
                folder("Unsorted", path: "/fixtures/lib/a/Unsorted", photos: dupSmall),
                folder("unsorted", path: "/fixtures/lib/b/unsorted", photos: dupLarge),
            ]
        ))

        // --- density -------------------------------------------------------
        var densityPhotos = series("dense", count: 40, start: MemoriesConformance.utc(2022, 3, 5, 8, 0))
        for day in 0..<5 {
            densityPhotos += series("sparse-\(day)", count: 2,
                                    start: MemoriesConformance.utc(2022, 4, 3 + day, 10, 0))
        }
        out.append(ScenarioSpec(
            name: "photo-density-single-busy-day",
            notes: [
                "Threshold = max(15, Int(avgPhotosPerDay × 3)) where the average is over days that HAVE photos, not calendar days. Here 50 photos / 6 days = 8.33 → 24.",
                "The id is 'density-<year>-<month>-<day>' with NO zero padding — unlike the onThisDay ids, which are ISO.",
                "Exactly one day qualifies on purpose: the density loop walks a Dictionary, so two qualifying days would make candidate order (and therefore jitter assignment) depend on Swift's per-process hash seed.",
            ],
            photos: densityPhotos
        ))

        // --- trips ---------------------------------------------------------
        out.append(ScenarioSpec(
            name: "trip-with-subtrips-cluster-uniqueness",
            notes: [
                "Home is detected (not the global-median fallback): the Berlin 0.1° cell spans 531 days over 60 distinct days, clearing min(180, max(30, totalSpan/2)) and min(30, max(10, distinctDays/4)).",
                "A trip parent and its sub-trips share the cluster 'trip-<key>', so only ONE of the three survives selection. The other two are generated and discarded — that is what makes them invisible here.",
                "Trip title: two countries at 50/50 defeat the 90% dominance rule, so the label is 'A & B' ordered by count desc then code asc; the 'with …' suffix drops mePersonPath and reduces names to first names.",
                "Sub-trips split on country because ≥2 countries are present; the segment key is the lowercased country code.",
            ],
            mePersonPath: "People/Self",
            photos: tripLibrary()
        ))

        let coolFolder = series("nov", count: 16, start: MemoriesConformance.utc(2023, 11, 1, 9, 0), stepSeconds: 30 * 3600)
        out.append(ScenarioSpec(
            name: "trip-parent-seen-penalty-promotes-a-subtrip",
            notes: [
                "seenMemoryIDs applies −30 to a memory seen within 6 months of `now`. Here it drops the trip parent below its own sub-trips, so a sub-trip takes the shared cluster instead — the penalty changing the *selection*, not just the order.",
                "The penalty is keyed by memory id, so it lands on the parent alone; the cool-down (below) is keyed by cluster and lands on all three.",
            ],
            mePersonPath: "People/Self",
            photos: tripLibrary(),
            seen: ["trip-2023-9-1": MemoriesConformance.utc(2024, 5, 1, 12, 0)]
        ))

        out.append(ScenarioSpec(
            name: "trip-cluster-cooldown-penalty",
            notes: [
                "surfacedClusters applies −25 to every member of a cluster surfaced in the last 3 days. All three trip memories sink, and the folder event (score 24) overtakes them.",
                "The cool-down window is `> now − 3 days`, evaluated with Calendar.current — a scenario in a different time zone can land on the other side of it.",
            ],
            mePersonPath: "People/Self",
            photos: tripLibrary() + coolFolder,
            leafFolders: [folder("November", path: "/fixtures/lib/November", photos: coolFolder)],
            surfaced: ["trip-2023-9-1": MemoriesConformance.utc(2024, 6, 10, 12, 0)]
        ))

        // --- birthdays -----------------------------------------------------
        let alice = contact("c-alice", "Alice", "Anderson", month: 6, day: 11)
        let bob = contact("c-bob", "Bob", "Brown", month: 9, day: 2)
        var alicePhotos = series("alice", count: 5,
                                 start: MemoriesConformance.utc(2021, 2, 1, 10, 0),
                                 stepSeconds: 86_400,
                                 tags: ["People/Alice Anderson"])
        alicePhotos.append(confPhoto("/fixtures/lib/alice-undated.jpg", tags: ["People/Alice Anderson"]))
        let bobPhotos = series("bob", count: 3,
                               start: MemoriesConformance.utc(2022, 3, 1, 10, 0),
                               stepSeconds: 86_400,
                               tags: ["People/Bob Brown"])

        out.append(ScenarioSpec(
            name: "birthday-today-with-an-undated-photo",
            notes: [
                "Birthdays score 100 — far enough above onThisDay (55) that the 0–12 jitter can never reorder them.",
                "Bob's contact exists and has a birthday on a different day, so his bundle is built and discarded. Exactly one birthday memory comes out of the person-bundle Dictionary, so the fixture stays order-stable.",
                "Undated photos sort to the FRONT (distantPast) and the cover is ids.last — i.e. the most recent dated photo. The dateRange spans only the dated photos, so one undated photo cannot collapse the subtitle.",
                "Birthday memories draw from allPhotos, not from photosWithDates: an undated photo is in the memory even though it is invisible to every other generator.",
            ],
            photos: onThisDayCore() + alicePhotos + bobPhotos,
            contacts: [alice, bob]
        ))

        out.append(ScenarioSpec(
            name: "birthday-links-manual-disabled-hidden",
            notes: [
                "Three person tags, three outcomes: `.disabled` skips the tag outright; a hidden person is skipped before the link is even consulted; `.manual` wins over the name auto-match — and the title still uses the TAG's display name, not the contact's.",
                "Carol's contact would auto-match by name and shares today's birthday; the `.disabled` entry is what suppresses her.",
                "Only one memory survives, again so the person-bundle Dictionary order cannot matter.",
            ],
            hiddenPeople: ["People/Erin Hidden"],
            photos: series("carol", count: 3, start: MemoriesConformance.utc(2021, 4, 1, 10, 0),
                           stepSeconds: 86_400, tags: ["People/Carol Clark"])
                + series("erin", count: 3, start: MemoriesConformance.utc(2021, 5, 1, 10, 0),
                         stepSeconds: 86_400, tags: ["People/Erin Hidden"])
                + series("dave", count: 4, start: MemoriesConformance.utc(2021, 6, 1, 10, 0),
                         stepSeconds: 86_400, tags: ["People/Dave"]),
            contacts: [
                contact("c-carol", "Carol", "Clark", month: 6, day: 11),
                contact("c-erin", "Erin", "Hidden", month: 6, day: 11),
                contact("c-dan", "Daniel", "Nomatch", month: 6, day: 11),
            ],
            links: [
                "People/Carol Clark": .disabled,
                "People/Dave": .manual(contactID: "c-dan"),
            ]
        ))

        out.append(ScenarioSpec(
            name: "birthdays-toggle-off",
            notes: ["The master toggle skips the whole category — same inputs as the birthday scenario, no birthday memory."],
            birthdaysEnabled: false,
            photos: onThisDayCore() + alicePhotos + bobPhotos,
            contacts: [alice, bob]
        ))

        // --- finalize ------------------------------------------------------
        out.append(ScenarioSpec(
            name: "finalize-caps-at-75-and-repoints-the-cover",
            notes: [
                "151 photos: the cap samples index Int(i × 151/75) for i in 0..<75, which SKIPS 75 — exactly the index onThisDay picked as its cover. The cover is therefore re-pointed to photoIDs[37] of the sampled list.",
                "The subtitle counts the CAPPED photos (75), not the original 151.",
                "yearsAgo-5 covers the same photos and is capped the same way, but its cover (also index 75 of 151) is re-pointed identically — both generators use ids[count / 2].",
            ],
            photos: series("cap", count: 151, start: MemoriesConformance.utc(2019, 6, 11, 6, 0), stepSeconds: 300)
        ))

        // --- selection cutoff ----------------------------------------------
        var manyPhotos = onThisDayCore()
        var manyFolders: [PhotoFolder] = []
        for month in 1...12 {
            let photos = series("fold\(month)", count: 16,
                                start: MemoriesConformance.utc(2023, month, 20, 9, 0),
                                stepSeconds: 4 * 3600)
            manyPhotos += photos
            manyFolders.append(folder("Folder \(month)", path: "/fixtures/lib/Folder\(month)", photos: photos))
        }
        out.append(ScenarioSpec(
            name: "ten-memory-greedy-cutoff",
            notes: [
                "14 candidates in 14 distinct clusters; selection stops at 10.",
                "The 12 folder events all score 12, so which 8 of them make the cut is decided purely by the jitter — this scenario is the one that fails loudest if the RNG or the stdlib Double conversion is off by anything.",
            ],
            photos: manyPhotos,
            leafFolders: manyFolders
        ))

        // --- time zone -----------------------------------------------------
        out.append(ScenarioSpec(
            name: "non-utc-timezone-asia-tokyo",
            notes: [
                "`now` is 2024-06-11T15:30Z, which is 2024-06-12 00:30 in Tokyo. The engine reads Calendar.current, so 'today' is June 12 — the June-12-local photos match and the June-11-local ones do not.",
                "…and the id says 2024-06-12 with it. It used to say 2024-06-11: the date was formatted by an ISO8601DateFormatter whose time zone is GMT, so the id's date and the calendar day the memory was ABOUT lived in different zones. Fixed and regenerated by _plans/10-widget-timezone-fix.md; the invariant is now that the date in an id names the local day the memory selects, which is also what makes the widget's pre-published ids resolve.",
            ],
            timeZone: "Asia/Tokyo",
            now: MemoriesConformance.utc(2024, 6, 11, 15, 30),
            photos: series("jst-match", count: 12, start: MemoriesConformance.utc(2019, 6, 11, 20, 0))
                + series("jst-miss", count: 12, start: MemoriesConformance.utc(2019, 6, 11, 2, 0))
        ))

        return out
    }

    // MARK: - Runner

    private func run(_ spec: ScenarioSpec) async -> ConfEngineScenario {
        // The time-zone move is still how a non-UTC scenario is driven: the
        // bridge reads `Calendar.current.timeZone.secondsFromGMT(for:)` — once
        // for `now` and once per photo — and hands the core fixed offsets, so
        // moving the process moves the engine's calendar exactly as it moved
        // `Calendar.current` before.
        //
        // `Calendar.current.timeZone`, **not** `TimeZone.current`: the latter
        // is cached and does not observe an `NSTimeZone.default` override, so
        // it would answer GMT here and the Tokyo scenario would silently run in
        // UTC. Both fixture zones are fixed-offset, so the per-photo offsets
        // equal the constant and no scenario can distinguish them.
        //
        // `contactsByLowerName` is no longer passed. The core derives it from
        // `contacts` the way `ContactLinker.index` does, which is what the
        // fixture's `contactsByLowerNameIsDerivedFromContacts` always asserted.
        let memories = await MemoriesConformance.withTimeZone(spec.timeZone) {
            await CoreMemories.generate(CoreMemories.Inputs(
                photos: spec.photos,
                leafFolders: spec.leafFolders,
                contacts: spec.contacts,
                personContactLinks: spec.links,
                birthdaysEnabled: spec.birthdaysEnabled,
                mePersonPath: spec.mePersonPath,
                hiddenPeople: spec.hiddenPeople,
                now: spec.now,
                seed: spec.seed,
                seenMemoryIDs: spec.seen,
                surfacedClusters: spec.surfaced
            ))
        }

        let links: [ConfLink] = spec.links.keys.sorted().map { path in
            switch spec.links[path] {
            case .manual(let id): return ConfLink(personPath: path, kind: "manual", contactID: id)
            case .disabled, nil:  return ConfLink(personPath: path, kind: "disabled", contactID: nil)
            }
        }
        let dateEntries: ([String: Date]) -> [ConfDateEntry] = { dict in
            dict.keys.sorted().map { ConfDateEntry(key: $0, date: MemoriesConformance.iso(dict[$0]!)) }
        }

        return ConfEngineScenario(
            name: spec.name,
            notes: spec.notes,
            inputs: ConfEngineInputs(
                now: MemoriesConformance.iso(spec.now),
                timeZone: spec.timeZone,
                seed: spec.seed,
                birthdaysEnabled: spec.birthdaysEnabled,
                mePersonPath: spec.mePersonPath,
                hiddenPeople: spec.hiddenPeople.sorted(),
                photos: spec.photos.map(ConfPhoto.init),
                leafFolders: spec.leafFolders.map { f in
                    ConfFolder(path: f.url.path, name: f.name, photoPaths: f.photos.map(\.url.path))
                },
                contacts: spec.contacts.map(ConfContact.init),
                contactsByLowerNameIsDerivedFromContacts: true,
                personContactLinks: links,
                seenMemoryIDs: dateEntries(spec.seen),
                surfacedClusters: dateEntries(spec.surfaced)
            ),
            expected: memories.map(ConfMemory.init)
        )
    }

    private func dump() async -> ConfEngineDump {
        var scenarios: [ConfEngineScenario] = []
        for spec in self.scenarios() { scenarios.append(await run(spec)) }
        return ConfEngineDump(
            schema: 1,
            environment: ConfEnvironment.current(notes: [
                "Subtitles come from DateFormatter.setLocalizedDateFormatFromTemplate(\"d MMM yyyy\") and trip labels from Locale.current.localizedString(forRegionCode:) — both ICU, both locale-sensitive. The strings pinned here belong to this locale.",
                "A run under a different locale will fail this fixture on the subtitle/title strings alone. That is the intended signal: the port has to answer the locale question, not inherit it silently.",
            ]),
            notes: [
                "Produced by LocalGalleryTests/Unit/MemoryEngineConformanceTests.swift from the shipping Swift MemoryEngine, BEFORE the Rust port.",
                "`inputs` is a complete MemoryCoordinator.GenerationInputs snapshot plus clock/seed/seen/cool-down/time zone. `contactsByLowerName` is derived from `contacts` the way ContactLinker.index derives it (lowercased fullName, first write wins).",
                "`inputs.photos` is already past MemoryCoordinator's cloud-placeholder filter — the engine never sees locality, and that filter stays in Swift.",
                "`expected[].score` is the PRE-jitter ladder score. The jitter (0–12, seeded) is not stored on a Memory; it is observable only as the order of `expected`.",
                "Photo ids are PhotoFile.stableID(for: path) — SHA-256 over the standardized path. `inputs.photos[].id` records them so the port can check its derivation without re-implementing the hash first.",
            ],
            scenarios: scenarios
        )
    }

    // MARK: - Tests

    func testMemoryEngineMatchesTheCommittedFixture() async throws {
        try ConformanceFixtures.assertMatches(
            await dump(), fixture: Self.fixtureName, in: MemoriesConformance.directory
        )
    }

    func testCommittedFixtureIsCanonical() throws {
        try ConformanceFixtures.assertCommittedBytesAreCanonical(
            ConfEngineDump.self, fixture: Self.fixtureName, in: MemoriesConformance.directory
        )
    }

    /// Every scenario has to be reproducible *within* a process, or the
    /// fixture is recording a coin flip. (Across processes the risk is Swift's
    /// per-process `Hasher` seed; this catches the same design mistake, since
    /// a scenario whose candidate order depends on a Dictionary walk will
    /// disagree with itself here far more often than not.)
    func testScenariosAreOrderStable() async throws {
        for spec in scenarios() {
            let a = await run(spec)
            let b = await run(spec)
            XCTAssertEqual(a, b, "scenario '\(spec.name)' is not reproducible")
        }
    }

    /// Guard rails the fixture itself cannot express: these are the invariants
    /// a regeneration must never quietly lose.
    func testFixtureInvariants() async throws {
        let dump = await dump()
        XCTAssertFalse(dump.scenarios.isEmpty)
        var names = Set<String>()
        for scenario in dump.scenarios {
            XCTAssertTrue(names.insert(scenario.name).inserted, "duplicate scenario \(scenario.name)")
            XCTAssertFalse(scenario.notes.isEmpty, "\(scenario.name) lost its notes")
            XCTAssertLessThanOrEqual(scenario.expected.count, 10, "\(scenario.name): selection cap is 10")

            var clusters = Set<String>()
            let ids = Set(scenario.inputs.photos.map(\.id))
            for memory in scenario.expected {
                XCTAssertTrue(
                    clusters.insert(CoreMemories.clusterKey(for: memory.id)).inserted,
                    "\(scenario.name): two memories from cluster \(CoreMemories.clusterKey(for: memory.id))"
                )
                XCTAssertLessThanOrEqual(memory.photoCount, 75, "\(scenario.name)/\(memory.id)")
                XCTAssertEqual(memory.photoCount, memory.photoIDs.count)
                XCTAssertTrue(memory.photoIDs.contains(memory.coverPhotoID),
                              "\(scenario.name)/\(memory.id): cover is not in the photo set")
                XCTAssertTrue(Set(memory.photoIDs).isSubset(of: ids),
                              "\(scenario.name)/\(memory.id): photo ids are not from the input library")
                XCTAssertTrue(memory.subtitle?.hasSuffix("photo") == true
                              || memory.subtitle?.hasSuffix("photos") == true,
                              "\(scenario.name)/\(memory.id): finalize did not standardize the subtitle")
            }
        }
        // The scenarios that exist to pin a specific behaviour must still do so.
        let byName = Dictionary(uniqueKeysWithValues: dump.scenarios.map { ($0.name, $0) })
        XCTAssertEqual(byName["empty-library"]?.expected.count, 0)
        XCTAssertEqual(byName["ten-memory-greedy-cutoff"]?.expected.count, 10)
        XCTAssertEqual(byName["finalize-caps-at-75-and-repoints-the-cover"]?.expected.first?.photoCount, 75)
        XCTAssertTrue(byName["birthdays-toggle-off"]?.expected.contains { $0.type == "birthday" } == false)
    }
}
