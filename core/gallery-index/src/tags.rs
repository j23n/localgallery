//! `TagIndex.swift`, ported — with the one behaviour change Phase 4 sanctions.
//!
//! The Swift index stores `[String: [PhotoFile]]`: a full struct copy of every
//! photo, in every bucket it is credited to, plus the `Places/*` prefix
//! expansion that credits one photo to three or four keys. `_plans/05` calls
//! taking the known follow-up ("switch to `[String: [UUID]]` + `photoByID`")
//! part of the port rather than replicating the waste, so this stores **photo
//! indices into one shared photo table** and nothing else. It is invisible to
//! callers: the same keys, the same order, the same counts.

use gallery_model::{HierarchicalTag, PhotoFile};
use std::collections::{HashMap, HashSet};

use crate::text;

/// `TagSuggestion.swift` — a bucket, flattened for the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct TagSuggestion {
    /// `fullPath` lowercased (and NFC-folded). The bucket key.
    pub id: String,
    /// Leaf segment.
    pub display_name: String,
    /// The canonical-cased hierarchical path.
    pub full_path: String,
    /// First segment, `None` for a flat tag.
    pub namespace: Option<String>,
    /// Photos credited to the bucket.
    pub count: usize,
    /// Most recent `dateTaken` among the bucket's photos, as seconds since the
    /// Apple reference date. Set for **people** suggestions only — the general
    /// tag list always leaves it `None`, which is what the fixture pins.
    pub latest_photo_date: Option<f64>,
}

/// `TagNamespace.matchesByPrefix` — namespaces whose parent tags act as prefix
/// filters. Selecting `Places/Italy` must surface `Places/Italy/Lazio/Rome`.
pub fn matches_by_prefix(namespace: Option<&str>) -> bool {
    matches!(
        namespace.map(text::lowercased).as_deref(),
        Some("places") | Some("objects") | Some("scenes")
    )
}

/// Swift's `raw.split(separator: "/")`: empty segments are dropped and nothing
/// is trimmed. `TagIndex.build` splits this way, unlike `HierarchicalTag(raw:)`
/// which also trims — keep them separate or a tag with a stray space changes
/// bucket.
fn segments(full_path: &str) -> Vec<&str> {
    full_path.split('/').filter(|s| !s.is_empty()).collect()
}

/// Lowercased tag path → the photos carrying it, plus the canonical spelling
/// of every key.
#[derive(Debug, Default, Clone)]
pub struct TagIndex {
    /// Key → indices into the photo table, in `all_photos` order.
    ///
    /// Keys are [`text::match_key`], not merely lowercased. Swift's `String`
    /// hashing is normalisation-aware, so a `Dictionary` there already merges
    /// canonically-equivalent spellings of a tag path into one bucket; a
    /// byte-keyed `HashMap` would split them. No fixture covers it — every tag
    /// path in them is already NFC, so the two agree — but the divergence is
    /// real and free to avoid.
    buckets: HashMap<String, Vec<u32>>,
    /// Key → canonical-cased path.
    ///
    /// The two kinds of key disagree about which spelling wins, and the fixture
    /// pins the disagreement: for a **leaf** key the last write wins, for a
    /// **virtual prefix** key the first does.
    canonical: HashMap<String, String>,
}

impl TagIndex {
    /// Rebuild from `all_photos`. One pass, including the prefix expansion.
    pub fn build(all_photos: &[PhotoFile]) -> Self {
        let mut buckets: HashMap<String, Vec<u32>> = HashMap::new();
        let mut canonical: HashMap<String, String> = HashMap::new();
        // Reused across photos so the credited-keys set costs one allocation
        // for the whole build rather than one per photo.
        let mut credited: HashSet<String> = HashSet::new();

        for (idx, photo) in all_photos.iter().enumerate() {
            let idx = idx as u32;
            credited.clear();
            for tag in &photo.hierarchical_tags {
                let segs = segments(&tag.full_path);
                let is_hierarchical = segs.len() > 1;
                let leaf_key = text::match_key(&tag.full_path);
                if credited.insert(leaf_key.clone()) {
                    buckets.entry(leaf_key.clone()).or_default().push(idx);
                }
                // Leaf keys: the LAST spelling written wins.
                canonical.insert(leaf_key, tag.full_path.clone());

                if matches_by_prefix(tag.namespace.as_deref()) && is_hierarchical {
                    // From depth 2 only, so the bare namespace is never a
                    // bucket: `Places` alone would collapse every place into
                    // one filter and is not something the UI offers.
                    for depth in 2..segs.len() {
                        let prefix_path = segs[..depth].join("/");
                        let key = text::match_key(&prefix_path);
                        if credited.insert(key.clone()) {
                            buckets.entry(key.clone()).or_default().push(idx);
                        }
                        // Virtual prefix keys: the FIRST spelling wins.
                        canonical.entry(key).or_insert(prefix_path);
                    }
                }
            }
        }

        TagIndex { buckets, canonical }
    }

    /// Photo-table indices credited to `key` (already [`text::match_key`]ed), in
    /// `all_photos` order.
    pub fn indices_for_key(&self, key: &str) -> &[u32] {
        self.buckets.get(key).map_or(&[], Vec::as_slice)
    }

    /// The canonical-cased spelling recorded for `key`.
    pub fn canonical_path(&self, key: &str) -> Option<&str> {
        self.canonical.get(key).map(String::as_str)
    }

    /// Every bucket key, sorted. The live Swift index is a `Dictionary` and has
    /// no order at all; sorting here is what makes a rebuild diffable.
    pub fn keys_sorted(&self) -> Vec<&str> {
        let mut keys: Vec<&str> = self.buckets.keys().map(String::as_str).collect();
        keys.sort_unstable();
        keys
    }

    /// `TagIndex.aggregateTagsAndPeople`: one suggestion per bucket — including
    /// the virtual `Places/*` prefixes no photo carries exactly — plus the
    /// people list with each person's most recent photo date.
    ///
    /// Swift sorts by `count` **alone**, with a non-stable sort, over a
    /// `Dictionary` walk: equal-count entries come out in an order that varies
    /// between processes, and `tag_index.json` records the canonical
    /// `(count desc, id asc)` form instead of a coin flip. This produces that
    /// canonical order directly. It is a tightening, not a divergence — the tie
    /// order was never specified.
    pub fn aggregate(&self, all_photos: &[PhotoFile]) -> (Vec<TagSuggestion>, Vec<TagSuggestion>) {
        let mut tags: Vec<TagSuggestion> = self
            .buckets
            .iter()
            .filter_map(|(key, indices)| {
                let path = self.canonical.get(key)?;
                let tag = HierarchicalTag::new(path);
                Some(TagSuggestion {
                    id: text::match_key(&tag.full_path),
                    display_name: tag.display_name,
                    full_path: tag.full_path,
                    namespace: tag.namespace,
                    count: indices.len(),
                    latest_photo_date: None,
                })
            })
            .collect();
        sort_canonical(&mut tags);

        let people: Vec<TagSuggestion> = tags
            .iter()
            .filter(|t| t.namespace.as_deref().map(text::lowercased).as_deref() == Some("people"))
            .map(|person| {
                let latest = self
                    .indices_for_key(&person.id)
                    .iter()
                    .filter_map(|i| all_photos[*i as usize].date_taken)
                    .map(|d| d.0)
                    .fold(None, |acc: Option<f64>, d| {
                        Some(acc.map_or(d, |a| a.max(d)))
                    });
                TagSuggestion {
                    latest_photo_date: latest,
                    ..person.clone()
                }
            })
            .collect();

        (tags, people)
    }
}

/// `(count desc, id asc)` — the canonical form `tag_index.json` stores.
fn sort_canonical(list: &mut [TagSuggestion]) {
    list.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.id.cmp(&b.id)));
}
