//! Swift `String` semantics for keys and comparisons.
//!
//! The one thing a Rust port is most likely to get wrong. Swift's `String`
//! compares — and hashes — by **canonical equivalence**, so `Set<String>`,
//! `Dictionary` keys, `==` and `contains` all treat a precomposed
//! `caf\u{00E9}` and a decomposed `cafe\u{0301}` as the same string. A
//! byte-keyed Rust `HashMap` splits them, silently, and nothing fails loudly
//! when it does: an accented person's name stops matching their contact, an
//! accented tag path stops finding its photos.
//!
//! This module lives in `gallery-model` rather than in one of its consumers
//! because both `gallery-index` (search corpus, tag buckets) and
//! `gallery-memories` (hidden people, contact lookup, folder-title dedupe) need
//! exactly the same fold, and two copies would eventually disagree.
//!
//! Three folds, and the difference between them matters:
//!
//! | fold | case | use |
//! |---|---|---|
//! | [`nfc`] | preserved | keys where case is meaningful: memory ids, cluster keys, `People/*` tag paths |
//! | [`match_key`] | lowercased | keys Swift itself lowercased first: tag buckets, the corpus, contact names |
//! | [`collation_key`] | lowercased + accents stripped | *ordering* only — an approximation of `localizedCaseInsensitiveCompare`, never an identity |

use unicode_normalization::UnicodeNormalization;

/// Swift's `lowercased()`: the full, **locale-independent** Unicode lowercase
/// mapping. Rust's `str::to_lowercase` is the same mapping, including the
/// special case that sends `İ` (U+0130) to `i` + U+0307.
pub fn lowercased(s: &str) -> String {
    s.to_lowercase()
}

/// NFC without a case fold — for keys that must keep their spelling.
///
/// This is the fold to reach for when replacing a Swift `Set<String>` or
/// `Dictionary` whose keys were **not** lowercased at the call site: it makes
/// the Rust map agree with Swift's canonical-equivalence hashing without
/// merging keys Swift would have kept apart (`People/alice` and `People/Alice`
/// are two Swift keys, and they stay two here).
pub fn nfc(s: &str) -> String {
    s.nfc().collect()
}

/// Lowercased, then NFC — the form substring matching and tag bucketing run
/// against.
///
/// Applied to both sides of every comparison, so `contains` is a plain byte
/// search over strings already in one canonical spelling.
pub fn match_key(s: &str) -> String {
    s.to_lowercase().nfc().collect()
}

/// A **sort** key approximating `localizedCaseInsensitiveCompare`: NFD, drop
/// combining marks, lowercase.
///
/// Byte order over lowercased UTF-8 gets the accented cases backwards —
/// `Émile` sorts after `Eve`, `Özlem` after `Peter`, `åsa` after `Bob` —
/// because the precomposed code points live above ASCII. ICU collates them as
/// if unaccented, and stripping the marks reproduces that for the Latin
/// scripts these names come from.
///
/// **This is not full ICU collation** and is not trying to be. It does not
/// implement locale tailorings (Swedish sorts `å` after `z`, not with `a`), it
/// does not expand `ß` to `ss`, and it orders non-Latin scripts by code point.
/// It is used in exactly one place — the trip-title people tiebreak, at most
/// three names — and the alternative there was a raw byte compare that was
/// wrong on every accented name.
pub fn collation_key(s: &str) -> String {
    s.to_lowercase()
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .nfc()
        .collect()
}

/// The Unicode combining-diacritical-mark blocks NFD decomposition produces for
/// Latin, Greek and Cyrillic.
fn is_combining_mark(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F   // Combining Diacritical Marks
        | 0x1AB0..=0x1AFF // …Extended
        | 0x1DC0..=0x1DFF // …Supplement
        | 0x20D0..=0x20FF // …for Symbols
        | 0xFE20..=0xFE2F // Combining Half Marks
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nfd_and_nfc_spellings_share_every_key() {
        assert_eq!(nfc("caf\u{00E9}"), nfc("cafe\u{0301}"));
        assert_eq!(match_key("caf\u{00E9}"), match_key("cafe\u{0301}"));
    }

    /// `nfc` must **not** fold case — a Swift `Set<String>` does not either,
    /// and a `People/*` path's case is part of its identity.
    #[test]
    fn nfc_preserves_case_while_match_key_folds_it() {
        assert_ne!(nfc("People/Alice"), nfc("People/alice"));
        assert_eq!(match_key("People/Alice"), match_key("People/alice"));
    }

    #[test]
    fn canonical_equivalence_is_not_accent_folding() {
        assert!(!match_key("cafe\u{0301}").contains(&match_key("cafe")));
    }

    /// The three pairs a raw byte compare gets backwards, probed against ICU.
    #[test]
    fn the_collation_key_orders_accented_names_the_way_icu_does() {
        for (a, b) in [("Émile", "Eve"), ("Özlem", "Peter"), ("åsa", "Bob")] {
            assert!(
                a.to_lowercase() > b.to_lowercase(),
                "{a} vs {b}: precondition — raw bytes get this backwards"
            );
            assert!(
                collation_key(a) < collation_key(b),
                "{a} must sort before {b}, as localizedCaseInsensitiveCompare has it"
            );
        }
    }

    /// A decomposed spelling collates identically to its precomposed twin.
    #[test]
    fn the_collation_key_is_normalisation_independent() {
        assert_eq!(
            collation_key("\u{00C9}mile"),
            collation_key("E\u{0301}mile")
        );
    }

    #[test]
    fn unaccented_names_are_unaffected() {
        assert_eq!(collation_key("Anna"), "anna");
        assert_eq!(collation_key("Bob"), "bob");
    }
}
