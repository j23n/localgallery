import XCTest
@testable import LocalGallery

// MARK: - Fixture shape

struct ConfSearchQuery: Codable, Equatable {
    let query: String
    let requiredTagPaths: [String]
    let expectedPhotoIDs: [String]
    let notes: [String]
}

struct ConfSearchDump: Codable, Equatable {
    let schema: Int
    let notes: [String]
    let photos: [ConfPhoto]
    /// `SearchIndex.sortPhotos`: date descending, undated last, ties broken on
    /// `url.path`. Backs the grid, so this order IS the UI.
    let sortedPhotoIDs: [String]
    /// `photo.id` → the lowercased newline-joined corpus the substring match
    /// runs against. Recorded verbatim: the join character and the field order
    /// are both load-bearing.
    let corpus: [ConfCorpusEntry]
    let queries: [ConfSearchQuery]
}

struct ConfCorpusEntry: Codable, Equatable {
    let photoID: String
    let terms: [String]
}

struct ConfTagBucket: Codable, Equatable {
    let key: String
    let canonicalPath: String?
    /// Ordered: photos are appended in `allPhotos` order.
    let photoIDs: [String]
}

struct ConfTagSuggestion: Codable, Equatable {
    let id: String
    let displayName: String
    let fullPath: String
    let namespace: String?
    let count: Int
    let latestPhotoDate: String?
}

struct ConfTagDump: Codable, Equatable {
    let schema: Int
    let notes: [String]
    let photos: [ConfPhoto]
    /// Sorted by key here; the live index is a Dictionary and has no order.
    let buckets: [ConfTagBucket]
    /// Canonicalised to (count desc, id asc) — see the notes on tie order.
    let tagSuggestions: [ConfTagSuggestion]
    let peopleSuggestions: [ConfTagSuggestion]
}

// MARK: - Harness

/// The library index over one deterministic library.
///
/// The two fixtures were produced from the shipping Swift `SearchIndex` and
/// `TagIndex` before the port; since Phase 4 step 4 this harness drives the
/// **Rust core** through `CoreLibraryIndex`, and every assertion below is
/// unchanged. The sort tiebreak, the corpus join, and Swift's
/// *canonical-equivalence* substring matching are all invisible until a user
/// notices the grid reshuffled — which is why they are pinned rather than
/// re-derived.
///
/// Two shapes changed with the port, both of them reads rather than behaviour:
/// the bucket table is reconstructed from the aggregated suggestions (one
/// suggestion per bucket, carrying its key and its canonical spelling) plus
/// `photos(forTag:)`, because the core exposes the buckets that way; and the
/// index build is `async`, because it runs off the main actor.
@MainActor
final class IndexConformanceTests: XCTestCase {

    private static let searchFixture = "search_index.json"
    private static let tagFixture = "tag_index.json"

    // MARK: The library

    /// Sixteen photos chosen for the edges, not for realism: equal dates,
    /// undated pairs, a decomposed filename, a Turkish dotted capital, a photo
    /// carrying both a parent and a leaf `Places/*` tag, and a namespace-less
    /// flat tag.
    private func library() -> [PhotoFile] {
        let march = MemoriesConformance.utc(2024, 3, 1, 12, 0)
        return [
            // Equal timestamps → the URL-path tiebreak decides. Listed in the
            // "wrong" order on purpose so a missing tiebreak shows up.
            confPhoto("/fixtures/idx/b-equal.jpg", date: march),
            confPhoto("/fixtures/idx/a-equal.jpg", date: march),
            confPhoto("/fixtures/idx/c-later.jpg", date: MemoriesConformance.utc(2024, 5, 1, 12, 0)),
            // Undated: both sort to `.distantPast`, so they are also ties.
            confPhoto("/fixtures/idx/undated-b.jpg"),
            confPhoto("/fixtures/idx/undated-a.jpg"),
            confPhoto("/fixtures/idx/Beach Italy.jpg",
                      date: MemoriesConformance.utc(2023, 8, 1, 12, 0),
                      tags: ["Places/Italy/Lazio/Rome", "Scenes/Beach"]),
            confPhoto("/fixtures/idx/rome2.jpg",
                      date: MemoriesConformance.utc(2023, 8, 2, 12, 0),
                      tags: ["Places/Italy/Lazio/Rome"]),
            confPhoto("/fixtures/idx/milan.jpg",
                      date: MemoriesConformance.utc(2023, 9, 1, 12, 0),
                      tags: ["Places/Italy/Lombardy/Milan"]),
            confPhoto("/fixtures/idx/paris.jpg",
                      date: MemoriesConformance.utc(2023, 10, 1, 12, 0),
                      tags: ["Places/France/\u{00CE}le-de-France/Paris"]),
            confPhoto("/fixtures/idx/caf\u{00E9}.jpg",
                      date: MemoriesConformance.utc(2023, 11, 1, 12, 0),
                      tags: ["Objects/Cup"]),
            confPhoto("/fixtures/idx/\u{0130}stanbul.jpg",
                      date: MemoriesConformance.utc(2023, 12, 1, 12, 0),
                      tags: ["Places/T\u{00FC}rkiye/Istanbul"]),
            confPhoto("/fixtures/idx/alice1.jpg",
                      date: MemoriesConformance.utc(2024, 1, 1, 12, 0),
                      tags: ["People/Alice Anderson"]),
            confPhoto("/fixtures/idx/alice2.jpg",
                      date: MemoriesConformance.utc(2024, 2, 1, 12, 0),
                      tags: ["People/Alice Anderson", "Scenes/Beach"]),
            confPhoto("/fixtures/idx/bob.jpg",
                      date: MemoriesConformance.utc(2023, 1, 1, 12, 0),
                      tags: ["People/Bob Brown"]),
            confPhoto("/fixtures/idx/flat.jpg",
                      date: MemoriesConformance.utc(2022, 1, 1, 12, 0),
                      tags: ["Vacation"]),
            confPhoto("/fixtures/idx/both-levels.jpg",
                      date: MemoriesConformance.utc(2022, 2, 1, 12, 0),
                      tags: ["Places/Italy", "Places/Italy/Lazio/Rome"]),
        ]
    }

    private func indexes() async -> (index: CoreLibraryIndex, photos: [PhotoFile], allTags: [TagSuggestion]) {
        let photos = library()
        let index = CoreLibraryIndex()
        index.build(allPhotos: photos)
        await index.settle()
        return (index, photos, index.allTags)
    }

    // MARK: SearchIndex dump

    private struct QuerySpec {
        let query: String
        let requiredTagPaths: [String]
        let notes: [String]
    }

    private func querySpecs() -> [QuerySpec] {
        [
            QuerySpec(query: "", requiredTagPaths: [],
                      notes: ["An empty query with no required tags returns the sorted list untouched — this is the grid's default."]),
            QuerySpec(query: "rome", requiredTagPaths: [],
                      notes: ["Plain substring against the corpus. Matches the tag leaf 'Rome' and the full path, so photos tagged Places/Italy/Lazio/Rome all hit."]),
            QuerySpec(query: "ROME", requiredTagPaths: [],
                      notes: ["The query is lowercased and so is the corpus: case never matters."]),
            QuerySpec(query: "places/italy", requiredTagPaths: [],
                      notes: ["The query matches a known tag path exactly, so search switches to the TAG branch — and because the namespace is Places, it also matches every nested path. A photo tagged only Places/France is not swept in.",
                              "This branch depends on `allTags`, which is the Store's aggregated list — the same list TagIndex produces. A port must feed it the same way or this query silently degrades to a substring match."]),
            QuerySpec(query: "people/alice anderson", requiredTagPaths: [],
                      notes: ["Same tag branch, non-Places namespace: exact path only, no prefix expansion."]),
            QuerySpec(query: "places/italy/lazio", requiredTagPaths: [],
                      notes: ["A VIRTUAL tag: no photo carries this path, but TagIndex synthesises it from the prefix expansion, so it is in allTags and takes the tag branch."]),
            QuerySpec(query: "beach italy", requiredTagPaths: [],
                      notes: ["A multi-token query is not tokenised — it is one substring. It matches only because a filename literally contains 'beach italy'."]),
            QuerySpec(query: "italy beach", requiredTagPaths: [],
                      notes: ["…and reversing the two words matches nothing. The corpus joins terms with '\\n', so a substring can never span two terms either."]),
            QuerySpec(query: "caf\u{00E9}", requiredTagPaths: [],
                      notes: ["The query is precomposed (NFC); the filename on disk is decomposed (Foundation's URL(fileURLWithPath:) decomposes). Swift's String.contains compares by CANONICAL EQUIVALENCE, so it matches anyway.",
                              "A Rust port that compares bytes will NOT match this, and a user searching for a name with an accent will get nothing. This is the single most likely regression in the index port."]),
            QuerySpec(query: "cafe", requiredTagPaths: [],
                      notes: ["Canonical equivalence is not accent folding: the unaccented spelling does not match."]),
            QuerySpec(query: "istanbul", requiredTagPaths: [],
                      notes: ["'\u{0130}'.lowercased() is 'i' + U+0307 COMBINING DOT ABOVE, which is not canonically equivalent to plain 'i'. Whatever this records is what a Turkish filename does today.",
                              "Swift's lowercased() is the full Unicode mapping and is locale-INdependent — it does not do the Turkish dotless-i thing."]),
            QuerySpec(query: "zzz-no-such-thing", requiredTagPaths: [],
                      notes: ["No match: an empty result, not the unfiltered list."]),
            QuerySpec(query: "", requiredTagPaths: ["Places/Italy"],
                      notes: ["Required tags AND together and are applied BEFORE the query. Places prefix expansion applies here too."]),
            QuerySpec(query: "", requiredTagPaths: ["Places/Italy", "Scenes/Beach"],
                      notes: ["Two required tags intersect."]),
            QuerySpec(query: "alice", requiredTagPaths: ["Scenes/Beach"],
                      notes: ["Required tag plus a substring query: both must hold."]),
            QuerySpec(query: "", requiredTagPaths: ["Vacation"],
                      notes: ["A namespace-less flat tag: no prefix expansion, exact match only."]),
        ]
    }

    private func searchDump() async -> ConfSearchDump {
        let (index, photos, allTags) = await indexes()
        let tagByPath = Dictionary(uniqueKeysWithValues: allTags.map { ($0.fullPath.lowercased(), $0) })

        let queries: [ConfSearchQuery] = querySpecs().map { spec in
            let required = spec.requiredTagPaths.compactMap { tagByPath[$0.lowercased()] }
            XCTAssertEqual(required.count, spec.requiredTagPaths.count,
                           "query '\(spec.query)': a required tag is not in the aggregated tag list")
            let results = index.search(query: spec.query, requiredTags: required)
            return ConfSearchQuery(
                query: spec.query,
                requiredTagPaths: spec.requiredTagPaths,
                expectedPhotoIDs: results.map(\.id.uuidString),
                notes: spec.notes
            )
        }

        let corpus: [ConfCorpusEntry] = photos.map { photo in
            var terms: [String] = [photo.filename]
            for tag in photo.hierarchicalTags {
                terms.append(tag.displayName)
                terms.append(tag.fullPath)
            }
            return ConfCorpusEntry(photoID: photo.id.uuidString, terms: terms.map { $0.lowercased() })
        }

        return ConfSearchDump(
            schema: 1,
            notes: [
                "Produced by LocalGalleryTests/Unit/IndexConformanceTests.swift from the shipping Swift SearchIndex, BEFORE the Rust port.",
                "Sort: dateTaken descending with nil as .distantPast, ties broken by `url.path` ascending. The tiebreak exists so a rescan cannot reshuffle the grid — pin it or the flicker comes back.",
                "`url.path` is compared with Swift's `<`, which for equal-length ASCII is byte order. The fixture's paths are ASCII apart from the two Unicode filenames, which do not tie with anything.",
                "The corpus is filename + (displayName, fullPath) per tag, joined with '\\n' and lowercased. It is rebuilt wholesale on every build(allPhotos:).",
                "Matching is `corpus.contains(query)` on lowercased strings — Swift substring search, i.e. CANONICAL EQUIVALENCE, not byte equality. See the 'café' query.",
            ],
            photos: photos.map(ConfPhoto.init),
            sortedPhotoIDs: index.sortedPhotos.map(\.id.uuidString),
            corpus: corpus,
            queries: queries
        )
    }

    // MARK: TagIndex dump

    private func suggestion(_ s: TagSuggestion) -> ConfTagSuggestion {
        ConfTagSuggestion(
            id: s.id, displayName: s.displayName, fullPath: s.fullPath,
            namespace: s.namespace, count: s.count,
            latestPhotoDate: MemoriesConformance.iso(s.latestPhotoDate)
        )
    }

    /// The aggregator sorts by `count` alone, with a non-stable sort, over a
    /// Dictionary walk — equal counts come out in an order that varies between
    /// processes. Canonicalise before comparing, and say so.
    private func canonical(_ list: [TagSuggestion]) -> [ConfTagSuggestion] {
        list.map(suggestion).sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id
        }
    }

    private func tagDump() async -> ConfTagDump {
        let (index, photos, _) = await indexes()
        let aggregated = (tags: index.allTags, people: index.peopleTags)
        // The core exposes one aggregated suggestion per bucket — carrying the
        // bucket key (`id`) and its canonical spelling (`fullPath`) — and the
        // bucket's photos through `photos(forTag:)`. Reconstructing the table
        // from those two is the FFI equivalent of reading `photosForTag` /
        // `canonicalPath` off the Swift index, and it is 1:1 because a bucket
        // with no canonical spelling cannot produce a suggestion.
        let buckets = aggregated.tags
            .sorted { $0.id < $1.id }
            .map { suggestion in
                ConfTagBucket(
                    key: suggestion.id,
                    canonicalPath: suggestion.fullPath,
                    photoIDs: index.photos(forTag: suggestion).map(\.id.uuidString)
                )
            }
        return ConfTagDump(
            schema: 1,
            notes: [
                "Produced by LocalGalleryTests/Unit/IndexConformanceTests.swift from the shipping Swift TagIndex, BEFORE the Rust port.",
                "Bucket keys are lowercased full paths. `canonicalPath` keeps the original casing; for a virtual prefix key it is the first spelling encountered, and the FIRST write wins (unlike the leaf key, where the LAST write wins).",
                "Prefix expansion applies only to namespaces where TagNamespace.matchesByPrefix is true — places, objects, scenes — and only from depth 2 up, so the bare namespace ('places') is never a bucket.",
                "A photo carrying both a parent and a leaf tag is credited to each key ONCE: `both-levels.jpg` appears a single time in the places/italy bucket even though two of its tags map there.",
                "Bucket photo order is `allPhotos` order and is deterministic. Bucket KEY order is not — the live index is a Dictionary; this list is sorted for the fixture.",
                "NONDETERMINISM, pinned as a canonical form rather than as observed output: aggregateTagsAndPeople sorts by `count` descending only, with Swift's non-stable `sorted`, over a Dictionary walk. Equal-count entries come out in an unspecified order that varies between processes. `tagSuggestions` and `peopleSuggestions` below are re-sorted by (count desc, id asc); the port must reproduce the COUNTS and the grouping, and is free in the tie order — as the Swift is.",
                "`latestPhotoDate` is set for people suggestions only; the general tag list always has it nil.",
            ],
            photos: photos.map(ConfPhoto.init),
            buckets: buckets,
            tagSuggestions: canonical(aggregated.tags),
            peopleSuggestions: canonical(aggregated.people)
        )
    }

    // MARK: Tests

    func testSearchIndexMatchesTheCommittedFixture() async throws {
        try ConformanceFixtures.assertMatches(
            await searchDump(), fixture: Self.searchFixture, in: MemoriesConformance.directory
        )
    }

    func testTagIndexMatchesTheCommittedFixture() async throws {
        try ConformanceFixtures.assertMatches(
            await tagDump(), fixture: Self.tagFixture, in: MemoriesConformance.directory
        )
    }

    func testCommittedFixturesAreCanonical() throws {
        try ConformanceFixtures.assertCommittedBytesAreCanonical(
            ConfSearchDump.self, fixture: Self.searchFixture, in: MemoriesConformance.directory
        )
        try ConformanceFixtures.assertCommittedBytesAreCanonical(
            ConfTagDump.self, fixture: Self.tagFixture, in: MemoriesConformance.directory
        )
    }

    /// Rebuilding from the same input must produce the same everything — the
    /// grid-order-stability gate from the plan, checked at the index level.
    func testRebuildIsStable() async throws {
        let searchA = await searchDump()
        let searchB = await searchDump()
        XCTAssertEqual(searchA, searchB)
        let tagsA = await tagDump()
        let tagsB = await tagDump()
        XCTAssertEqual(tagsA, tagsB)
    }

    /// Invariants the fixture cannot state about itself.
    func testIndexInvariants() async throws {
        let search = await searchDump()
        let tags = await tagDump()
        XCTAssertEqual(Set(search.photos.map(\.id)).count, search.photos.count, "duplicate photo ids")
        XCTAssertEqual(search.sortedPhotoIDs.count, search.photos.count, "sort must not drop photos")
        XCTAssertEqual(Set(search.sortedPhotoIDs), Set(search.photos.map(\.id)))

        let byID = Dictionary(uniqueKeysWithValues: search.photos.map { ($0.id, $0) })
        // Dated photos come first, in descending order; undated close the list.
        let dates = search.sortedPhotoIDs.map { byID[$0]?.dateTaken }
        let firstUndated = dates.firstIndex(where: { $0 == nil }) ?? dates.count
        XCTAssertFalse(dates[firstUndated...].contains(where: { $0 != nil }),
                       "an undated photo sorted above a dated one")
        for i in 1..<firstUndated {
            XCTAssertGreaterThanOrEqual(dates[i - 1]!, dates[i]!, "sort is not date-descending")
        }
        // Ties break on path, ascending.
        for i in 1..<search.sortedPhotoIDs.count where dates[i - 1] == dates[i] {
            XCTAssertLessThan(byID[search.sortedPhotoIDs[i - 1]]!.path,
                              byID[search.sortedPhotoIDs[i]]!.path,
                              "tied photos are not in path order")
        }

        for bucket in tags.buckets {
            XCTAssertEqual(bucket.key, bucket.key.lowercased())
            XCTAssertEqual(Set(bucket.photoIDs).count, bucket.photoIDs.count,
                           "\(bucket.key): a photo is credited twice")
            XCTAssertNotNil(bucket.canonicalPath, "\(bucket.key) has no canonical spelling")
        }
        // Every suggestion's count is its bucket's size.
        let bucketSize = Dictionary(uniqueKeysWithValues: tags.buckets.map { ($0.key, $0.photoIDs.count) })
        for s in tags.tagSuggestions {
            XCTAssertEqual(s.count, bucketSize[s.id], "\(s.id): count disagrees with the bucket")
            XCTAssertNil(s.latestPhotoDate, "only people suggestions carry latestPhotoDate")
        }
        for p in tags.peopleSuggestions {
            XCTAssertEqual(p.namespace?.lowercased(), "people")
        }
    }
}
