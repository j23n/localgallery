import XCTest
@testable import LocalGallery

/// The Phase-4 bridge itself: `CoreLibraryIndex` and `CoreMemories` over the
/// real FFI, rather than the behaviours underneath them (those are pinned by
/// `IndexConformanceTests` / `MemoryEngineConformanceTests` against the
/// committed fixtures).
///
/// What is tested here is everything the *boundary* can get wrong and a
/// fixture cannot see: whether an id survives the round trip, whether a stale
/// rebuild can publish over a fresh one, whether cancellation reaches the core,
/// and whether a query stays fast enough to sit in a `View` body.
@MainActor
final class CoreLibraryBridgeTests: XCTestCase {

    // MARK: - Library

    /// A library of `count` photos, one every 7 hours from 2008, a third of
    /// them carrying a nested `Places/…` tag and some a `People/…` tag.
    ///
    /// The 7-hour step is chosen so 20,000 photos span ~16 years at ~3.4 a
    /// day: every calendar day is populated in many past years, which is what
    /// makes the scheduled-horizon measurement below do real work instead of
    /// early-exiting on empty buckets.
    private func library(_ count: Int) -> [PhotoFile] {
        let start = date(2008, 1, 1, 0, 0)
        return (0..<count).map { i in
            var tags: [String] = []
            if i % 3 == 0 { tags.append("Places/Italy/Lazio/Rome") }
            if i % 5 == 0 { tags.append("People/Alice Anderson") }
            if i % 7 == 0 { tags.append("Scenes/Beach") }
            return PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/photo-\(i).jpg"),
                filename: "photo-\(i)",
                dateTaken: start.addingTimeInterval(Double(i) * 25_200),
                tags: tags
            )
        }
    }

    private func built(_ photos: [PhotoFile]) async -> CoreLibraryIndex {
        let index = CoreLibraryIndex()
        index.build(allPhotos: photos)
        await index.settle()
        return index
    }

    /// The round trip: every photo handed to the core comes back as an id the
    /// app can resolve, in an order the app can render. A bridge that dropped
    /// or mangled ids would show an empty grid, not a wrong one.
    func testEveryPhotoSurvivesTheRoundTrip() async {
        let photos = library(500)
        let index = await built(photos)
        XCTAssertEqual(index.sortedPhotos.count, photos.count)
        XCTAssertEqual(Set(index.sortedPhotos.map(\.id)), Set(photos.map(\.id)))
        // Newest first — the same order the grid renders.
        XCTAssertEqual(index.sortedPhotos.first?.id, photos.last?.id)
        XCTAssertEqual(index.sortedPhotos.last?.id, photos.first?.id)
    }

    func testTagAggregationCountsMatchTheBuckets() async {
        let index = await built(library(90))
        let byID = Dictionary(uniqueKeysWithValues: index.allTags.map { ($0.id, $0) })
        // 90 photos: every third is in Rome, every fifth is Alice.
        XCTAssertEqual(byID["places/italy/lazio/rome"]?.count, 30)
        XCTAssertEqual(byID["people/alice anderson"]?.count, 18)
        // The virtual prefixes exist and carry the same photos as the leaf.
        XCTAssertEqual(byID["places/italy"]?.count, 30)
        XCTAssertEqual(byID["places/italy/lazio"]?.count, 30)
        for tag in index.allTags {
            XCTAssertEqual(index.photos(forTag: tag).count, tag.count,
                           "\(tag.id): bucket size disagrees with the suggestion")
        }
        XCTAssertEqual(index.peopleTags.map(\.fullPath), ["People/Alice Anderson"])
        XCTAssertNotNil(index.peopleTags.first?.latestPhotoDate,
                        "people suggestions carry their most recent photo date")
    }

    /// The generation guard. Two builds are started back to back; the second
    /// must be the one that publishes, whatever order the detached tasks
    /// finish in — otherwise a fast rescan behind a slow one restores a
    /// library the user already replaced.
    func testAStaleRebuildCannotPublishOverAFreshOne() async {
        let index = CoreLibraryIndex()
        let big = library(400)
        let small = [PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/only.jpg"),
                                       dateTaken: date(2024, 1, 1))]
        index.build(allPhotos: big)
        index.build(allPhotos: small)
        await index.settle()
        XCTAssertEqual(index.sortedPhotos.map(\.id), small.map(\.id))
        XCTAssertNil(index.photo(byID: big[0].id), "the id table is the new library's")
    }

    /// Search latency, at the scale the do-not-regress list cares about.
    ///
    /// Not a benchmark — a smoke test with a deliberately loose bound, because
    /// `store.search` is called from a `View` body (`TagGridView.photos`) and a
    /// boundary crossing there is the one thing `_plans/06`'s scroll findings
    /// say must not come back. The numbers this logs are the ones reported in
    /// the phase notes.
    func testSearchLatencyStaysInsideAFrameBudget() async {
        let index = await built(library(20_000))
        let queries: [(String, [TagSuggestion])] = [
            ("", []),
            ("rome", []),
            ("photo-1", []),
            ("places/italy", []),
            ("zzz-no-such-thing", []),
            ("", [index.allTags.first { $0.id == "people/alice anderson" }].compactMap { $0 }),
        ]
        for (query, required) in queries {
            // First call crosses the boundary; the second must hit the memo,
            // which is what makes a repeated body evaluation free.
            let cold = measureMillis { _ = index.search(query: query, requiredTags: required) }
            let warm = measureMillis { _ = index.search(query: query, requiredTags: required) }
            print("[search-latency] 20k \"\(query)\" tags=\(required.count) cold=\(String(format: "%.1f", cold))ms warm=\(String(format: "%.3f", warm))ms")
            XCTAssertLessThan(cold, 250, "query '\(query)' is too slow to sit in a View body")
        }
    }

    private func measureMillis(_ body: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }

    // MARK: - Memories

    /// 12 photos on 2019-06-11, two minutes apart — past the 60 s dedup window
    /// and over the on-this-day threshold. The same shape
    /// `memory_engine.json`'s `on-this-day-and-years-ago-overlap` uses.
    private func onThisDayLibrary() -> [PhotoFile] {
        (0..<12).map { i in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/fixtures/lib/otd-\(i).jpg"),
                dateTaken: MemoriesConformance.utc(2019, 6, 11, 12, i * 2)
            )
        }
    }

    /// The generation round trip against the same scenario the fixture pins,
    /// asserted here as ids so a failure says "the bridge" rather than "the
    /// engine". `MemoryEngineConformanceTests` owns the content.
    func testGenerateRoundTripsTheFixtureScenario() async {
        // Inline rather than `MemoriesConformance.withTimeZone`: this suite is
        // `@MainActor`, and the closure would have to carry a non-Sendable
        // main-actor body across an await, which strict concurrency refuses.
        let previous = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC") ?? previous
        let memories = await CoreMemories.generate(CoreMemories.Inputs(
            photos: onThisDayLibrary(),
            now: MemoriesConformance.utc(2024, 6, 11, 12, 0),
            seed: "2024-06-11"
        ))
        NSTimeZone.default = previous
        XCTAssertEqual(memories.map(\.id), ["onThisDay-2024-06-11", "yearsAgo-5-2024-06-11"])
        guard let first = memories.first else { return XCTFail("no memories") }
        XCTAssertEqual(first.type, .onThisDay)
        XCTAssertEqual(first.score, 55)
        XCTAssertEqual(first.photoIDs.count, 12)
        XCTAssertTrue(first.photoIDs.contains(first.coverPhotoID))
        XCTAssertEqual(first.subtitle, "Jun 11, 2019 · 12 photos")
        XCTAssertNotNil(first.dateRange)
        // The ids are the library's, resolved rather than re-derived.
        XCTAssertTrue(Set(first.photoIDs).isSubset(of: Set(onThisDayLibrary().map(\.id))))
    }

    /// Cancellation has to cross the boundary: `Task.detached` swallows it, so
    /// without the explicit forwarding the core would run to completion and the
    /// expiring background task would publish a result nobody wanted.
    func testCancellationReachesTheCoreAndYieldsNothing() async {
        let inputs = CoreMemories.Inputs(
            photos: onThisDayLibrary(),
            now: MemoriesConformance.utc(2024, 6, 11, 12, 0),
            seed: "2024-06-11"
        )
        let task = Task { await CoreMemories.generate(inputs) }
        task.cancel()
        let memories = await task.value
        XCTAssertTrue(memories.isEmpty, "a cancelled generation must publish nothing")
    }

    /// The horizon, and the invariant the widget deep links rest on: a day-N
    /// pre-published id is the id the live run produces on day N.
    func testScheduledHorizonMatchesTheLiveRunOnItsDay() async {
        let photos = onThisDayLibrary()
        let today = MemoriesConformance.utc(2024, 6, 8, 12, 0)
        let harness = TestGalleryStore.make(clock: FixedClock(date: today))
        defer { harness.teardown() }
        let store = harness.store

        let scheduled = await store.computeScheduledMemories(photos: photos)
        XCTAssertEqual(CoreMemories.horizonDays, 7)
        XCTAssertFalse(scheduled.isEmpty)
        // 2024-06-11 is offset +3.
        guard let item = scheduled.first(where: { $0.memory.id == "onThisDay-2024-06-11" }) else {
            return XCTFail("the horizon did not reach June 11; got \(scheduled.map(\.memory.id))")
        }
        XCTAssertLessThan(item.validFrom, item.validTo)

        let live = await CoreMemories.generate(CoreMemories.Inputs(
            photos: photos,
            now: MemoriesConformance.utc(2024, 6, 11, 12, 0),
            seed: WidgetDayKey.string(for: MemoriesConformance.utc(2024, 6, 11, 0, 0))
        ))
        guard let liveSame = live.first(where: { $0.id == item.memory.id }) else {
            return XCTFail("the live run did not produce \(item.memory.id)")
        }
        XCTAssertEqual(liveSame.photoIDs, item.memory.photoIDs)
        XCTAssertEqual(liveSame.coverPhotoID, item.memory.coverPhotoID)
        XCTAssertEqual(liveSame.subtitle, item.memory.subtitle)
    }

    /// The scheduled horizon on a 20k library — `_plans/06` Finding 3's gate.
    /// It used to be ~9 s **on the main actor**; the call below is `async` and
    /// the work happens on a detached task.
    func testScheduledHorizonOverALargeLibraryStaysUnderASecond() async {
        let photos = library(20_000)
        let harness = TestGalleryStore.make(clock: FixedClock(date: date(2024, 6, 8, 12, 0)))
        defer { harness.teardown() }
        let t = CFAbsoluteTimeGetCurrent()
        let scheduled = await harness.store.computeScheduledMemories(photos: photos)
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        print("[scheduled-horizon] 20k photos, 7 days: \(String(format: "%.0f", ms))ms, \(scheduled.count) items")
        XCTAssertLessThan(ms, 1000, "Finding 3's gate: the 7-day horizon must complete in under a second")
    }

    /// The index build over 20k, which the do-not-regress list caps at 0.3 s.
    /// Measured end to end — marshalling in, the core's work, and resolving
    /// 20,000 ids back to `PhotoFile`s — because that whole span is what the
    /// old synchronous `searchService.build` occupied on the main actor.
    func testIndexBuildOverALargeLibraryStaysInsideTheBudget() async {
        let photos = library(20_000)
        let index = CoreLibraryIndex()
        let t = CFAbsoluteTimeGetCurrent()
        index.build(allPhotos: photos)
        await index.settle()
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        print("[index-build] 20k photos: \(String(format: "%.0f", ms))ms")
        XCTAssertEqual(index.sortedPhotos.count, 20_000)
        XCTAssertLessThan(ms, 3000, "a build this slow would be visible as a stale grid after every scan")
    }

    // MARK: - Cluster keys

    func testClusterKeysCollapseSubtripsOntoTheirParent() {
        XCTAssertEqual(CoreMemories.clusterKey(for: "subtrip-2023-5-1-italy-tuscany"), "trip-2023-5-1")
        XCTAssertEqual(CoreMemories.clusterKey(for: "trip-2023-5-1"), "trip-2023-5-1")
        XCTAssertEqual(CoreMemories.clusterKey(for: "onThisDay-2024-06-11"), "onThisDay-2024-06-11")
        XCTAssertEqual(CoreMemories.clusterKey(for: "birthday-People/Anna"), "birthday-People/Anna")
    }

    /// Country names come from the core's table now, not from ICU. Pinned
    /// because it is a user-visible behaviour change: the names are `en_US`
    /// whatever the device language is.
    func testCountryNamesComeFromTheCoreTable() {
        XCTAssertEqual(CoreMemories.countryName(from: "AR"), "Argentina")
        XCTAssertEqual(CoreMemories.countryName(from: "de"), "Germany")
        XCTAssertNil(CoreMemories.countryName(from: "ZZ"))
    }
}
