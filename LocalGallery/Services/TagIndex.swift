import Foundation
import Observation

/// Owns the tag → photos index used for collection lookups and the
/// canonical-cased path map needed by the async tag aggregator. The Store
/// keeps the observed `allTags` / `topPeople` lists as the source of truth;
/// this type provides the index + a pure aggregator the Store calls from a
/// background task.
@Observable
@MainActor
final class TagIndex {
    /// Lowercased fullPath → all photos credited to that tag, including the
    /// virtual `Places/*` prefix expansion (a photo tagged
    /// `Places/Italy/Lazio/Rome` counts toward `Places/Italy` and
    /// `Places/Italy/Lazio` too).
    private(set) var photosForTag: [String: [PhotoFile]] = [:]
    /// Lowercased fullPath → canonical-cased fullPath. Lets the async
    /// aggregator construct nicely-cased `TagSuggestion`s for virtual
    /// prefix tags that no leaf photo carries exactly.
    @ObservationIgnored private(set) var canonicalPath: [String: String] = [:]

    /// Rebuild the index from `allPhotos`. Includes the Places/* prefix
    /// expansion. One pass per call.
    func build(allPhotos: [PhotoFile]) {
        var tagPhotos: [String: [PhotoFile]] = [:]
        var canonical: [String: String] = [:]
        for photo in allPhotos {
            // Track which keys we've already credited this photo to so we
            // don't double-count when a photo carries both a leaf tag and an
            // explicit parent tag (e.g. Places/Italy AND Places/Italy/Lazio/Rome).
            var keysCreditedForPhoto = Set<String>()
            for tag in photo.hierarchicalTags {
                let segments = tag.fullPath.split(separator: "/").map(String.init)
                let isPlaces = tag.namespace?.lowercased() == "places"
                let isHierarchical = segments.count > 1
                let leafKey = tag.fullPath.lowercased()
                if keysCreditedForPhoto.insert(leafKey).inserted {
                    tagPhotos[leafKey, default: []].append(photo)
                }
                canonical[leafKey] = tag.fullPath
                if isPlaces && isHierarchical {
                    for depth in 2..<segments.count {
                        let prefixSegments = Array(segments.prefix(depth))
                        let prefixPath = prefixSegments.joined(separator: "/")
                        let key = prefixPath.lowercased()
                        if keysCreditedForPhoto.insert(key).inserted {
                            tagPhotos[key, default: []].append(photo)
                        }
                        if canonical[key] == nil {
                            canonical[key] = prefixPath
                        }
                    }
                }
            }
        }
        photosForTag = tagPhotos
        canonicalPath = canonical
    }

    func photos(forTag tag: TagSuggestion) -> [PhotoFile] {
        photosForTag[tag.fullPath.lowercased()] ?? []
    }

    /// Pure aggregator producing the global tag list and the recency-weighted
    /// people list. Snapshots are passed in so this can run on a detached task
    /// without touching the index instance. `nonisolated` because the Store
    /// invokes it from a `Task.detached` to keep aggregation off the main
    /// actor; inputs and outputs are all Sendable value types.
    nonisolated static func aggregateTagsAndPeople(
        photosForTag: [String: [PhotoFile]],
        canonicalPath: [String: String]
    ) -> (tags: [TagSuggestion], people: [TagSuggestion]) {
        // Build a TagSuggestion for every key in photosForTag — including the
        // virtual Places/* prefixes that no photo carries exactly.
        let tags: [TagSuggestion] = photosForTag.compactMap { entry -> TagSuggestion? in
            guard let path = canonicalPath[entry.key] else { return nil }
            let tag = HierarchicalTag(raw: path)
            return TagSuggestion(
                id: tag.fullPath.lowercased(),
                displayName: tag.displayName,
                fullPath: tag.fullPath,
                namespace: tag.namespace,
                count: entry.value.count
            )
        }
        .sorted { $0.count > $1.count }

        // Sort people by recent-activity then count. Show all people, not just
        // 8 — pinning / featuring happens downstream in visiblePeople.
        let peopleTags = tags.filter { $0.namespace?.lowercased() == "people" }
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let scoredPeople: [(tag: TagSuggestion, hasRecent: Bool)] = peopleTags.map { person in
            let photos = photosForTag[person.fullPath.lowercased()] ?? []
            let hasRecent = photos.contains { ($0.dateTaken ?? .distantPast) > oneYearAgo }
            return (person, hasRecent)
        }
        let people = scoredPeople
            .sorted { a, b in
                if a.hasRecent != b.hasRecent { return a.hasRecent }
                return a.tag.count > b.tag.count
            }
            .map(\.tag)

        return (tags, people)
    }
}
