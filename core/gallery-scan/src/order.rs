//! Folder ordering: a port of `String.localizedStandardCompare`.
//!
//! Subfolder order **is** part of the contract (fixture landmine 21) — the
//! grid renders folders in it, and it must not drift between scans or between
//! platforms. Within-folder photo order is *not*; it is whatever the directory
//! listing produced, and the fixtures sort those lists rather than pin them.
//!
//! # What this is and is not
//!
//! `localizedStandardCompare` is `compare(_:options:range:locale:)` with
//! case-insensitive, numeric, width-insensitive and forced ordering, in the
//! **current locale**. This implements the first three plus the tiebreak; it
//! does not implement locale-sensitive collation, which needs ICU. The
//! difference shows up only where a locale reorders letters against Unicode
//! order (Swedish `ä` after `z`, Czech `ch` after `h`), for which no fixture
//! exists — see the port notes.

use std::cmp::Ordering;

/// Finder-style comparison: case-insensitive, with digit runs compared as
/// numbers so `IMG_2` sorts before `IMG_10`.
pub fn localized_standard_compare(a: &str, b: &str) -> Ordering {
    let mut left = a.char_indices().peekable();
    let mut right = b.char_indices().peekable();

    loop {
        let (li, lc) = match left.peek().copied() {
            Some(v) => v,
            None => {
                return if right.peek().is_none() {
                    // Equal under every option — "forced ordering" then falls
                    // back to a literal comparison so the result is still a
                    // total order and a sort is still deterministic.
                    a.cmp(b)
                } else {
                    Ordering::Less
                };
            }
        };
        let Some((ri, rc)) = right.peek().copied() else {
            return Ordering::Greater;
        };

        if lc.is_ascii_digit() && rc.is_ascii_digit() {
            let lhs = digit_run(a, li);
            let rhs = digit_run(b, ri);
            match compare_numeric(lhs, rhs) {
                Ordering::Equal => {}
                other => return other,
            }
            advance(&mut left, lhs.len());
            advance(&mut right, rhs.len());
            continue;
        }

        match fold(lc).cmp(&fold(rc)) {
            Ordering::Equal => {
                left.next();
                right.next();
            }
            other => return other,
        }
    }
}

/// The maximal run of ASCII digits starting at `start`.
fn digit_run(s: &str, start: usize) -> &str {
    let end = s[start..]
        .find(|c: char| !c.is_ascii_digit())
        .map_or(s.len(), |off| start + off);
    &s[start..end]
}

/// Compare two digit runs by value, ignoring leading zeros.
fn compare_numeric(a: &str, b: &str) -> Ordering {
    let a_trimmed = a.trim_start_matches('0');
    let b_trimmed = b.trim_start_matches('0');
    a_trimmed
        .len()
        .cmp(&b_trimmed.len())
        .then_with(|| a_trimmed.cmp(b_trimmed))
}

fn advance(iter: &mut std::iter::Peekable<std::str::CharIndices<'_>>, bytes: usize) {
    let mut consumed = 0;
    while consumed < bytes {
        match iter.next() {
            Some((_, c)) => consumed += c.len_utf8(),
            None => break,
        }
    }
}

/// Case folding, one character at a time.
///
/// A per-character fold, not a full Unicode case fold: `ß` does not become
/// `ss` here. Foundation's is full, but the two only disagree on strings that
/// are already ordering ties, where the literal tiebreak takes over.
fn fold(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

/// Sort folder names into the order the tree renders them in.
pub fn sort_names(names: &mut [String]) {
    names.sort_by(|a, b| localized_standard_compare(a, b));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(input: &[&str]) -> Vec<String> {
        let mut names: Vec<String> = input.iter().map(|s| s.to_string()).collect();
        sort_names(&mut names);
        names
    }

    #[test]
    fn the_fixture_trees_folders_come_out_in_the_pinned_order() {
        assert_eq!(
            sorted(&["Unicode", "Nested", "Media", "Locked", "Junk", "Empty", "Added"]),
            vec!["Added", "Empty", "Junk", "Locked", "Media", "Nested", "Unicode"]
        );
    }

    #[test]
    fn digit_runs_compare_as_numbers() {
        assert_eq!(
            sorted(&["IMG_10", "IMG_2", "IMG_1"]),
            vec!["IMG_1", "IMG_2", "IMG_10"],
            "a plain lexicographic sort puts IMG_10 second"
        );
        assert_eq!(
            sorted(&["2020", "999", "10000"]),
            vec!["999", "2020", "10000"]
        );
    }

    #[test]
    fn comparison_is_case_insensitive_with_a_deterministic_tiebreak() {
        assert_eq!(sorted(&["beta", "Alpha"]), vec!["Alpha", "beta"]);
        // "a" and "A" tie under the options; forced ordering still picks one,
        // and picks the same one every run.
        let order = localized_standard_compare("a", "A");
        assert_ne!(order, Ordering::Equal);
        assert_eq!(order, localized_standard_compare("a", "A"));
    }

    #[test]
    fn leading_zeros_do_not_change_the_value() {
        assert_eq!(localized_standard_compare("007", "7"), "007".cmp("7"));
        assert_eq!(localized_standard_compare("008", "7"), Ordering::Greater);
        assert_eq!(localized_standard_compare("07", "008"), Ordering::Less);
    }

    #[test]
    fn a_prefix_sorts_before_the_string_that_extends_it() {
        assert_eq!(sorted(&["Trip 2021", "Trip"]), vec!["Trip", "Trip 2021"]);
    }

    #[test]
    fn non_ascii_names_still_produce_a_total_order() {
        // No locale collation, but the result must be stable and antisymmetric
        // or the folder grid reshuffles itself between scans.
        let names = ["café", "cafe\u{301}", "Zebra", "äpple", "apple"];
        for a in names {
            for b in names {
                let forward = localized_standard_compare(a, b);
                let backward = localized_standard_compare(b, a);
                assert_eq!(forward, backward.reverse(), "{a} vs {b}");
            }
        }
    }
}
