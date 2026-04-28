import Foundation
import Observation
import os

/// Owns the date-sorted photo list, the per-photo search corpus, and the
/// O(1) photo-by-ID lookup. `@Observable` so view reads chained through the
/// Store (e.g. `store.sortedPhotos`) re-render correctly when the index
/// rebuilds.
@Observable
@MainActor
final class SearchIndex {
    /// Date-descending photo list. Backs `store.sortedPhotos`.
    private(set) var sortedPhotos: [PhotoFile] = []
    /// `PhotoFile.id` → `PhotoFile`. Backs `store.photo(byID:)`.
    private(set) var photoByID: [UUID: PhotoFile] = [:]
    /// Per-photo lowercased search corpus: filename + every tag leaf + every
    /// tag full path, joined by newline. Substring-matched in `search(...)`.
    @ObservationIgnored private var corpus: [UUID: String] = [:]

    /// Date-descending sort. Photos missing `dateTaken` go to the bottom.
    func sortPhotos(_ photos: [PhotoFile]) -> [PhotoFile] {
        photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
    }

    /// Rebuild every index from `allPhotos`. One pass per call.
    func build(allPhotos: [PhotoFile]) {
        sortedPhotos = sortPhotos(allPhotos)
        photoByID = Dictionary(allPhotos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newCorpus: [UUID: String] = [:]
        for photo in allPhotos {
            var terms: [String] = [photo.filename]
            for tag in photo.hierarchicalTags {
                terms.append(tag.displayName)
                terms.append(tag.fullPath)
            }
            newCorpus[photo.id] = terms.joined(separator: "\n").lowercased()
        }
        corpus = newCorpus
    }

    func photo(byID id: UUID) -> PhotoFile? { photoByID[id] }

    /// Filter the sorted photo list by AND-combining required tags and an
    /// optional substring query. `allTags` is the Store's observed tag list,
    /// passed in so `search` doesn't depend on TagIndex.
    func search(query: String, requiredTags: [TagSuggestion], allTags: [TagSuggestion]) -> [PhotoFile] {
        var results = sortedPhotos

        // Apply AND filter for each required tag. Places/* matches as a path
        // prefix so filtering by "Places/Argentina" surfaces every photo nested
        // under Argentina, not just ones tagged exactly at country level.
        for tag in requiredTags {
            let tagPath = tag.fullPath.lowercased()
            let isPlaces = tag.namespace?.lowercased() == "places"
            results = results.filter { photo in
                photo.hierarchicalTags.contains { ht in
                    let hp = ht.fullPath.lowercased()
                    if hp == tagPath { return true }
                    if isPlaces, hp.hasPrefix(tagPath + "/") { return true }
                    return false
                }
            }
        }

        guard !query.isEmpty else {
            if !requiredTags.isEmpty {
                Log.search.debug("tags:\(requiredTags.map(\.displayName)) → \(results.count) matches")
            }
            return results
        }

        let q = query.lowercased()
        // If query matches a known tag path exactly, filter by that tag.
        let matchedTag = allTags.first { $0.fullPath.lowercased() == q }
        if let matchedTag {
            let isPlaces = matchedTag.namespace?.lowercased() == "places"
            results = results.filter { photo in
                photo.hierarchicalTags.contains { ht in
                    let hp = ht.fullPath.lowercased()
                    if hp == q { return true }
                    if isPlaces, hp.hasPrefix(q + "/") { return true }
                    return false
                }
            }
        } else {
            results = results.filter { photo in
                corpus[photo.id]?.contains(q) ?? false
            }
        }
        Log.search.debug("\"\(query)\" tags:\(requiredTags.map(\.displayName)) → \(results.count) matches\(matchedTag != nil ? " (exact tag)" : "")")
        return results
    }
}
