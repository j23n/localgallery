//! The one thing the index port is most likely to get wrong.
//!
//! `SearchIndex.search` matches with `corpus.contains(query)` on two Swift
//! `String`s. Swift `String` compares by **canonical equivalence**, so a
//! precomposed query (`caf\u{00E9}`) finds a filename stored decomposed on disk
//! (`cafe\u{0301}`) — which is exactly what Foundation's
//! `URL(fileURLWithPath:)` produces on Apple platforms. A byte-comparing Rust
//! port silently stops finding every accented name in the library, and nothing
//! fails loudly when it happens.
//!
//! The port's answer: normalise both sides to **NFC** and then compare bytes.
//! Byte order over NFC is not literally Swift's collation, but it agrees with
//! it on the three cases `search_index.json` pins, and it is the only
//! dependency-free option that keeps `café` findable:
//!
//! | case | expectation | NFC + bytes |
//! |---|---|---|
//! | NFC query vs NFD filename | matches | ✅ both fold to the same NFC bytes |
//! | `"cafe"` vs `"café"` | does **not** match | ✅ equivalence is not folding |
//! | `"istanbul"` vs `"İstanbul"` | matches | ✅ — via the photo's `Istanbul` **tag**, not the filename; see below |
//!
//! That last row is worth stating plainly because the fixture's note reads as
//! if it were a case-folding puzzle: `"İ".lowercased()` is `i` + U+0307, which
//! is *not* canonically equivalent to a plain `i`, and the corpus term built
//! from the filename therefore does **not** match `"istanbul"`. The query hits
//! because the same photo carries `Places/Türkiye/Istanbul`, whose leaf term
//! lowercases to a plain `istanbul`. No Turkish-specific case folding is
//! involved, and adding any would be a divergence.

use unicode_normalization::UnicodeNormalization;

/// Swift's `lowercased()`: the full, **locale-independent** Unicode lowercase
/// mapping. Rust's `str::to_lowercase` is the same mapping, including the
/// special case that sends `İ` (U+0130) to `i` + U+0307.
pub fn lowercased(s: &str) -> String {
    s.to_lowercase()
}

/// The form substring matching runs against: lowercased, then NFC.
///
/// Applied to both the corpus and the query, so `contains` is a plain byte
/// search on strings that are already in one canonical spelling.
pub fn match_key(s: &str) -> String {
    s.to_lowercase().nfc().collect()
}

/// NFC without the case fold — for keys that must keep their spelling
/// (`url.path` sort keys, where case is meaningful).
pub fn nfc(s: &str) -> String {
    s.nfc().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nfd_and_nfc_spellings_share_a_match_key() {
        assert_eq!(match_key("caf\u{00E9}"), match_key("cafe\u{0301}"));
    }

    #[test]
    fn canonical_equivalence_is_not_accent_folding() {
        assert!(!match_key("cafe\u{0301}").contains(&match_key("cafe")));
    }

    #[test]
    fn dotted_capital_i_lowercases_to_i_plus_combining_dot() {
        // Pinned because the whole `istanbul` fixture case rests on it: Rust
        // must reproduce Swift's SpecialCasing entry for U+0130, and it does.
        assert_eq!(lowercased("\u{0130}stanbul"), "i\u{0307}stanbul");
        // …and that is NOT reachable from a plain "istanbul".
        assert!(!match_key("\u{0130}stanbul").contains("istanbul"));
    }

    #[test]
    fn lowercasing_is_locale_independent() {
        // No Turkish dotless-ı anywhere: `I` lowercases to `i`, always.
        assert_eq!(lowercased("ISTANBUL"), "istanbul");
    }
}
