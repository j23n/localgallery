//! `search_index.json` + `tag_index.json`, run against `gallery-index`.
//!
//! One copy of the fixtures in the repo, read here straight off disk and
//! bundled into `LocalGalleryTests` as a folder resource — the same arrangement
//! as `scan-conformance/`. Duplicating the expectations per language puts
//! nothing on the line.
//!
//! Every case in both files is asserted: the sorted order, the corpus term by
//! term, all 16 queries, all 15 buckets with their canonical spellings, and
//! both suggestion lists.

use std::collections::BTreeMap;
use std::path::PathBuf;

use gallery_index::{corpus_terms, text, LibraryIndex, TagSuggestion};
use gallery_model::{AppleDate, HierarchicalTag, PhotoFile, StableId};
use serde::Deserialize;

// ---------------------------------------------------------------------------
// Fixture plumbing
// ---------------------------------------------------------------------------

fn parse<T: for<'de> Deserialize<'de>>(name: &str) -> T {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "memories-conformance",
        name,
    ]
    .iter()
    .collect();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"))
}

#[derive(Deserialize)]
struct Photo {
    path: String,
    id: String,
    filename: String,
    #[serde(rename = "dateTaken")]
    date_taken: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(rename = "countryCode")]
    country_code: Option<String>,
    #[serde(rename = "gpsLatitude")]
    gps_latitude: Option<f64>,
    #[serde(rename = "gpsLongitude")]
    gps_longitude: Option<f64>,
    #[serde(rename = "isVideo")]
    is_video: bool,
}

/// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, the fixtures' only date spelling.
///
/// Parsed by hand rather than through serde's number path: the fixture README
/// records that serde_json rounds some 17-digit decimals one ULP low, and the
/// habit of parsing floats with `str::parse` is cheaper to keep than to
/// remember where it matters.
fn parse_utc(s: &str) -> AppleDate {
    let bytes = s.as_bytes();
    assert_eq!(bytes.len(), 24, "unexpected date spelling {s}");
    let n = |a: usize, b: usize| -> i64 { s[a..b].parse().unwrap() };
    let civil = gallery_model::CivilDateTime {
        year: n(0, 4) as i32,
        month: n(5, 7) as u32,
        day: n(8, 10) as u32,
        hour: n(11, 13) as u32,
        minute: n(14, 16) as u32,
        second: n(17, 19) as u32,
    };
    let millis: f64 = s[20..23].parse().unwrap();
    AppleDate::from_unix_secs_f64(civil.as_naive_unix_secs() as f64 + millis / 1000.0)
}

impl Photo {
    fn to_photo_file(&self) -> PhotoFile {
        let mut p = PhotoFile::new(&self.path, self.filename.clone(), 0);
        assert_eq!(
            p.id.to_string(),
            self.id,
            "{}: the fixture's id is not what StableId derives from its path",
            self.path
        );
        p.date_taken = self.date_taken.as_deref().map(parse_utc);
        p.hierarchical_tags = self.tags.iter().map(|t| HierarchicalTag::new(t)).collect();
        p.country_code = self.country_code.clone();
        p.gps_latitude = self.gps_latitude;
        p.gps_longitude = self.gps_longitude;
        p.is_video = self.is_video;
        p
    }
}

fn ids(photos: &[&PhotoFile]) -> Vec<String> {
    photos.iter().map(|p| p.id.to_string()).collect()
}

// ---------------------------------------------------------------------------
// search_index.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct SearchDump {
    schema: u32,
    photos: Vec<Photo>,
    #[serde(rename = "sortedPhotoIDs")]
    sorted_photo_ids: Vec<String>,
    corpus: Vec<CorpusEntry>,
    queries: Vec<Query>,
}

#[derive(Deserialize)]
struct CorpusEntry {
    #[serde(rename = "photoID")]
    photo_id: String,
    terms: Vec<String>,
}

#[derive(Deserialize)]
struct Query {
    query: String,
    #[serde(rename = "requiredTagPaths")]
    required_tag_paths: Vec<String>,
    #[serde(rename = "expectedPhotoIDs")]
    expected_photo_ids: Vec<String>,
}

fn search_fixture() -> (SearchDump, LibraryIndex) {
    let dump: SearchDump = parse("search_index.json");
    assert_eq!(dump.schema, 1);
    let photos: Vec<PhotoFile> = dump.photos.iter().map(Photo::to_photo_file).collect();
    let index = LibraryIndex::build(photos);
    (dump, index)
}

#[test]
fn sorted_order_matches_the_fixture() {
    let (dump, index) = search_fixture();
    let observed: Vec<String> = index
        .sorted_photo_ids()
        .iter()
        .map(StableId::to_string)
        .collect();
    assert_eq!(observed, dump.sorted_photo_ids);
}

#[test]
fn the_corpus_matches_term_for_term() {
    let (dump, index) = search_fixture();
    let by_id: BTreeMap<&str, &CorpusEntry> = dump
        .corpus
        .iter()
        .map(|c| (c.photo_id.as_str(), c))
        .collect();
    assert_eq!(by_id.len(), index.photos().len());
    for photo in index.photos() {
        let expected = by_id[photo.id.to_string().as_str()];
        assert_eq!(
            corpus_terms(photo),
            expected.terms,
            "{}: corpus terms",
            photo.path()
        );
        assert_eq!(expected.terms.len(), 1 + photo.hierarchical_tags.len() * 2);
    }
}

#[test]
fn every_query_returns_the_fixture_result_list() {
    let (dump, index) = search_fixture();
    let (all_tags, _) = index.tag_suggestions();
    let by_path: BTreeMap<String, &TagSuggestion> = all_tags
        .iter()
        .map(|t| (text::lowercased(&t.full_path), t))
        .collect();

    assert_eq!(dump.queries.len(), 16, "the query set shrank");
    for q in &dump.queries {
        let required: Vec<TagSuggestion> = q
            .required_tag_paths
            .iter()
            .map(|p| {
                (*by_path
                    .get(&text::lowercased(p))
                    .unwrap_or_else(|| panic!("required tag {p} is not in the aggregated list")))
                .clone()
            })
            .collect();
        let observed = ids(&index.search(&q.query, &required, &all_tags));
        assert_eq!(
            observed, q.expected_photo_ids,
            "query {:?} tags {:?}",
            q.query, q.required_tag_paths
        );
    }
}

/// The three cases the fixture calls the single most likely regression in the
/// port, asserted by name so a failure says what broke rather than which array
/// index disagreed.
#[test]
fn canonical_equivalence_survives_the_port() {
    let (dump, index) = search_fixture();
    let (all_tags, _) = index.tag_suggestions();
    let hits = |q: &str| ids(&index.search(q, &[], &all_tags));

    // The query is precomposed; the filename on disk is decomposed.
    let cafe = &dump.photos.iter().find(|p| p.path.contains("caf")).unwrap();
    assert!(
        cafe.path.contains('\u{0301}'),
        "the fixture's café stopped being decomposed — this case no longer \
         tests what it was written for"
    );
    assert_eq!(hits("caf\u{00E9}"), vec![cafe.id.clone()]);
    // Equivalence is not folding.
    assert!(hits("cafe").is_empty());
    // And the dotted capital: matched through the photo's `Istanbul` TAG, not
    // through its filename, whose lowercase is `i` + U+0307.
    let istanbul = dump
        .photos
        .iter()
        .find(|p| p.filename.ends_with("stanbul"))
        .unwrap();
    // Decomposed too — `İ` reaches the fixture as `I` + U+0307, so its
    // lowercase is `i` + U+0307 and a plain `i` cannot match it.
    assert_eq!(istanbul.filename, "I\u{0307}stanbul");
    assert_eq!(hits("istanbul"), vec![istanbul.id.clone()]);
}

/// Grid-order stability: the plan's acceptance criterion, at the index level.
#[test]
fn rebuilding_the_index_is_byte_identical() {
    let (_, a) = search_fixture();
    let (_, b) = search_fixture();
    assert_eq!(a.sorted_photo_ids(), b.sorted_photo_ids());
    assert_eq!(a.tag_suggestions(), b.tag_suggestions());
}

// ---------------------------------------------------------------------------
// tag_index.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct TagDump {
    schema: u32,
    photos: Vec<Photo>,
    buckets: Vec<Bucket>,
    #[serde(rename = "tagSuggestions")]
    tag_suggestions: Vec<Suggestion>,
    #[serde(rename = "peopleSuggestions")]
    people_suggestions: Vec<Suggestion>,
}

#[derive(Deserialize)]
struct Bucket {
    key: String,
    #[serde(rename = "canonicalPath")]
    canonical_path: Option<String>,
    #[serde(rename = "photoIDs")]
    photo_ids: Vec<String>,
}

#[derive(Deserialize, Debug, PartialEq)]
struct Suggestion {
    id: String,
    #[serde(rename = "displayName")]
    display_name: String,
    #[serde(rename = "fullPath")]
    full_path: String,
    namespace: Option<String>,
    count: usize,
    #[serde(rename = "latestPhotoDate")]
    latest_photo_date: Option<String>,
}

impl Suggestion {
    fn of(s: &TagSuggestion) -> Self {
        Suggestion {
            id: s.id.clone(),
            display_name: s.display_name.clone(),
            full_path: s.full_path.clone(),
            namespace: s.namespace.clone(),
            count: s.count,
            latest_photo_date: s.latest_photo_date.map(|d| AppleDate(d).to_utc_string()),
        }
    }
}

fn tag_fixture() -> (TagDump, LibraryIndex) {
    let dump: TagDump = parse("tag_index.json");
    assert_eq!(dump.schema, 1);
    let photos: Vec<PhotoFile> = dump.photos.iter().map(Photo::to_photo_file).collect();
    let index = LibraryIndex::build(photos);
    (dump, index)
}

#[test]
fn every_bucket_matches_the_fixture() {
    let (dump, index) = tag_fixture();
    let tags = index.tags();

    assert_eq!(
        tags.keys_sorted(),
        dump.buckets
            .iter()
            .map(|b| b.key.as_str())
            .collect::<Vec<_>>(),
        "the bucket key set diverged"
    );
    for b in &dump.buckets {
        let observed: Vec<String> = tags
            .indices_for_key(&b.key)
            .iter()
            .map(|i| index.photos()[*i as usize].id.to_string())
            .collect();
        assert_eq!(observed, b.photo_ids, "{}: bucket contents", b.key);
        assert_eq!(
            tags.canonical_path(&b.key),
            b.canonical_path.as_deref(),
            "{}: canonical spelling",
            b.key
        );
    }
}

#[test]
fn both_suggestion_lists_match_the_fixture() {
    let (dump, index) = tag_fixture();
    let (tags, people) = index.tag_suggestions();
    assert_eq!(
        tags.iter().map(Suggestion::of).collect::<Vec<_>>(),
        dump.tag_suggestions,
        "tag suggestions, in the canonical (count desc, id asc) order"
    );
    assert_eq!(
        people.iter().map(Suggestion::of).collect::<Vec<_>>(),
        dump.people_suggestions
    );
}

/// The prefix-expansion rules, called out because each is a place a reasonable
/// implementation would do something more useful and therefore wrong.
#[test]
fn prefix_expansion_follows_the_pinned_rules() {
    let (_, index) = tag_fixture();
    let tags = index.tags();
    let keys = tags.keys_sorted();

    assert!(keys.contains(&"places/italy/lazio"), "a virtual prefix tag");
    assert!(
        !keys.contains(&"places"),
        "the bare namespace is never a bucket"
    );
    assert!(
        !keys.contains(&"people"),
        "People is not a prefix-matching namespace"
    );
    // The photo carrying BOTH Places/Italy and Places/Italy/Lazio/Rome is
    // credited to places/italy exactly once.
    assert_eq!(tags.indices_for_key("places/italy").len(), 4);
    assert_eq!(tags.indices_for_key("vacation").len(), 1);
}
