//! Which of two face groups survives a user merge.
//!
//! The write (`merge_clusters(into, from)`) is directional and carries no
//! policy. Every UI — iOS review, Linux review, naming onto an existing
//! person — has to pick the same survivor or the same pair merges
//! differently depending on where the user tapped.

/// The cluster that keeps its id and the one that disappears.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClusterMerge {
    /// Keeps its id, its name, and absorbs the other group.
    pub survivor_id: i64,
    /// Disappears; its faces move onto [`Self::survivor_id`].
    pub absorbed_id: i64,
}

/// Decide which of two clusters survives a merge.
///
/// `None` when they are the same group — the write refuses a self-merge,
/// and a button that cannot work should not be drawn.
///
/// The rule, in order:
///
/// 1. A **named** group survives an unnamed one.
/// 2. Between two named or two unnamed groups, the larger survives.
/// 3. Size ties break on the lower id so the answer does not depend on
///    list order.
pub fn cluster_merge_direction(
    a_id: i64,
    a_name: Option<&str>,
    a_size: u32,
    b_id: i64,
    b_name: Option<&str>,
    b_size: u32,
) -> Option<ClusterMerge> {
    if a_id == b_id {
        return None;
    }
    let a_named = a_name.map(str::trim).filter(|s| !s.is_empty()).is_some();
    let b_named = b_name.map(str::trim).filter(|s| !s.is_empty()).is_some();
    let a_wins = match (a_named, b_named) {
        (true, false) => true,
        (false, true) => false,
        _ => (a_size, b_id) > (b_size, a_id),
    };
    if a_wins {
        Some(ClusterMerge {
            survivor_id: a_id,
            absorbed_id: b_id,
        })
    } else {
        Some(ClusterMerge {
            survivor_id: b_id,
            absorbed_id: a_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_named_group_survives_an_unnamed_one_whatever_the_sizes() {
        let decided = cluster_merge_direction(1, Some("Ada"), 2, 2, None, 200).unwrap();
        assert_eq!(decided.survivor_id, 1);
        assert_eq!(decided.absorbed_id, 2);
        let flipped = cluster_merge_direction(2, None, 200, 1, Some("Ada"), 2).unwrap();
        assert_eq!(flipped.survivor_id, 1);
    }

    #[test]
    fn between_two_named_groups_the_bigger_one_keeps_its_name() {
        let decided = cluster_merge_direction(3, Some("Grace"), 4, 9, Some("Ada"), 30).unwrap();
        assert_eq!(decided.survivor_id, 9);
        assert_eq!(decided.absorbed_id, 3);
    }

    #[test]
    fn a_size_tie_is_broken_by_the_lower_id() {
        let a = cluster_merge_direction(4, None, 5, 7, None, 5).unwrap();
        let b = cluster_merge_direction(7, None, 5, 4, None, 5).unwrap();
        assert_eq!(a.survivor_id, b.survivor_id);
        assert_eq!(a.survivor_id, 4);
    }

    #[test]
    fn a_group_cannot_merge_with_itself() {
        assert!(cluster_merge_direction(5, Some("Ada"), 2, 5, Some("Ada"), 2).is_none());
    }
}
