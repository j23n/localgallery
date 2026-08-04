//! `MemoryEngine+Selection.swift` plus the selection tail of `generate`:
//! folder-name dedupe, the seeded jitter, the two penalties, and the greedy
//! cluster-unique top 10.
//!
//! This is where the daily rail actually gets decided, and where a port that
//! got the ladder right and the RNG wrong fails — on **order alone**, because
//! `Memory.score` never carries the jitter.

use std::collections::{HashMap, HashSet};

use gallery_model::{text, AppleDate, SeededRng};

use crate::time::LocalCalendar;
use crate::{GenerationInputs, Memory, MemoryType};

/// `Date.distantPast` in Apple-reference seconds, the sort floor for undated
/// photos.
pub(crate) const DISTANT_PAST: f64 = -63_114_076_800.0;

/// How many memories reach the rail.
pub const MAX_SELECTED: usize = 10;

/// Memories sharing a cluster key are mutually exclusive in one render and
/// share a cool-down: a trip parent (`trip-<key>`) and its sub-trips
/// (`subtrip-<key>-<seg>`) all collapse to `trip-<key>`. Every other id is its
/// own cluster.
///
/// The split is on `-` and is only unambiguous because a trip key's three
/// components are numeric (landmine 5).
pub fn cluster_key(memory_id: &str) -> String {
    if let Some(rest) = memory_id.strip_prefix("subtrip-") {
        let parts: Vec<&str> = rest.split('-').collect();
        if parts.len() >= 4 {
            return format!("trip-{}", parts[..3].join("-"));
        }
    }
    memory_id.to_string()
}

/// Collapse folder memories that share a name to the one with the most photos.
///
/// Compared on `title.lowercased()` and applied **after** `finalize`, so the
/// 75-photo cap can change which folder wins. The survivor keeps its own
/// spelling (landmine 10). Ties keep the earlier candidate — `>` rather than
/// `>=`, and that is load-bearing: it mirrors Swift's `max(by:)`, which returns
/// the first maximal element.
///
/// The key is [`text::match_key`], not a bare `lowercased()`: Swift compared
/// two `String`s, which matches a folder named `Jos\u{00E9}` against one named
/// `Jose\u{0301}` — and on Apple platforms both spellings genuinely occur,
/// because `URL(fileURLWithPath:)` decomposes what the user typed precomposed.
///
/// Insertion order is irrelevant to the output (the filter below walks the
/// original candidate order), which is what lets the index be a plain
/// `HashMap` — the linear `find` it replaces was O(folders²) and folder events
/// are the one candidate class with no upper bound.
fn dedupe_folder_names(candidates: Vec<Memory>) -> Vec<Memory> {
    let mut best: HashMap<String, usize> = HashMap::new();
    for (idx, c) in candidates.iter().enumerate() {
        if c.kind != MemoryType::FolderEvent {
            continue;
        }
        match best.entry(text::match_key(&c.title)) {
            std::collections::hash_map::Entry::Occupied(mut slot) => {
                if c.photo_ids.len() > candidates[*slot.get()].photo_ids.len() {
                    slot.insert(idx);
                }
            }
            std::collections::hash_map::Entry::Vacant(slot) => {
                slot.insert(idx);
            }
        }
    }
    let keep: HashSet<usize> = best.into_values().collect();
    candidates
        .into_iter()
        .enumerate()
        .filter(|(idx, c)| c.kind != MemoryType::FolderEvent || keep.contains(idx))
        .map(|(_, c)| c)
        .collect()
}

/// The selection stage: dedupe, jitter, penalise, sort, then take the top
/// [`MAX_SELECTED`] with one memory per cluster.
pub(crate) fn select(
    inputs: &GenerationInputs,
    cal: &LocalCalendar,
    candidates: Vec<Memory>,
) -> Vec<Memory> {
    let candidates = dedupe_folder_names(candidates);

    // The jitter is drawn in CANDIDATE-ARRAY ORDER, one draw per candidate,
    // before any sorting — and after the folder dedupe, so a dropped duplicate
    // shifts every later candidate's draw. Candidate order is therefore part of
    // the contract: [onThisDay, yearsAgo…, folderEvents…, density…, trips…,
    // birthdays] (landmine 7).
    let mut rng = SeededRng::new(&inputs.seed);
    let six_months_ago = cal.adding_months(inputs.now, -6);
    let cool_down_threshold = cal.adding_days(inputs.now, -3);

    // Both penalty maps are keyed by strings that **embed a `People/*` path**:
    // `birthday-People/Jos\u{00E9}` is a memory id, and `clusterKey` passes it
    // through unchanged. The keys were written by a Swift `Dictionary` and are
    // read back from JSON, so they carry whatever spelling the tag had when the
    // user tapped — while the id generated today carries whatever spelling the
    // sidecar has now. Swift matched the two; byte keys do not. `nfc` (not
    // `match_key`) because case is part of an id: `birthday-People/alice` and
    // `birthday-People/Alice` were two Swift keys and stay two here.
    let seen: HashMap<String, AppleDate> = inputs
        .seen_memory_ids
        .iter()
        .map(|(k, v)| (text::nfc(k), *v))
        .collect();
    let surfaced: HashMap<String, AppleDate> = inputs
        .surfaced_clusters
        .iter()
        .map(|(k, v)| (text::nfc(k), *v))
        .collect();

    let jittered: Vec<f64> = candidates
        .iter()
        .map(|mem| {
            let mut s = mem.score + rng.next_double(12.0);
            // The seen penalty is keyed by memory ID…
            if let Some(last_seen) = seen.get(&text::nfc(&mem.id)) {
                if last_seen.0 > six_months_ago.0 {
                    s -= 30.0;
                }
            }
            // …and the cool-down by CLUSTER, so it hits a trip parent and every
            // sub-trip at once (landmine 8).
            if let Some(last) = surfaced.get(&text::nfc(&cluster_key(&mem.id))) {
                if last.0 > cool_down_threshold.0 {
                    s -= 25.0;
                }
            }
            s
        })
        .collect();

    let mut order: Vec<usize> = (0..candidates.len()).collect();
    order.sort_by(|a, b| jittered[*b].total_cmp(&jittered[*a]));

    let mut selected: Vec<Memory> = Vec::with_capacity(MAX_SELECTED);
    let mut used_clusters: Vec<String> = Vec::with_capacity(MAX_SELECTED);
    for idx in order {
        let cluster = cluster_key(&candidates[idx].id);
        // A cluster is claimed by whoever sorts first and the rest are dropped
        // silently — two generated, scored sub-trips can never appear
        // (landmine 9).
        if used_clusters.contains(&cluster) {
            continue;
        }
        used_clusters.push(cluster);
        selected.push(candidates[idx].clone());
        if selected.len() >= MAX_SELECTED {
            break;
        }
    }
    selected
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_model::StableId;

    /// A folder event titled `title` with `count` photos.
    fn folder(title: &str, count: usize) -> Memory {
        let ids: Vec<StableId> = (0..count)
            .map(|i| StableId::for_photo(&format!("/lib/{title}/{i}.jpg")))
            .collect();
        Memory {
            id: format!("folder-{}", StableId::for_folder(&format!("/lib/{title}"))),
            kind: MemoryType::FolderEvent,
            title: title.to_string(),
            subtitle: None,
            cover_photo_id: ids[0],
            photo_ids: ids,
            date_range: None,
            score: 10.0,
            years_ago: None,
            person_name: None,
        }
    }

    fn titles(memories: Vec<Memory>) -> Vec<String> {
        memories.into_iter().map(|m| m.title).collect()
    }

    /// Landmine 10, restated as the property the `HashMap` rewrite had to keep:
    /// the survivor is the one with the most photos, ties go to the **earlier**
    /// candidate, and the survivor keeps its own spelling.
    #[test]
    fn same_name_folders_collapse_to_the_biggest_and_ties_keep_the_earlier() {
        assert_eq!(
            titles(dedupe_folder_names(vec![
                folder("Holiday", 20),
                folder("holiday", 30),
                folder("Other", 5),
            ])),
            vec!["holiday".to_string(), "Other".to_string()],
            "the bigger one wins and keeps its own casing"
        );
        // Equal counts: `>` not `>=`, so the first candidate holds the slot.
        assert_eq!(
            titles(dedupe_folder_names(vec![
                folder("Holiday", 20),
                folder("HOLIDAY", 20),
                folder("holiday", 20),
            ])),
            vec!["Holiday".to_string()]
        );
        // A later, *smaller* duplicate must not displace an earlier winner.
        assert_eq!(
            titles(dedupe_folder_names(vec![
                folder("Holiday", 30),
                folder("holiday", 20),
            ])),
            vec!["Holiday".to_string()]
        );
    }

    /// The key is a canonical fold, not a byte-wise `lowercased()`: two folders
    /// whose names differ only in Unicode normalisation are the same name to
    /// Swift, and both spellings genuinely occur on Apple platforms because
    /// `URL(fileURLWithPath:)` decomposes.
    #[test]
    fn folder_titles_dedupe_across_normalisation_forms() {
        let out = dedupe_folder_names(vec![
            folder("Jose\u{0301}", 10), // NFD, as read from disk
            folder("Jos\u{00E9}", 25),  // NFC, as typed
        ]);
        assert_eq!(titles(out), vec!["Jos\u{00E9}".to_string()]);
        // Genuinely different names still survive side by side.
        assert_eq!(
            titles(dedupe_folder_names(vec![
                folder("Jose", 10),
                folder("Jos\u{00E9}", 25)
            ]))
            .len(),
            2
        );
    }

    /// Only folder events take part, and the survivors keep their position in
    /// the candidate array — which the jitter draw sequence depends on
    /// (landmine 7).
    #[test]
    fn the_dedupe_preserves_candidate_order_and_ignores_other_kinds() {
        let mut trip = folder("Holiday", 40);
        trip.kind = MemoryType::Trip;
        let out = dedupe_folder_names(vec![folder("Holiday", 5), trip, folder("holiday", 9)]);
        assert_eq!(
            titles(out),
            // The trip keeps its slot and its name even though a folder event
            // shares it; the smaller of the two folders is the only casualty.
            vec!["Holiday".to_string(), "holiday".to_string()]
        );
    }

    #[test]
    fn subtrips_collapse_onto_their_parent() {
        assert_eq!(cluster_key("subtrip-2023-9-1-cl"), "trip-2023-9-1");
        assert_eq!(cluster_key("trip-2023-9-1"), "trip-2023-9-1");
        assert_eq!(cluster_key("onThisDay-2024-06-11"), "onThisDay-2024-06-11");
        // A malformed sub-trip id is its own cluster rather than a panic.
        assert_eq!(cluster_key("subtrip-oops"), "subtrip-oops");
    }
}
