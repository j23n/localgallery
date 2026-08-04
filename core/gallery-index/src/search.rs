//! `SearchIndex.swift`, ported: the date-sorted photo list, the per-photo
//! search corpus, and the two-branch query.

use gallery_model::PhotoFile;

use crate::text;

/// `Date.distantPast`, in Apple-reference-date seconds — what
/// `SearchIndex.sortPhotos` substitutes for a missing `dateTaken`.
///
/// A sentinel rather than `f64::NEG_INFINITY` so a photo that somehow *is*
/// dated to the distant past ties with the undated tail, exactly as in Swift,
/// instead of sorting above it.
pub const DISTANT_PAST: f64 = -63_114_076_800.0;

/// The per-photo corpus terms, before they are joined: the filename, then
/// `displayName` and `fullPath` for each tag, each lowercased.
///
/// Exposed because the fixture records this list verbatim — the field order
/// and the count (`1 + 2 × tags`) are both part of the contract.
pub fn corpus_terms(photo: &PhotoFile) -> Vec<String> {
    let mut terms = Vec::with_capacity(1 + photo.hierarchical_tags.len() * 2);
    terms.push(text::lowercased(&photo.filename));
    for tag in &photo.hierarchical_tags {
        terms.push(text::lowercased(&tag.display_name));
        terms.push(text::lowercased(&tag.full_path));
    }
    terms
}

/// The corpus entry a query is substring-matched against: the terms joined with
/// `\n`, in the canonical form `text::match_key` defines.
///
/// The newline join is load-bearing: it is why no substring can ever span two
/// terms, and why `"italy beach"` matches nothing while `"beach italy"` matches
/// a filename that literally contains it.
pub fn corpus_entry(photo: &PhotoFile) -> String {
    text::nfc(&corpus_terms(photo).join("\n"))
}

/// The sort key: `(dateTaken ?? .distantPast, url.path)`.
///
/// The path half is the tiebreak that stops a rescan from reshuffling the grid
/// — `sorted` is not documented stable and the input order comes off a
/// filesystem enumeration. It is NFC-normalised because Swift's `String <`
/// compares canonically-equivalent spellings as equal, so a decomposed and a
/// precomposed filename must not sort to two different places.
pub(crate) struct SortKey {
    pub date: f64,
    pub path: String,
}

impl SortKey {
    pub fn new(photo: &PhotoFile) -> Self {
        SortKey {
            date: photo.date_taken.map_or(DISTANT_PAST, |d| d.0),
            path: text::nfc(photo.url.path()),
        }
    }

    /// Date descending, then path ascending.
    pub fn cmp(&self, other: &SortKey) -> std::cmp::Ordering {
        other
            .date
            .partial_cmp(&self.date)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| self.path.cmp(&other.path))
    }
}
