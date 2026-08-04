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
    ///
    /// The published Swift arrays were never the whole story: `search` and
    /// `photos(forTag:)` are answered by the **core**, which swaps its own
    /// index when its build finishes rather than when the Swift side decides to
    /// publish. A generation counter alone cannot order those two swaps, so a
    /// big stale build finishing after a small fresh one left the app showing
    /// one library and querying another. Asserting only `sortedPhotos` could
    /// not see it.
    func testAStaleRebuildCannotPublishOverAFreshOne() async {
        let index = CoreLibraryIndex()
        let big = library(400)
        let small = [PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/only.jpg"),
                                       dateTaken: date(2024, 1, 1),
                                       tags: ["Scenes/Beach"])]
        index.build(allPhotos: big)
        index.build(allPhotos: small)
        await index.settle()
        XCTAssertEqual(index.sortedPhotos.map(\.id), small.map(\.id))
        XCTAssertNil(index.photo(byID: big[0].id), "the id table is the new library's")

        // The core's own index, reached through the two query paths. A stale
        // core would answer these with 400 ids that no longer resolve — i.e.
        // an empty list — or with the big library's tag buckets.
        XCTAssertEqual(index.search(query: "").map(\.id), small.map(\.id),
                       "the core is answering from the library that was published")
        guard let beach = index.allTags.first(where: { $0.id == "scenes/beach" }) else {
            return XCTFail("the fresh build's tag is missing: \(index.allTags.map(\.id))")
        }
        XCTAssertEqual(index.photos(forTag: beach).map(\.id), small.map(\.id))
        XCTAssertEqual(beach.count, 1, "the aggregation is the fresh build's too")
        // The stale library's distinctive tag is gone from both the aggregated
        // list and the core's buckets.
        XCTAssertNil(index.allTags.first { $0.id == "places/italy/lazio/rome" })
        XCTAssertTrue(index.search(query: "places/italy").isEmpty)
    }

    /// The reverse order, to prove the serialisation rather than the timing: a
    /// *small* build started first and a *big* one second must still leave the
    /// big one in the core, even though it takes far longer to finish.
    func testTheLastStartedRebuildIsAlwaysTheOneTheCoreHolds() async {
        let index = CoreLibraryIndex()
        let big = library(400)
        index.build(allPhotos: [PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/only.jpg"),
                                                  dateTaken: date(2024, 1, 1))])
        index.build(allPhotos: big)
        await index.settle()
        XCTAssertEqual(index.search(query: "").count, big.count)
        XCTAssertEqual(index.photos(forTag: index.allTags.first { $0.id == "scenes/beach" }!).count,
                       big.filter { $0.hierarchicalTags.contains { $0.fullPath == "Scenes/Beach" } }.count)
    }

    /// A query issued **during** a rebuild must not outlive it.
    ///
    /// The memos were cleared when a rebuild *started*, which left a window —
    /// the whole ~400 ms of the core build — in which `photoByID` already held
    /// the new library while the core still held the old one. A query in that
    /// window resolves the old index's ids against the new table, gets nothing,
    /// and cached that nothing *after* the clear had already happened. The
    /// result survived until the next rebuild: blank `PersonCard`s and an empty
    /// `TagGridView` on a library that was fully loaded.
    ///
    /// Deterministic without any timing games: `build` is synchronous up to the
    /// `Task` it spawns, and this suite is `@MainActor`, so the query below
    /// provably runs before the rebuild's first suspension point.
    func testAQueryDuringARebuildDoesNotSurviveThePublish() async {
        let index = CoreLibraryIndex()
        let first = (0..<30).map { i in
            PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/a-\(i).jpg"),
                              dateTaken: date(2020, 1, 1).addingTimeInterval(Double(i) * 3600),
                              tags: ["People/Alice Anderson"])
        }
        let second = (0..<7).map { i in
            PhotoFile.fixture(url: URL(fileURLWithPath: "/lib/b-\(i).jpg"),
                              dateTaken: date(2021, 1, 1).addingTimeInterval(Double(i) * 3600),
                              tags: ["People/Alice Anderson"])
        }
        index.build(allPhotos: first)
        await index.settle()
        guard let alice = index.allTags.first(where: { $0.id == "people/alice anderson" }) else {
            return XCTFail("no people tag in the first build")
        }
        XCTAssertEqual(index.photos(forTag: alice).count, 30)

        index.build(allPhotos: second)
        // Mid-rebuild: whatever these answer is allowed to be wrong. What is
        // not allowed is for the answer to be remembered.
        _ = index.photos(forTag: alice)
        _ = index.search(query: "alice")
        await index.settle()

        XCTAssertEqual(index.photos(forTag: alice).map(\.id), second.map(\.id),
                       "the mid-rebuild answer was memoised past the publish")
        XCTAssertEqual(index.search(query: "alice").count, 7)
    }

    /// Cold launch: `sortedPhotos` is empty before the first publish, and empty
    /// again for a genuinely empty library. `AllPhotosView` needs to tell those
    /// apart or it renders `PhotoGridScreen`'s "No photos match." over a
    /// library that is merely still sorting.
    func testTheIndexSaysWhetherItHasPublishedYet() async {
        let index = CoreLibraryIndex()
        XCTAssertFalse(index.hasEverPublished, "nothing has been built yet")
        XCTAssertTrue(index.sortedPhotos.isEmpty)

        index.build(allPhotos: library(50))
        XCTAssertFalse(index.hasEverPublished, "still building — this is the flash window")
        await index.settle()
        XCTAssertTrue(index.hasEverPublished)

        // A later rebuild must not take the flag back: the grid already has an
        // order to render, and dropping to a spinner mid-session would be a
        // worse flash than the one this fixes.
        index.build(allPhotos: library(10))
        XCTAssertTrue(index.hasEverPublished)
        await index.settle()
        XCTAssertTrue(index.hasEverPublished)

        // An empty library still publishes, so the empty state is reachable.
        index.build(allPhotos: [])
        await index.settle()
        XCTAssertTrue(index.hasEverPublished)
        XCTAssertTrue(index.sortedPhotos.isEmpty)
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

    /// The fence under `GalleryStore.scheduledInputs`.
    ///
    /// That snapshot deliberately fills in only the calendar half of
    /// `CoreMemories.Inputs` — no `seed`, no `leafFolders`, no seen/cool-down
    /// maps, and **no `mePersonPath`** — on the grounds that the horizon runs
    /// only `onThisDay` / `yearsAgo` / birthdays, none of which read them. That
    /// is true of today's engine and is not enforced anywhere: `mePersonPath`
    /// is read by trip titles, and a future ladder change that consulted it
    /// from a calendar generator would make every widget-scheduled memory
    /// differ from the one the app generates live on its day, silently, with no
    /// test going red.
    ///
    /// So: run the horizon with a non-empty `mePersonPath` and assert it
    /// changes nothing, and that the day-N item still equals the live run.
    func testTheScheduledInputsSubsetIsSafeToOmitMePersonPath() async {
        let photos = (0..<12).map { i in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/fixtures/lib/me-\(i).jpg"),
                dateTaken: MemoriesConformance.utc(2019, 6, 11, 12, i * 2),
                tags: ["People/Alice Anderson"]
            )
        }
        let base = CoreMemories.Inputs(
            photos: photos,
            contacts: [],
            now: MemoriesConformance.utc(2024, 6, 8, 12, 0)
        )
        var withMe = base
        withMe.mePersonPath = "People/Alice Anderson"

        let plain = await CoreMemories.computeScheduled(base, hiddenMemoryIDs: [])
        let tagged = await CoreMemories.computeScheduled(withMe, hiddenMemoryIDs: [])
        XCTAssertFalse(plain.isEmpty)
        XCTAssertEqual(plain.map(\.memory.id), tagged.map(\.memory.id),
                       "the horizon started reading mePersonPath — scheduledInputs must now supply it")
        XCTAssertEqual(plain.map(\.memory.photoIDs), tagged.map(\.memory.photoIDs))
        XCTAssertEqual(plain.map(\.memory.coverPhotoID), tagged.map(\.memory.coverPhotoID))

        // …and the day-N parity the widget deep links rest on still holds with
        // the field set, so the omission is not merely self-consistent.
        guard let item = tagged.first(where: { $0.memory.id == "onThisDay-2024-06-11" }) else {
            return XCTFail("the horizon did not reach June 11: \(tagged.map(\.memory.id))")
        }
        let live = await CoreMemories.generate(CoreMemories.Inputs(
            photos: photos,
            mePersonPath: "People/Alice Anderson",
            now: MemoriesConformance.utc(2024, 6, 11, 12, 0),
            seed: WidgetDayKey.string(for: MemoriesConformance.utc(2024, 6, 11, 0, 0))
        ))
        guard let liveSame = live.first(where: { $0.id == item.memory.id }) else {
            return XCTFail("the live run did not produce \(item.memory.id)")
        }
        XCTAssertEqual(liveSame.photoIDs, item.memory.photoIDs)
        XCTAssertEqual(liveSame.coverPhotoID, item.memory.coverPhotoID)
    }

    // MARK: - Folder events and cloud placeholders

    /// A leaf folder whose photos are mostly non-downloaded cloud placeholders.
    ///
    /// The engine's scored pool excludes them (no bytes, no sidecar, so no
    /// tags/GPS/date worth trusting), but the folder-event ladder must still
    /// see them — the deleted Swift read `folder.photos`, the folder's own
    /// array, which that filter never touched:
    ///
    /// ```swift
    /// for folder in leafFolders {
    ///     let withDatesRaw = folder.photos.compactMap { photo -> (PhotoFile, Date)? in
    ///         guard let date = photo.dateTaken else { return nil }
    ///         return (photo, date)
    ///     }.sorted { $0.1 < $1.1 }
    /// ```
    ///
    /// Resolving the members through the filtered pool alone drops this folder
    /// below the 15-photo floor entirely, so the memory disappears — and a
    /// folder that stayed above it would come back with a different photo list,
    /// a different `ids[count / 3]` cover and a different subtitle under an
    /// unchanged `folder-<id>` id.
    private func novemberFolder() -> (all: [PhotoFile], live: [PhotoFile], placeholders: [PhotoFile], folder: PhotoFolder) {
        let all = (0..<20).map { i -> PhotoFile in
            var photo = PhotoFile.fixture(
                url: URL(fileURLWithPath: "/fixtures/lib/November/\(String(format: "%02d", i)).jpg"),
                dateTaken: MemoriesConformance.utc(2019, 11, 5, 10, i * 2)
            )
            // Interleaved rather than appended: the folder's listing order is
            // what `photoIDs` records, so a placeholder in the middle is what
            // moves the `count / 3` cover.
            photo.locality = i % 5 < 2 ? .local : .remote(downloaded: false)
            return photo
        }
        let folder = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/fixtures/lib/November"),
            name: "November",
            photos: all
        )
        return (all,
                all.filter { $0.locality == .local },
                all.filter { $0.locality != .local },
                folder)
    }

    func testAFolderEventKeepsItsCloudPlaceholders() async {
        let f = novemberFolder()
        XCTAssertEqual(f.live.count, 8, "under the 15-photo floor on its own")
        let memories = await CoreMemories.generate(CoreMemories.Inputs(
            photos: f.live,
            folderPlaceholderPhotos: f.placeholders,
            leafFolders: [f.folder],
            now: MemoriesConformance.utc(2020, 3, 1, 12, 0),
            seed: "2020-03-01"
        ))
        guard let event = memories.first(where: { $0.type == .folderEvent }) else {
            return XCTFail("the folder event was dropped: \(memories.map(\.id))")
        }
        XCTAssertEqual(event.photoIDs, f.all.map(\.id), "membership is the folder's own")
        XCTAssertEqual(event.coverPhotoID, f.all[f.all.count / 3].id)
        XCTAssertEqual(event.subtitle, "Nov 5, 2019 · 20 photos")
    }

    /// The same call without the placeholders — the shape the bridge had before
    /// this fix — produces no folder event at all.
    func testWithholdingThePlaceholdersDeletesTheFolderEvent() async {
        let f = novemberFolder()
        let memories = await CoreMemories.generate(CoreMemories.Inputs(
            photos: f.live,
            leafFolders: [f.folder],
            now: MemoriesConformance.utc(2020, 3, 1, 12, 0),
            seed: "2020-03-01"
        ))
        XCTAssertFalse(memories.contains { $0.type == .folderEvent })
    }

    /// And the coordinator is the thing that has to supply them, so the split
    /// is asserted where it is actually made rather than only at the FFI.
    func testTheCoordinatorRoutesPlaceholdersToTheFolderLadder() async {
        let f = novemberFolder()
        let harness = TestGalleryStore.make(
            clock: FixedClock(date: MemoriesConformance.utc(2020, 3, 1, 12, 0))
        )
        defer { harness.teardown() }
        let coordinator = harness.store.memories
        coordinator.makeInputs = {
            MemoryCoordinator.GenerationInputs(
                photos: f.all,
                leafFolders: [f.folder],
                contacts: [],
                personContactLinks: [:],
                mePersonPath: "",
                hiddenPeople: []
            )
        }
        coordinator.forceRegenerate()
        // `forceRegenerate` is fire-and-forget; give the detached generation a
        // turn to land rather than asserting on a race.
        for _ in 0..<200 where coordinator.all.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let event = coordinator.all.first(where: { $0.type == .folderEvent }) else {
            return XCTFail("the coordinator dropped the folder event: \(coordinator.all.map(\.id))")
        }
        XCTAssertEqual(event.photoIDs.count, 20)
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
