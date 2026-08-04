//! A smoke assertion on the one query shape that used to do Unicode work per
//! photo per keystroke.
//!
//! `search`'s tag branch calls `photo_carries` for every photo in the result
//! set, once per required tag and once more for an exact-tag-path query. That
//! function used to `match_key` each of the photo's tag paths on every call —
//! a `to_lowercase` plus an NFC pass, both allocating — so a 20k library with
//! three tags a photo re-normalised ~60,000 strings *per query*, and
//! `PhotoGridScreen` issues one per keystroke. The keys are now folded once at
//! build time.
//!
//! Not a benchmark: the bound is deliberately an order of magnitude above the
//! measured number, because this runs in debug on whatever machine CI has. It
//! fails if the per-query fold comes back, and passes comfortably otherwise.
//! The build-time cost it moved the work into is asserted too, so the fix
//! cannot be "make queries fast by making rebuilds slow".

use std::time::Instant;

use gallery_index::{LibraryIndex, TagSuggestion};
use gallery_model::{AppleDate, HierarchicalTag, PhotoFile};

const PHOTOS: usize = 20_000;
const QUERIES: usize = 40;
/// Debug-build headroom over the measured ~0.6 ms/query.
const QUERY_BUDGET_MS: f64 = 25.0;
const BUILD_BUDGET_MS: f64 = 6_000.0;

/// 20k photos, three tags each, a third of them in the `Places/…` hierarchy the
/// prefix expansion walks. Accented paths on purpose: an ASCII-only library
/// would let a byte compare look just as fast as the fold it replaced.
fn library() -> Vec<PhotoFile> {
    (0..PHOTOS)
        .map(|i| {
            let mut p = PhotoFile::new(&format!("/lib/photo-{i}.jpg"), format!("photo-{i}"), 1_000);
            p.date_taken = Some(AppleDate(i as f64 * 60.0));
            p.hierarchical_tags = vec![
                HierarchicalTag::new(&format!(
                    "Places/Espa\u{00F1}a/Andaluc\u{00ED}a/City{}",
                    i % 50
                )),
                HierarchicalTag::new(&format!("People/Jos\u{00E9} Person{}", i % 40)),
                HierarchicalTag::new(&format!("Scenes/Scene{}", i % 12)),
            ];
            p
        })
        .collect()
}

fn suggestion(full_path: &str) -> TagSuggestion {
    let tag = HierarchicalTag::new(full_path);
    TagSuggestion {
        id: full_path.to_lowercase(),
        display_name: tag.display_name,
        full_path: tag.full_path,
        namespace: tag.namespace,
        count: 0,
        latest_photo_date: None,
    }
}

#[test]
fn the_tag_branch_does_no_unicode_work_per_query() {
    let photos = library();
    let started = Instant::now();
    let index = LibraryIndex::build(photos);
    let build_ms = started.elapsed().as_secs_f64() * 1000.0;

    let (all_tags, _people) = index.tag_suggestions();
    let required = vec![suggestion("Places/Espa\u{00F1}a")];

    // Both branches that call `photo_carries`: an exact tag-path *query* (which
    // has to find the path in `all_tags` first) and a required-tag filter.
    let started = Instant::now();
    for _ in 0..QUERIES {
        let hits = index.search("places/espa\u{00F1}a/andaluc\u{00ED}a", &[], &all_tags);
        assert_eq!(
            hits.len(),
            PHOTOS,
            "the prefix expansion must reach the leaf"
        );
        let filtered = index.search("", &required, &all_tags);
        assert_eq!(filtered.len(), PHOTOS);
    }
    let per_query_ms = started.elapsed().as_secs_f64() * 1000.0 / (QUERIES * 2) as f64;

    println!("[index-search] {PHOTOS} photos: build {build_ms:.0}ms, {per_query_ms:.2}ms/query");
    assert!(
        per_query_ms < QUERY_BUDGET_MS,
        "{per_query_ms:.2}ms/query — the per-query Unicode fold is back"
    );
    assert!(
        build_ms < BUILD_BUDGET_MS,
        "{build_ms:.0}ms to build — the pre-folded tag keys cost more than they save"
    );
}

/// A decomposed query still matches a precomposed tag path after the fold moved
/// to build time — the property the whole `match_key` layer exists for, and the
/// one a naive "just store the raw paths" optimisation would break.
#[test]
fn pre_folding_keeps_the_canonical_equivalence_match() {
    let mut photo = PhotoFile::new("/lib/a.jpg", "a".to_string(), 1);
    photo.date_taken = Some(AppleDate(0.0));
    // Precomposed on the photo…
    photo.hierarchical_tags = vec![HierarchicalTag::new("Places/Espa\u{00F1}a/Sevilla")];
    let index = LibraryIndex::build(vec![photo]);
    let (all_tags, _) = index.tag_suggestions();

    // …decomposed in the query, and in the required tag.
    assert_eq!(
        index
            .search("places/espan\u{0303}a/sevilla", &[], &all_tags)
            .len(),
        1
    );
    assert_eq!(
        index
            .search("", &[suggestion("Places/Espan\u{0303}a")], &all_tags)
            .len(),
        1,
        "the places prefix expansion folds too"
    );
}
