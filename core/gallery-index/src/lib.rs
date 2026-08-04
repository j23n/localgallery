//! `SearchIndex` + `TagIndex`, ported (Phase 4 step 3).
//!
//! Both Swift types are pure functions of `allPhotos`, which makes them the
//! easiest part of the phase to port and the easiest to get quietly wrong: the
//! sort tiebreak, the corpus join and Swift's canonical-equivalence substring
//! matching are all invisible until a user notices the grid reshuffled or an
//! accented name stopped being findable.
//! `core/fixtures/memories-conformance/{search_index,tag_index}.json` pin all
//! three; `tests/index_conformance.rs` runs this code against them.
//!
//! One owner, one photo table: [`LibraryIndex`] holds the photos and every
//! index is a list of **indices** into it. That is the Phase-4-sanctioned
//! improvement over the Swift `TagIndex`, which copies a whole `PhotoFile`
//! into every bucket a photo is credited to.

#![forbid(unsafe_code)]

pub mod search;
pub mod tags;
pub mod text;

use std::collections::HashMap;

use gallery_model::{PhotoFile, StableId};

pub use search::{corpus_entry, corpus_terms, DISTANT_PAST};
pub use tags::{matches_by_prefix, TagIndex, TagSuggestion};

/// The photo table plus every index built over it.
///
/// Rebuilt wholesale from `all_photos`, exactly as the Swift pair is: the Store
/// calls `build(allPhotos:)` on both after every `apply(_:)`, and partial
/// updates were never part of the contract.
#[derive(Debug, Clone)]
pub struct LibraryIndex {
    photos: Vec<PhotoFile>,
    by_id: HashMap<StableId, u32>,
    /// Indices into `photos`, date descending with the `url.path` tiebreak.
    sorted: Vec<u32>,
    /// Parallel to `photos`: the newline-joined, match-key-folded corpus.
    corpus: Vec<String>,
    tags: TagIndex,
}

impl LibraryIndex {
    /// Build every index from `all_photos`. One pass per index, no photo copies
    /// beyond the single table this takes ownership of.
    pub fn build(all_photos: Vec<PhotoFile>) -> Self {
        let keys: Vec<search::SortKey> = all_photos.iter().map(search::SortKey::new).collect();
        let mut sorted: Vec<u32> = (0..all_photos.len() as u32).collect();
        // Stable, so the comparator alone decides — the Swift `sorted` is not
        // stable, which is precisely why it needs the path tiebreak.
        sorted.sort_by(|a, b| keys[*a as usize].cmp(&keys[*b as usize]));

        // First id wins, mirroring `uniquingKeysWith: { a, _ in a }`.
        let mut by_id: HashMap<StableId, u32> = HashMap::with_capacity(all_photos.len());
        for (i, photo) in all_photos.iter().enumerate() {
            by_id.entry(photo.id).or_insert(i as u32);
        }

        let corpus: Vec<String> = all_photos.iter().map(search::corpus_entry).collect();
        let tags = TagIndex::build(&all_photos);

        LibraryIndex {
            photos: all_photos,
            by_id,
            sorted,
            corpus,
            tags,
        }
    }

    /// The photo table, in the order it was handed over.
    pub fn photos(&self) -> &[PhotoFile] {
        &self.photos
    }

    /// The tag index.
    pub fn tags(&self) -> &TagIndex {
        &self.tags
    }

    /// Date-descending photo list. Backs `store.sortedPhotos` — this order *is*
    /// the grid.
    pub fn sorted_photos(&self) -> impl Iterator<Item = &PhotoFile> {
        self.sorted.iter().map(|i| &self.photos[*i as usize])
    }

    /// The sorted list as ids, for the FFI boundary.
    pub fn sorted_photo_ids(&self) -> Vec<StableId> {
        self.sorted_photos().map(|p| p.id).collect()
    }

    /// `photoByID` — O(1) lookup.
    pub fn photo(&self, id: StableId) -> Option<&PhotoFile> {
        self.by_id.get(&id).map(|i| &self.photos[*i as usize])
    }

    /// `TagIndex.photos(forTag:)`.
    pub fn photos_for_tag(&self, full_path: &str) -> Vec<&PhotoFile> {
        self.tags
            .indices_for_key(&text::match_key(full_path))
            .iter()
            .map(|i| &self.photos[*i as usize])
            .collect()
    }

    /// `TagIndex.aggregateTagsAndPeople` over this index.
    pub fn tag_suggestions(&self) -> (Vec<TagSuggestion>, Vec<TagSuggestion>) {
        self.tags.aggregate(&self.photos)
    }

    /// `SearchIndex.search(query:requiredTags:allTags:)`.
    ///
    /// Required tags AND together and are applied **before** the query. Then
    /// one of two branches:
    ///
    /// - the query equals a known tag path → filter by that tag (with
    ///   `Places/*` prefix expansion), or
    /// - anything else → a single substring match against the corpus.
    ///
    /// `all_tags` is the caller's aggregated list rather than this index's own,
    /// mirroring the Swift signature: the Store owns that list, and it is what
    /// makes *virtual* prefix tags (`places/italy/lazio`, which no photo
    /// carries) queryable. Pass [`Self::tag_suggestions`]'s first element to
    /// get the app's behaviour.
    pub fn search(
        &self,
        query: &str,
        required_tags: &[TagSuggestion],
        all_tags: &[TagSuggestion],
    ) -> Vec<&PhotoFile> {
        self.search_indices(query, required_tags, all_tags)
            .into_iter()
            .map(|i| &self.photos[i as usize])
            .collect()
    }

    /// [`Self::search`] as photo-table indices — the allocation-free form the
    /// paging FFI wants.
    pub fn search_indices(
        &self,
        query: &str,
        required_tags: &[TagSuggestion],
        all_tags: &[TagSuggestion],
    ) -> Vec<u32> {
        let mut results = self.sorted.clone();

        for tag in required_tags {
            let path = text::match_key(&tag.full_path);
            let is_places =
                tag.namespace.as_deref().map(text::lowercased).as_deref() == Some("places");
            results.retain(|i| self.photo_carries(*i, &path, is_places));
        }

        if query.is_empty() {
            return results;
        }

        let q = text::match_key(query);
        match all_tags.iter().find(|t| text::match_key(&t.full_path) == q) {
            Some(matched) => {
                let is_places = matched
                    .namespace
                    .as_deref()
                    .map(text::lowercased)
                    .as_deref()
                    == Some("places");
                results.retain(|i| self.photo_carries(*i, &q, is_places));
            }
            // `q` is already in the corpus's canonical form, so the fallback
            // is a plain byte search.
            None => results.retain(|i| self.corpus[*i as usize].contains(&q)),
        }
        results
    }

    /// Does photo `idx` carry `path` (already [`text::match_key`]ed), counting a nested
    /// path when `is_places`?
    fn photo_carries(&self, idx: u32, path: &str, is_places: bool) -> bool {
        self.photos[idx as usize]
            .hierarchical_tags
            .iter()
            .any(|ht| {
                let hp = text::match_key(&ht.full_path);
                // `hp == path || (isPlaces && hp.hasPrefix(path + "/"))`,
                // without building the concatenation on every comparison.
                hp == path
                    || (is_places
                        && hp.len() > path.len()
                        && hp.starts_with(path)
                        && hp.as_bytes()[path.len()] == b'/')
            })
    }
}
