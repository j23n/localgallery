//! Tag-path helpers and the casing rules from schema §3.

use unicode_normalization::UnicodeNormalization;

use crate::error::{MetaError, MetaResult};

/// Unicode NFC — the one normalization form this crate compares in.
///
/// # Policy
///
/// `Café` has two legal spellings: NFC (`é` as one code point) and NFD (`e` +
/// combining acute). They render identically, and no user will ever accept
/// that their library contains both `Places/Café` and `Places/Café`. macOS
/// hands out NFD from its filesystem APIs, so a tagger that lifted a keyword
/// from a filename really does produce the other form. So:
///
/// 1. **Requested tags are NFC-normalized on entry** ([`normalize_tag`]). The
///    crate's own output is therefore always NFC.
/// 2. **Comparisons against entries already in a sidecar are made on NFC
///    forms** — "is this tag already here", "is this the leaf I claimed", "is
///    this the entry I must retract". An NFD entry in the file matches the NFC
///    tag we hold, so nothing duplicates and no claim is orphaned.
/// 3. **Entries the crate is not editing are never rewritten.** Normalization
///    is a comparison rule, not a rewrite rule: a human's NFD keyword keeps its
///    bytes. Preservation outranks tidiness (crate doc).
///
/// The one place bytes do change is the crate's own `Core*` sentinel, which is
/// rewritten wholesale from the NFC values it now holds — that is our field to
/// normalize.
pub fn nfc(value: &str) -> String {
    value.nfc().collect()
}

/// NFC plus lowercase: the key `dc:subject` leaves are compared on.
///
/// Keyword matching in this ecosystem is case-insensitive by convention (the
/// planner has always compared leaves that way), and the retraction path has to
/// use exactly the same rule as the claim path or a leaf whose case drifted
/// after we claimed it would be dropped from `CoreSubjects` while surviving in
/// the file — an orphaned claim that nothing ever cleans up.
pub fn nfc_lower(value: &str) -> String {
    nfc(value).to_lowercase()
}

/// `Places/Italy/Rome` → `Rome`. A flat tag comes back unchanged.
pub fn leaf_of(tag: &str) -> &str {
    match tag.rsplit_once('/') {
        Some((_, leaf)) => leaf,
        None => tag,
    }
}

/// `Objects/Animal/Dog` → `Objects|Animal|Dog`, the `lr:hierarchicalSubject`
/// form (schema §1.1).
pub fn to_lr_path(tag: &str) -> String {
    tag.replace('/', "|")
}

/// Top-level root of a hierarchical tag: `Objects/Animal/Dog` → `Objects`.
pub fn root_of(tag: &str) -> &str {
    match tag.split_once('/') {
        Some((root, _)) => root,
        None => tag,
    }
}

/// The root the core is forbidden to touch — digiKam owns face names
/// (schema §2.1) and Phase 2 will take that over deliberately, not by accident.
pub const PEOPLE_ROOT: &str = "People";

/// Normalize a requested tag: NFC-compose it, trim each segment, collapse
/// internal runs of whitespace, titlecase every segment (§3), drop empty
/// segments.
///
/// Rejects a tag that ends up empty, or that targets `People/` — Phase 1 has
/// no business there.
pub fn normalize_tag(tag: &str) -> MetaResult<String> {
    if tag.chars().any(|c| c.is_control()) {
        return Err(MetaError::InvalidTag {
            tag: tag.to_string(),
            reason: "contains control characters".into(),
        });
    }
    // NFC first, so titlecasing sees a composed `é` rather than a bare `e`
    // followed by a combining mark — and so the whole crate has exactly one
    // spelling of every tag it produces (see [`nfc`]).
    let composed = nfc(tag);
    let segments: Vec<String> = composed
        .split('/')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(titlecase_segment)
        .collect();
    if segments.is_empty() {
        return Err(MetaError::InvalidTag {
            tag: tag.to_string(),
            reason: "empty after normalization".into(),
        });
    }
    let normalized = segments.join("/");
    if root_of(&normalized) == PEOPLE_ROOT {
        return Err(MetaError::InvalidTag {
            tag: tag.to_string(),
            reason: "People/* is owned by face recognition, not the tagger".into(),
        });
    }
    Ok(normalized)
}

/// English small words the `titlecase` PyPI library keeps lowercase when they
/// are neither the first nor the last word (schema §3).
///
/// photo-tools runs that library in default English mode, so non-English small
/// words (`del`, `de`, `la`) are *uppercased* — matched here by omission.
const SMALL_WORDS: &[&str] = &[
    "a", "an", "and", "as", "at", "but", "by", "en", "for", "if", "in", "of", "on", "or", "the",
    "to", "v", "v.", "via", "vs", "vs.",
];

/// Titlecase one path segment.
///
/// A deliberately conservative subset of the `titlecase` library: a word that
/// already carries an internal capital (`McDonald`, `iPhone`, `Roma I`) is left
/// alone, so pre-cased taxonomy leaves from the model pack pass through
/// untouched and only sloppy input gets fixed. Full parity with the Python
/// library is neither achievable nor needed — the tagger's label set ships
/// already cased.
pub fn titlecase_segment(segment: &str) -> String {
    let words: Vec<&str> = segment.split_whitespace().collect();
    let last = words.len().saturating_sub(1);
    words
        .iter()
        .enumerate()
        .map(|(i, word)| titlecase_word(word, i == 0 || i == last))
        .collect::<Vec<_>>()
        .join(" ")
}

fn titlecase_word(word: &str, forced: bool) -> String {
    // Anything with a capital past the first character is intentional casing
    // somebody else chose. Leave it.
    if word.chars().skip(1).any(char::is_uppercase) {
        return word.to_string();
    }
    if !forced && SMALL_WORDS.contains(&word.to_lowercase().as_str()) {
        return word.to_lowercase();
    }
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Normalize, deduplicate and sort a requested tag list.
///
/// Sorting is what makes output deterministic: the ML tagger hands tags over in
/// score order, and cross-architecture float drift reorders near-ties without
/// changing the set. Sorting the set means the same *set* always serializes to
/// the same bytes (determinism doctrine, overview §5).
pub fn normalize_tag_list(tags: &[String]) -> MetaResult<Vec<String>> {
    let mut out: Vec<String> = tags
        .iter()
        .map(|t| normalize_tag(t))
        .collect::<MetaResult<Vec<_>>>()?;
    out.sort();
    out.dedup();
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaf_and_root_split_at_the_right_end() {
        assert_eq!(leaf_of("Places/Italy/Rome"), "Rome");
        assert_eq!(leaf_of("Rome"), "Rome");
        assert_eq!(root_of("Places/Italy/Rome"), "Places");
        assert_eq!(root_of("Rome"), "Rome");
    }

    #[test]
    fn lr_paths_use_the_pipe_separator() {
        assert_eq!(to_lr_path("Objects/Animal/Dog"), "Objects|Animal|Dog");
    }

    #[test]
    fn normalization_titlecases_and_collapses() {
        assert_eq!(
            normalize_tag("objects/animal/dog").unwrap(),
            "Objects/Animal/Dog"
        );
        assert_eq!(
            normalize_tag("  Objects / Animal / Dog ").unwrap(),
            "Objects/Animal/Dog"
        );
        assert_eq!(normalize_tag("Objects//Dog").unwrap(), "Objects/Dog");
    }

    #[test]
    fn normalization_matches_the_schema_doc_examples() {
        assert_eq!(titlecase_segment("rome"), "Rome");
        assert_eq!(titlecase_segment("municipio roma i"), "Municipio Roma I");
        assert_eq!(titlecase_segment("state of the art"), "State of the Art");
        // Default English mode uppercases non-English small words (§3).
        assert_eq!(
            titlecase_segment("città del vaticano"),
            "Città Del Vaticano"
        );
    }

    #[test]
    fn pre_cased_taxonomy_leaves_survive_untouched() {
        for s in ["Dog", "Hot Air Balloon", "McDonald's", "T-Shirt", "Roma I"] {
            assert_eq!(titlecase_segment(s), s);
        }
    }

    #[test]
    fn people_tags_are_rejected() {
        let err = normalize_tag("People/Alice").unwrap_err();
        assert!(matches!(err, MetaError::InvalidTag { .. }), "{err:?}");
    }

    #[test]
    fn empty_and_control_tags_are_rejected() {
        assert!(normalize_tag("").is_err());
        assert!(normalize_tag("///").is_err());
        assert!(normalize_tag("Objects/\u{0}Dog").is_err());
    }

    #[test]
    fn tag_lists_come_back_sorted_and_deduped() {
        let input = vec![
            "Scenes/Urban/Street".to_string(),
            "objects/animal/dog".to_string(),
            "Objects/Animal/Dog".to_string(),
        ];
        assert_eq!(
            normalize_tag_list(&input).unwrap(),
            vec!["Objects/Animal/Dog", "Scenes/Urban/Street"]
        );
    }
}
