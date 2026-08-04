//! `MemoryEngine+Selection.swift` plus the selection tail of `generate`:
//! folder-name dedupe, the seeded jitter, the two penalties, and the greedy
//! cluster-unique top 10.
//!
//! This is where the daily rail actually gets decided, and where a port that
//! got the ladder right and the RNG wrong fails — on **order alone**, because
//! `Memory.score` never carries the jitter.

use gallery_model::SeededRng;

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
/// spelling (landmine 10). Ties keep the earlier candidate.
fn dedupe_folder_names(candidates: Vec<Memory>) -> Vec<Memory> {
    let mut best: Vec<(String, usize)> = Vec::new();
    for (idx, c) in candidates.iter().enumerate() {
        if c.kind != MemoryType::FolderEvent {
            continue;
        }
        let key = c.title.to_lowercase();
        match best.iter_mut().find(|(k, _)| *k == key) {
            Some((_, slot)) => {
                if c.photo_ids.len() > candidates[*slot].photo_ids.len() {
                    *slot = idx;
                }
            }
            None => best.push((key, idx)),
        }
    }
    let keep: Vec<usize> = best.into_iter().map(|(_, i)| i).collect();
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

    let jittered: Vec<f64> = candidates
        .iter()
        .map(|mem| {
            let mut s = mem.score + rng.next_double(12.0);
            // The seen penalty is keyed by memory ID…
            if let Some(last_seen) = inputs.seen_memory_ids.get(&mem.id) {
                if last_seen.0 > six_months_ago.0 {
                    s -= 30.0;
                }
            }
            // …and the cool-down by CLUSTER, so it hits a trip parent and every
            // sub-trip at once (landmine 8).
            if let Some(last) = inputs.surfaced_clusters.get(&cluster_key(&mem.id)) {
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

    #[test]
    fn subtrips_collapse_onto_their_parent() {
        assert_eq!(cluster_key("subtrip-2023-9-1-cl"), "trip-2023-9-1");
        assert_eq!(cluster_key("trip-2023-9-1"), "trip-2023-9-1");
        assert_eq!(cluster_key("onThisDay-2024-06-11"), "onThisDay-2024-06-11");
        // A malformed sub-trip id is its own cluster rather than a panic.
        assert_eq!(cluster_key("subtrip-oops"), "subtrip-oops");
    }
}
