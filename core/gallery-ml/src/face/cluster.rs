//! Deterministic face clustering: incremental assignment and a full
//! chinese-whispers pass.
//!
//! Pure functions over embeddings and cluster snapshots. Nothing here touches
//! SQLite, the filesystem, or a model — which is what makes "shuffle the input,
//! get the same partition" a property a test can actually assert.
//!
//! # Two modes, and why both exist
//!
//! **Incremental** ([`assign`]) is what a run does to each new face: compare it
//! against every cluster centroid, join the best one that clears its threshold,
//! else seed a new cluster. It is *O(faces × clusters)*, it never revisits a
//! decision, and it is what makes a 200-photo import feel instant. Its weakness
//! is inherent: a partition built one face at a time depends on the order the
//! faces arrived in, and two devices will not import in the same order.
//!
//! **Full** ([`chinese_whispers`]) is what reconciles that. It rebuilds the
//! partition of the *unlabeled* faces from scratch, from the face set alone,
//! with no reference to the current clusters — so two devices holding the same
//! faces produce the same partition regardless of how they got there. It never
//! touches named clusters; those are the user's, and the most it will say about
//! them is a merge *proposal*.
//!
//! # Why chinese whispers and not agglomerative clustering
//!
//! The number of people in a library is unknown, so k-means and friends are
//! out. Agglomerative-with-a-cutoff is the usual alternative and would work,
//! but it is *O(n²)* memory in the linkage matrix and needs a full distance
//! matrix up front; chinese whispers is *O(edges)* per round on a thresholded
//! graph and converges in a handful of rounds. It is also what dlib's
//! well-travelled face-clustering example uses, on the same kind of embedding.
//!
//! # Determinism
//!
//! Chinese whispers is normally randomized — that is the point of the
//! algorithm, and the reason it escapes local optima. Randomized is not
//! available here, so:
//!
//! * nodes are sorted by `(content_hash, face_idx)` before anything else, so
//!   the caller's ordering is erased;
//! * the "random" visit order is a fixed permutation of that sorted list,
//!   produced by a SplitMix64 stream seeded from the manifest's `cw_seed`. It
//!   is unpredictable enough to break the pathological orders a sorted walk
//!   would hit, and identical on every device;
//! * label ties are broken toward the **smallest** label, never toward "the
//!   first one seen";
//! * the loop stops when a round changes nothing, so the iteration cap is a
//!   bound rather than a source of variation.
//!
//! Float arithmetic is the one remaining wobble: a cosine computed on two
//! architectures can differ in the last bit, and a comparison exactly at the
//! threshold could then fall either way. That is the same exposure the tagger
//! has, and the same doctrine covers it (overview §5): thresholds are set with
//! margins far larger than a rounding step, and the durable output — a named
//! person in a sidecar — travels between devices rather than being recomputed.

use std::collections::BTreeMap;

use crate::cache::{ClusterRow, ClusterState};
use crate::pack::ClusteringConfig;

/// Cosine similarity of two vectors that are already L2-normalized.
///
/// Accumulates in `f64`: at 512 dimensions the `f32` accumulation error is
/// around 1e-6, which is small but is *order-dependent*, and this value is
/// compared against a fixed threshold on more than one machine.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return -1.0;
    }
    let dot: f64 = a
        .iter()
        .zip(b)
        .map(|(x, y)| f64::from(*x) * f64::from(*y))
        .sum();
    dot as f32
}

/// L2-normalized mean of `vectors`, or `None` if there is nothing to average.
pub fn centroid<'a>(vectors: impl IntoIterator<Item = &'a [f32]>) -> Option<Vec<f32>> {
    let mut sum: Vec<f64> = Vec::new();
    let mut n = 0usize;
    for v in vectors {
        if sum.is_empty() {
            sum = vec![0.0; v.len()];
        } else if sum.len() != v.len() {
            return None;
        }
        for (acc, x) in sum.iter_mut().zip(v) {
            *acc += f64::from(*x);
        }
        n += 1;
    }
    if n == 0 {
        return None;
    }
    let norm = sum.iter().map(|x| x * x).sum::<f64>().sqrt();
    // NaN-safe: a `norm <= EPSILON` test alone would let a NaN through.
    if norm.is_nan() || norm <= f64::EPSILON {
        return None;
    }
    Some(sum.iter().map(|x| (x / norm) as f32).collect())
}

/// What [`assign`] decided about one face.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Assignment {
    /// Join this cluster.
    Join(i64),
    /// Nothing was close enough; the caller should create a cluster.
    Seed,
}

/// Pick the cluster a face should join, or say it should seed a new one.
///
/// Named clusters are held to [`ClusteringConfig::auto`] and unlabeled ones to
/// [`ClusteringConfig::join`], with `auto ≥ join` enforced at pack load. A
/// named cluster that clears its (higher) bar wins over an unlabeled one even
/// if the unlabeled one is a hair closer: the whole purpose of naming a cluster
/// is that subsequent faces of that person land in it.
///
/// [`ClusterState::Ignored`] clusters are candidates too. Not joining them
/// would mean every dismissed non-face — a pattern on a shirt, a face on a
/// poster — coming back as a brand-new cluster on the next run, forever.
pub fn assign(embedding: &[f32], clusters: &[ClusterRow], cfg: &ClusteringConfig) -> Assignment {
    let mut best: Option<(i64, f32)> = None;
    let mut best_named: Option<(i64, f32)> = None;

    for cluster in clusters {
        if cluster.centroid.len() != embedding.len() {
            continue;
        }
        let sim = cosine(embedding, &cluster.centroid);
        let (bar, slot) = match cluster.state {
            ClusterState::Named => (cfg.auto, &mut best_named),
            _ => (cfg.join, &mut best),
        };
        if sim < bar {
            continue;
        }
        // Ties go to the lower id: a stable rule, and the lower id is the older
        // cluster, so a face joins the established group rather than a splinter.
        match slot {
            Some((id, s)) if *s > sim || (*s == sim && *id <= cluster.id) => {}
            _ => *slot = Some((cluster.id, sim)),
        }
    }

    match best_named.or(best) {
        Some((id, _)) => Assignment::Join(id),
        None => Assignment::Seed,
    }
}

/// A face as the clustering sees it: an identity and a vector.
#[derive(Debug, Clone, PartialEq)]
pub struct FaceVec {
    /// SHA-256 of the photo's bytes.
    pub content_hash: [u8; 32],
    /// Index within that photo's detections.
    pub face_idx: u32,
    /// L2-normalized embedding.
    pub embedding: Vec<f32>,
}

impl FaceVec {
    fn key(&self) -> ([u8; 32], u32) {
        (self.content_hash, self.face_idx)
    }
}

/// Partition `faces` into groups by chinese whispers.
///
/// Returns one group per cluster, each a list of `(content_hash, face_idx)`
/// sorted ascending, and the groups themselves sorted by their first member —
/// so the result is a canonical form of the partition, not merely *a*
/// representation of it. Singletons are included: a face that matched nothing
/// is a cluster of one, and the caller decides what to do about it.
pub fn chinese_whispers(faces: &[FaceVec], cfg: &ClusteringConfig) -> Vec<Vec<([u8; 32], u32)>> {
    // 1. Canonical node order. Everything below indexes into `nodes`, so this
    //    is the single place the caller's ordering stops mattering.
    let mut nodes: Vec<&FaceVec> = faces.iter().collect();
    nodes.sort_by_key(|f| f.key());
    nodes.dedup_by_key(|f| f.key());
    let n = nodes.len();
    if n == 0 {
        return Vec::new();
    }

    // 2. Thresholded similarity graph. O(n²) similarities, but only edges above
    //    the threshold are kept, and a face library's graph is very sparse.
    let mut adjacency: Vec<Vec<(usize, f32)>> = vec![Vec::new(); n];
    for i in 0..n {
        for j in (i + 1)..n {
            let sim = cosine(&nodes[i].embedding, &nodes[j].embedding);
            if sim >= cfg.edge {
                adjacency[i].push((j, sim));
                adjacency[j].push((i, sim));
            }
        }
    }

    // 3. Label propagation over a fixed pseudo-random visit order.
    let mut labels: Vec<usize> = (0..n).collect();
    let order = permutation(n, cfg.cw_seed);
    for _ in 0..cfg.cw_iterations {
        let mut changed = false;
        for &i in &order {
            if adjacency[i].is_empty() {
                continue;
            }
            let mut weights: BTreeMap<usize, f64> = BTreeMap::new();
            for &(j, sim) in &adjacency[i] {
                *weights.entry(labels[j]).or_insert(0.0) += f64::from(sim);
            }
            // BTreeMap iterates ascending, and the comparison is strict, so an
            // exact tie keeps the smallest label. That is the tie-break rule.
            let mut best = (labels[i], f64::NEG_INFINITY);
            for (label, weight) in &weights {
                if *weight > best.1 {
                    best = (*label, *weight);
                }
            }
            if best.0 != labels[i] {
                labels[i] = best.0;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }

    // 4. Canonical output.
    let mut groups: BTreeMap<usize, Vec<([u8; 32], u32)>> = BTreeMap::new();
    for (i, label) in labels.iter().enumerate() {
        groups.entry(*label).or_default().push(nodes[i].key());
    }
    let mut out: Vec<Vec<([u8; 32], u32)>> = groups.into_values().collect();
    for group in &mut out {
        group.sort_unstable();
    }
    out.sort_by(|a, b| a[0].cmp(&b[0]));
    out
}

/// Cluster pairs whose centroids are similar enough to be worth asking about.
///
/// Ordered strongest first, with `(a, b)` normalized so `a < b`. Ignored
/// clusters are excluded: proposing to merge two things the user has already
/// dismissed is noise.
pub fn merge_proposals(clusters: &[ClusterRow], cfg: &ClusteringConfig) -> Vec<(i64, i64, f32)> {
    let live: Vec<&ClusterRow> = clusters
        .iter()
        .filter(|c| c.state != ClusterState::Ignored && !c.centroid.is_empty())
        .collect();
    let mut out = Vec::new();
    for (i, a) in live.iter().enumerate() {
        for b in &live[i + 1..] {
            // Two *named* clusters both having members of one person is exactly
            // the case the UI needs to surface, so they are proposed like any
            // other pair — the rule is that nothing is ever merged automatically.
            let sim = cosine(&a.centroid, &b.centroid);
            if sim >= cfg.merge {
                let (lo, hi) = if a.id <= b.id {
                    (a.id, b.id)
                } else {
                    (b.id, a.id)
                };
                out.push((lo, hi, sim));
            }
        }
    }
    out.sort_by(|x, y| {
        y.2.total_cmp(&x.2)
            .then_with(|| x.0.cmp(&y.0))
            .then_with(|| x.1.cmp(&y.1))
    });
    out
}

/// A fixed permutation of `0..n`, seeded.
///
/// Fisher-Yates driven by SplitMix64 — eight lines, no dependency, and
/// specified precisely enough that a future port can reproduce it exactly. That
/// last property is why this is not `rand`: a crate's default generator is free
/// to change its algorithm in a minor release, and this permutation is part of
/// the cross-device contract.
fn permutation(n: usize, seed: u64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..n).collect();
    let mut state = seed;
    let mut next = move || {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    };
    for i in (1..n).rev() {
        let j = (next() % (i as u64 + 1)) as usize;
        order.swap(i, j);
    }
    order
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> ClusteringConfig {
        ClusteringConfig::default()
    }

    fn unit(v: &[f32]) -> Vec<f32> {
        let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        v.iter().map(|x| x / norm).collect()
    }

    fn row(id: i64, centroid: Vec<f32>, state: ClusterState) -> ClusterRow {
        ClusterRow {
            id,
            centroid,
            size: 1,
            state,
            person_name: if state == ClusterState::Named {
                Some(format!("P{id}"))
            } else {
                None
            },
            pinned: false,
        }
    }

    fn face(hash: u8, idx: u32, embedding: Vec<f32>) -> FaceVec {
        FaceVec {
            content_hash: [hash; 32],
            face_idx: idx,
            embedding,
        }
    }

    /// Two well-separated identities plus noise around each, in 4-D.
    fn two_identities() -> Vec<FaceVec> {
        let mut out = Vec::new();
        for i in 0..5u8 {
            let d = f32::from(i) * 0.02;
            out.push(face(i, 0, unit(&[1.0, d, 0.0, 0.0])));
        }
        for i in 0..5u8 {
            let d = f32::from(i) * 0.02;
            out.push(face(100 + i, 0, unit(&[0.0, 0.0, 1.0, d])));
        }
        out
    }

    #[test]
    fn cosine_is_a_dot_product_on_unit_vectors() {
        assert!((cosine(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 1e-6);
        assert!(cosine(&[1.0, 0.0], &[0.0, 1.0]).abs() < 1e-6);
        assert!((cosine(&[1.0, 0.0], &[-1.0, 0.0]) + 1.0).abs() < 1e-6);
        // Mismatched dimensions are "as far apart as possible", not a panic.
        assert_eq!(cosine(&[1.0], &[1.0, 0.0]), -1.0);
    }

    #[test]
    fn a_centroid_is_the_normalized_mean() {
        let c = centroid([[1.0f32, 0.0].as_slice(), [0.0, 1.0].as_slice()]).unwrap();
        assert!((c[0] - c[1]).abs() < 1e-6);
        assert!((c[0] * c[0] + c[1] * c[1] - 1.0).abs() < 1e-6);
        assert!(centroid(std::iter::empty()).is_none());
        // Opposing vectors average to zero, which has no direction.
        assert!(centroid([[1.0f32, 0.0].as_slice(), [-1.0, 0.0].as_slice()]).is_none());
    }

    #[test]
    fn a_face_far_from_everything_seeds_a_new_cluster() {
        let clusters = vec![row(1, vec![1.0, 0.0], ClusterState::Unlabeled)];
        assert_eq!(assign(&[0.0, 1.0], &clusters, &cfg()), Assignment::Seed);
        assert_eq!(assign(&[1.0, 0.0], &clusters, &cfg()), Assignment::Join(1));
    }

    /// The rule that stops a wrong sidecar write: a named cluster is only
    /// joined at the higher bar.
    #[test]
    fn a_named_cluster_holds_a_face_to_the_stricter_threshold() {
        let c = cfg();
        let named = vec![row(1, vec![1.0, 0.0], ClusterState::Named)];
        // Similarity between join (0.42) and auto (0.55): close enough for an
        // anonymous cluster, not close enough to write somebody's name.
        let between = unit(&[0.5, 1.0]);
        assert!((0.42..0.55).contains(&cosine(&between, &[1.0, 0.0])));
        assert_eq!(assign(&between, &named, &c), Assignment::Seed);

        let unlabeled = vec![row(1, vec![1.0, 0.0], ClusterState::Unlabeled)];
        assert_eq!(assign(&between, &unlabeled, &c), Assignment::Join(1));
    }

    /// Once a face clears the higher bar, the named cluster wins even against
    /// a marginally closer anonymous one — that is what naming is *for*.
    #[test]
    fn a_qualifying_named_cluster_wins_over_a_closer_unlabeled_one() {
        let clusters = vec![
            row(1, unit(&[1.0, 0.02]), ClusterState::Unlabeled),
            row(2, vec![1.0, 0.0], ClusterState::Named),
        ];
        assert_eq!(
            assign(&unit(&[1.0, 0.02]), &clusters, &cfg()),
            Assignment::Join(2)
        );
    }

    #[test]
    fn a_dismissed_cluster_still_absorbs_its_faces() {
        // Otherwise every "not a person" the user dismissed comes back as a
        // brand-new cluster on the next run.
        let clusters = vec![row(1, vec![1.0, 0.0], ClusterState::Ignored)];
        assert_eq!(assign(&[1.0, 0.0], &clusters, &cfg()), Assignment::Join(1));
    }

    #[test]
    fn an_exact_tie_goes_to_the_older_cluster() {
        let clusters = vec![
            row(7, vec![1.0, 0.0], ClusterState::Unlabeled),
            row(3, vec![1.0, 0.0], ClusterState::Unlabeled),
        ];
        assert_eq!(assign(&[1.0, 0.0], &clusters, &cfg()), Assignment::Join(3));
    }

    #[test]
    fn a_cluster_of_a_different_dimension_is_ignored_not_matched() {
        let clusters = vec![row(1, vec![1.0, 0.0, 0.0], ClusterState::Unlabeled)];
        assert_eq!(assign(&[1.0, 0.0], &clusters, &cfg()), Assignment::Seed);
    }

    /// The headline property.
    #[test]
    fn shuffling_the_input_produces_an_identical_partition() {
        let faces = two_identities();
        let reference = chinese_whispers(&faces, &cfg());

        // Every rotation, plus a reversal, plus an interleave: enough distinct
        // orders that an order-sensitive implementation could not survive.
        for shift in 0..faces.len() {
            let mut shuffled: Vec<FaceVec> = faces[shift..].to_vec();
            shuffled.extend_from_slice(&faces[..shift]);
            assert_eq!(
                chinese_whispers(&shuffled, &cfg()),
                reference,
                "shift {shift}"
            );
        }
        let mut reversed = faces.clone();
        reversed.reverse();
        assert_eq!(chinese_whispers(&reversed, &cfg()), reference);

        let mut interleaved = Vec::new();
        let (a, b) = faces.split_at(faces.len() / 2);
        for i in 0..a.len().max(b.len()) {
            if let Some(f) = b.get(i) {
                interleaved.push(f.clone());
            }
            if let Some(f) = a.get(i) {
                interleaved.push(f.clone());
            }
        }
        assert_eq!(chinese_whispers(&interleaved, &cfg()), reference);
    }

    #[test]
    fn two_separated_identities_come_back_as_two_groups() {
        let groups = chinese_whispers(&two_identities(), &cfg());
        assert_eq!(groups.len(), 2, "{groups:?}");
        assert!(groups.iter().all(|g| g.len() == 5), "{groups:?}");
        // Group members are sorted, and the groups are ordered by first member.
        assert!(groups[0][0] < groups[1][0]);
        for group in &groups {
            assert!(group.windows(2).all(|w| w[0] < w[1]));
        }
    }

    #[test]
    fn a_face_matching_nothing_is_its_own_group() {
        let mut faces = two_identities();
        faces.push(face(200, 0, unit(&[0.0, 1.0, 0.0, -1.0])));
        let groups = chinese_whispers(&faces, &cfg());
        assert_eq!(groups.len(), 3);
        assert_eq!(groups.iter().filter(|g| g.len() == 1).count(), 1);
    }

    #[test]
    fn an_empty_input_produces_no_groups() {
        assert!(chinese_whispers(&[], &cfg()).is_empty());
    }

    /// Every face lands in exactly one group, however the graph came out.
    #[test]
    fn the_partition_covers_every_face_exactly_once() {
        let faces = two_identities();
        let groups = chinese_whispers(&faces, &cfg());
        let mut seen: Vec<([u8; 32], u32)> = groups.into_iter().flatten().collect();
        seen.sort_unstable();
        let mut expected: Vec<([u8; 32], u32)> =
            faces.iter().map(|f| (f.content_hash, f.face_idx)).collect();
        expected.sort_unstable();
        assert_eq!(seen, expected);
    }

    #[test]
    fn duplicate_faces_in_the_input_are_collapsed() {
        let mut faces = two_identities();
        faces.push(faces[0].clone());
        let groups = chinese_whispers(&faces, &cfg());
        assert_eq!(groups.iter().map(Vec::len).sum::<usize>(), 10);
    }

    /// With a threshold no pair can clear, the graph has no edges at all and
    /// every face is its own group. This is the sanity check on the graph
    /// construction — it is deliberately the *provable* end of the range:
    /// chinese whispers is a heuristic, so "a looser threshold merges more" is
    /// a tendency and not a theorem, and asserting it would be asserting
    /// something the algorithm does not promise.
    #[test]
    fn a_threshold_no_pair_can_clear_leaves_every_face_alone() {
        let faces = two_identities();
        let strict = ClusteringConfig { edge: 1.1, ..cfg() };
        assert_eq!(chinese_whispers(&faces, &strict).len(), faces.len());
    }

    #[test]
    fn the_permutation_is_a_permutation_and_is_seed_stable() {
        for n in [0usize, 1, 2, 10, 257] {
            let p = permutation(n, 20_260_803);
            let mut sorted = p.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, (0..n).collect::<Vec<_>>());
            assert_eq!(p, permutation(n, 20_260_803));
        }
        assert_ne!(permutation(64, 1), permutation(64, 2));
        // Not the identity — the shuffle has to actually shuffle.
        assert_ne!(permutation(64, 20_260_803), (0..64).collect::<Vec<_>>());
    }

    #[test]
    fn merge_proposals_are_ordered_normalized_and_exclude_the_dismissed() {
        let clusters = vec![
            row(1, vec![1.0, 0.0], ClusterState::Unlabeled),
            row(2, unit(&[1.0, 0.05]), ClusterState::Named),
            row(3, vec![0.0, 1.0], ClusterState::Unlabeled),
            row(4, vec![1.0, 0.0], ClusterState::Ignored),
        ];
        let proposals = merge_proposals(&clusters, &cfg());
        assert_eq!(proposals.len(), 1);
        assert_eq!((proposals[0].0, proposals[0].1), (1, 2));
        assert!(proposals[0].2 > 0.6);
    }

    #[test]
    fn merge_proposals_are_sorted_strongest_first() {
        let clusters = vec![
            row(1, vec![1.0, 0.0], ClusterState::Unlabeled),
            row(2, unit(&[1.0, 0.30]), ClusterState::Unlabeled),
            row(3, unit(&[1.0, 0.05]), ClusterState::Unlabeled),
        ];
        let proposals = merge_proposals(&clusters, &cfg());
        assert!(proposals.len() >= 2);
        assert!(proposals.windows(2).all(|w| w[0].2 >= w[1].2));
    }

    /// Incremental and batch will not always agree — that is why the full pass
    /// exists — but on well-separated identities they must, and the bound this
    /// asserts is the one the engine relies on: no *merging* of identities that
    /// the batch pass keeps apart.
    #[test]
    fn incremental_assignment_matches_the_batch_partition_on_separated_identities() {
        let faces = two_identities();
        let mut clusters: Vec<ClusterRow> = Vec::new();
        let mut members: BTreeMap<i64, Vec<Vec<f32>>> = BTreeMap::new();
        let mut next_id = 1i64;

        for f in &faces {
            match assign(&f.embedding, &clusters, &cfg()) {
                Assignment::Join(id) => {
                    members.get_mut(&id).unwrap().push(f.embedding.clone());
                    let vectors: Vec<&[f32]> = members[&id].iter().map(Vec::as_slice).collect();
                    let c = centroid(vectors).unwrap();
                    let row = clusters.iter_mut().find(|c| c.id == id).unwrap();
                    row.centroid = c;
                    row.size += 1;
                }
                Assignment::Seed => {
                    clusters.push(row(next_id, f.embedding.clone(), ClusterState::Unlabeled));
                    members.insert(next_id, vec![f.embedding.clone()]);
                    next_id += 1;
                }
            }
        }

        assert_eq!(clusters.len(), 2, "incremental split the identities");
        let batch = chinese_whispers(&faces, &cfg());
        assert_eq!(batch.len(), clusters.len());
        for cluster in &clusters {
            assert_eq!(cluster.size, 5);
        }
    }
}
