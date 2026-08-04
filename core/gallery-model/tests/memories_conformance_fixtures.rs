//! Phase-4 conformance fixtures, read from Rust.
//!
//! `core/fixtures/memories-conformance/` holds the spec the `MemoryEngine` /
//! `SearchIndex` / `TagIndex` port has to satisfy: one copy in the repo,
//! bundled into `LocalGalleryTests` as a folder resource and read here straight
//! off disk — the same arrangement as `scan-conformance/` and
//! `stable_uuid_vectors.json`.
//!
//! Like `scan_conformance_fixtures.rs`, what this file does *today* is narrow
//! on purpose: it proves the fixtures parse from Rust, pins the invariants a
//! porting mistake would break first, and asserts the landmines are still
//! recorded. When `gallery-memories` / `gallery-index` land, their tests
//! replace these assertions with real comparisons against real output.
//!
//! The one exception is `SeededRNG`: its vectors are checked against the real
//! implementation, [`gallery_model::SeededRng`], rather than against a
//! description of it. Everything else in Phase 4 depends on that generator, so
//! it landed first and lives in the library, not in this file.

use gallery_model::SeededRng;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

fn fixture(name: &str) -> String {
    // core/gallery-model → core → fixtures/memories-conformance
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "memories-conformance",
        name,
    ]
    .iter()
    .collect();
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn parse<T: for<'de> Deserialize<'de>>(name: &str) -> T {
    serde_json::from_str(&fixture(name))
        .unwrap_or_else(|e| panic!("{name} does not match the expected shape: {e}"))
}

// ---------------------------------------------------------------------------
// Shared records
// ---------------------------------------------------------------------------

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

#[derive(Deserialize, PartialEq, Debug)]
struct Memory {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    title: String,
    subtitle: Option<String>,
    #[serde(rename = "photoIDs")]
    photo_ids: Vec<String>,
    #[serde(rename = "photoCount")]
    photo_count: usize,
    #[serde(rename = "coverPhotoID")]
    cover_photo_id: String,
    score: f64,
    #[serde(rename = "yearsAgo")]
    years_ago: Option<i32>,
    #[serde(rename = "personName")]
    person_name: Option<String>,
    #[serde(rename = "dateRangeStart")]
    date_range_start: Option<String>,
    #[serde(rename = "dateRangeEnd")]
    date_range_end: Option<String>,
}

/// Cluster identity, ported from `MemoryEngine+Selection.swift`. A trip parent
/// and its sub-trips collapse to one key; everything else is its own.
fn cluster_key(memory_id: &str) -> String {
    if let Some(rest) = memory_id.strip_prefix("subtrip-") {
        let parts: Vec<&str> = rest.split('-').collect();
        if parts.len() >= 4 {
            return format!("trip-{}", parts[..3].join("-"));
        }
    }
    memory_id.to_string()
}

// ---------------------------------------------------------------------------
// seeded_rng.json — checked against a real Rust implementation
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct RngDump {
    schema: u32,
    algorithm: RngAlgorithm,
    notes: Vec<String>,
    seeds: Vec<RngSeed>,
    #[serde(rename = "daySeeds")]
    day_seeds: Vec<DaySeed>,
    #[serde(rename = "forceRegenerateSeeds")]
    force_regenerate_seeds: Vec<DaySeed>,
}

#[derive(Deserialize)]
struct RngAlgorithm {
    #[serde(rename = "jitterFormula")]
    jitter_formula: String,
    gamma: String,
    #[serde(rename = "offsetBasis")]
    offset_basis: String,
}

#[derive(Deserialize)]
struct RngSeed {
    seed: String,
    #[serde(rename = "seedUTF8")]
    seed_utf8: Vec<u8>,
    #[serde(rename = "initialState")]
    initial_state: String,
    next: Vec<String>,
    #[serde(rename = "jitter0to12")]
    jitter_0_to_12: Vec<f64>,
    #[serde(rename = "jitter0to12Bits")]
    jitter_0_to_12_bits: Vec<String>,
    #[serde(rename = "unit0to1")]
    unit_0_to_1: Vec<f64>,
    #[serde(rename = "unit0to1Bits")]
    unit_0_to_1_bits: Vec<String>,
}

#[derive(Deserialize)]
struct DaySeed {
    #[serde(rename = "instantUTC")]
    _instant_utc: String,
    #[serde(rename = "timeZone")]
    time_zone: String,
    seed: String,
}

#[test]
fn seeded_rng_vectors_match_a_rust_implementation() {
    let dump: RngDump = parse("seeded_rng.json");
    assert_eq!(dump.schema, 1);
    assert!(!dump.notes.is_empty(), "the notes are part of the fixture");
    assert!(dump
        .algorithm
        .jitter_formula
        .contains("0x1F_FFFF_FFFF_FFFF"));
    assert_eq!(dump.algorithm.gamma, "0x9E3779B97F4A7C15");
    assert_eq!(dump.algorithm.offset_basis, "0xcbf29ce484222325");
    assert!(dump.seeds.len() >= 6);

    for v in &dump.seeds {
        assert_eq!(
            v.seed.as_bytes(),
            v.seed_utf8.as_slice(),
            "seed '{}': the recorded UTF-8 bytes are not the seed's bytes",
            v.seed
        );

        let rng = SeededRng::new(&v.seed);
        assert_eq!(
            rng.state().to_string(),
            v.initial_state,
            "seed '{}': FNV-1a state mismatch",
            v.seed
        );

        let mut raw = SeededRng::new(&v.seed);
        let observed: Vec<String> = (0..v.next.len())
            .map(|_| raw.next_u64().to_string())
            .collect();
        assert_eq!(observed, v.next, "seed '{}': SplitMix64 mismatch", v.seed);

        // Compare BIT PATTERNS, not the decimals: serde_json parses at least
        // one of the recorded decimals one ULP low (see the fixture note), and
        // one ULP of jitter is enough to swap two candidates on the rail.
        let mut jitter = SeededRng::new(&v.seed);
        let observed: Vec<String> = (0..v.jitter_0_to_12_bits.len())
            .map(|_| jitter.next_double(12.0).to_bits().to_string())
            .collect();
        assert_eq!(
            observed, v.jitter_0_to_12_bits,
            "seed '{}': the daily jitter does not reproduce bit-for-bit",
            v.seed
        );
        assert!(v
            .jitter_0_to_12_bits
            .iter()
            .map(|b| f64::from_bits(b.parse().unwrap()))
            .all(|d| (0.0..12.0).contains(&d)));
        // The decimals are for human readers; they must at least agree to
        // within a ULP, or one of the two renderings is wrong.
        for (bits, decimal) in v.jitter_0_to_12_bits.iter().zip(&v.jitter_0_to_12) {
            let exact = f64::from_bits(bits.parse().unwrap());
            assert!(
                (exact - decimal).abs() <= f64::EPSILON * 16.0,
                "seed '{}': {exact} and {decimal} are not the same draw",
                v.seed
            );
        }

        let mut unit = SeededRng::new(&v.seed);
        let observed: Vec<String> = (0..v.unit_0_to_1_bits.len())
            .map(|_| unit.next_double(1.0).to_bits().to_string())
            .collect();
        assert_eq!(
            observed, v.unit_0_to_1_bits,
            "seed '{}': unit draws",
            v.seed
        );
        assert_eq!(v.unit_0_to_1.len(), v.unit_0_to_1_bits.len());
    }
}

#[test]
fn seeded_rng_pins_the_nfc_nfd_divergence_and_the_day_seed_shape() {
    let dump: RngDump = parse("seeded_rng.json");
    let by_seed: BTreeMap<&str, &RngSeed> =
        dump.seeds.iter().map(|s| (s.seed.as_str(), s)).collect();

    // Canonically-equivalent seeds are `==` in Swift and must NOT collide here.
    let nfc = by_seed["caf\u{00E9}"];
    let nfd = by_seed["cafe\u{0301}"];
    assert_ne!(nfc.seed_utf8, nfd.seed_utf8);
    assert_ne!(
        nfc.next[0], nfd.next[0],
        "NFC and NFD spellings must produce different streams — a port that \
         normalizes its seed diverges from the app"
    );

    // The day seed is the local calendar day, so one instant maps to different
    // seeds in different zones. 2024-06-11T15:30Z is already the 12th in Tokyo.
    let by_zone: BTreeMap<&str, &str> = dump
        .day_seeds
        .iter()
        .map(|d| (d.time_zone.as_str(), d.seed.as_str()))
        .collect();
    assert_eq!(by_zone["UTC"], "2024-06-11");
    assert_eq!(by_zone["Asia/Tokyo"], "2024-06-12");
    assert_eq!(by_zone["America/Los_Angeles"], "2024-06-11");

    // forceRegenerate's seed is a Swift Double interpolation, not a date.
    assert!(dump
        .force_regenerate_seeds
        .iter()
        .all(|s| s.seed.contains('.')));
}

// ---------------------------------------------------------------------------
// memory_engine.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct EngineDump {
    schema: u32,
    environment: Environment,
    notes: Vec<String>,
    scenarios: Vec<EngineScenario>,
}

#[derive(Deserialize)]
struct Environment {
    #[serde(rename = "localeIdentifier")]
    locale_identifier: String,
    #[serde(rename = "calendarIdentifier")]
    calendar_identifier: String,
    #[serde(rename = "notes")]
    _notes: Vec<String>,
}

#[derive(Deserialize)]
struct EngineScenario {
    name: String,
    notes: Vec<String>,
    inputs: EngineInputs,
    expected: Vec<Memory>,
}

#[derive(Deserialize)]
struct EngineInputs {
    now: String,
    #[serde(rename = "timeZone")]
    time_zone: String,
    seed: String,
    #[serde(rename = "birthdaysEnabled")]
    birthdays_enabled: bool,
    #[serde(rename = "mePersonPath")]
    _me_person_path: String,
    #[serde(rename = "hiddenPeople")]
    hidden_people: Vec<String>,
    photos: Vec<Photo>,
    #[serde(rename = "leafFolders")]
    leaf_folders: Vec<Folder>,
    contacts: Vec<Contact>,
    #[serde(rename = "personContactLinks")]
    person_contact_links: Vec<Link>,
    #[serde(rename = "seenMemoryIDs")]
    seen_memory_ids: Vec<DateEntry>,
    #[serde(rename = "surfacedClusters")]
    surfaced_clusters: Vec<DateEntry>,
}

#[derive(Deserialize)]
struct Folder {
    path: String,
    name: String,
    #[serde(rename = "photoPaths")]
    photo_paths: Vec<String>,
}

#[derive(Deserialize)]
struct Contact {
    id: String,
    #[serde(rename = "givenName")]
    _given_name: String,
    #[serde(rename = "familyName")]
    _family_name: String,
    #[serde(rename = "birthdayMonth")]
    birthday_month: Option<u32>,
    #[serde(rename = "birthdayDay")]
    birthday_day: Option<u32>,
}

#[derive(Deserialize)]
struct Link {
    #[serde(rename = "personPath")]
    person_path: String,
    kind: String,
    #[serde(rename = "contactID")]
    contact_id: Option<String>,
}

#[derive(Deserialize)]
struct DateEntry {
    key: String,
    date: String,
}

fn engine() -> EngineDump {
    parse("memory_engine.json")
}

fn scenario<'a>(dump: &'a EngineDump, name: &str) -> &'a EngineScenario {
    dump.scenarios
        .iter()
        .find(|s| s.name == name)
        .unwrap_or_else(|| panic!("no scenario '{name}'"))
}

#[test]
fn memory_engine_fixture_deserializes_and_is_internally_consistent() {
    let dump = engine();
    assert_eq!(dump.schema, 1);
    assert!(!dump.notes.is_empty());
    assert_eq!(dump.environment.calendar_identifier, "gregorian");
    assert_eq!(
        dump.environment.locale_identifier, "en_US",
        "the pinned subtitles and country names belong to this locale"
    );
    assert!(dump.scenarios.len() >= 14, "the scenario set shrank");

    let mut names = BTreeSet::new();
    for s in &dump.scenarios {
        assert!(
            names.insert(s.name.as_str()),
            "duplicate scenario {}",
            s.name
        );
        assert!(!s.notes.is_empty(), "{} lost its notes", s.name);
        assert!(s.inputs.now.ends_with('Z'), "{}", s.name);
        assert!(!s.inputs.time_zone.is_empty());
        assert!(!s.inputs.seed.is_empty());
        assert!(s.expected.len() <= 10, "{}: selection cap is 10", s.name);

        let photo_ids: BTreeSet<&str> = s.inputs.photos.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(
            photo_ids.len(),
            s.inputs.photos.len(),
            "{}: duplicate photo ids",
            s.name
        );
        for p in &s.inputs.photos {
            assert!(p.path.starts_with("/fixtures/"), "{}: {}", s.name, p.path);
            assert_eq!(p.id, p.id.to_uppercase(), "ids are uppercase UUID strings");
            assert_eq!(p.id.len(), 36);
            assert!(!p.filename.is_empty());
            assert!(
                !p.is_video,
                "the engine never sees videos in these fixtures"
            );
            if let Some(d) = &p.date_taken {
                assert!(d.ends_with('Z'), "{}: {}", s.name, d);
            }
            assert_eq!(p.gps_latitude.is_some(), p.gps_longitude.is_some());
            if let Some(cc) = &p.country_code {
                assert_eq!(cc, &cc.to_uppercase());
            }
        }
        for f in &s.inputs.leaf_folders {
            assert!(!f.name.is_empty());
            assert!(f.path.starts_with("/fixtures/"));
            assert!(!f.photo_paths.is_empty());
        }
        for l in &s.inputs.person_contact_links {
            assert!(matches!(l.kind.as_str(), "manual" | "disabled"));
            assert_eq!(l.kind == "manual", l.contact_id.is_some());
            assert!(l.person_path.starts_with("People/"));
        }
        for c in &s.inputs.contacts {
            assert!(!c.id.is_empty());
            assert_eq!(c.birthday_month.is_some(), c.birthday_day.is_some());
        }
        for e in s
            .inputs
            .seen_memory_ids
            .iter()
            .chain(&s.inputs.surfaced_clusters)
        {
            assert!(e.date.ends_with('Z'), "{}: {}", s.name, e.date);
            assert!(!e.key.is_empty());
        }
        for _ in &s.inputs.hidden_people {}

        // Output invariants.
        let mut clusters = BTreeSet::new();
        for m in &s.expected {
            assert!(
                clusters.insert(cluster_key(&m.id)),
                "{}: two memories share cluster {}",
                s.name,
                cluster_key(&m.id)
            );
            assert!(
                matches!(
                    m.kind.as_str(),
                    "onThisDay" | "yearsAgo" | "folderEvent" | "photoDensity" | "trip" | "birthday"
                ),
                "{}: unexpected memory type {}",
                s.name,
                m.kind
            );
            assert_eq!(m.photo_count, m.photo_ids.len());
            assert!(m.photo_count <= 75, "{}/{}: the cap is 75", s.name, m.id);
            assert!(m.photo_count > 0);
            assert!(
                m.photo_ids.contains(&m.cover_photo_id),
                "{}/{}: the cover must be in the memory's own photo set",
                s.name,
                m.id
            );
            for id in &m.photo_ids {
                assert!(
                    photo_ids.contains(id.as_str()),
                    "{}/{}: photo id not in the input library",
                    s.name,
                    m.id
                );
            }
            let subtitle = m.subtitle.as_deref().expect("finalize always sets one");
            assert!(
                subtitle.ends_with(&format!("{} photos", m.photo_count))
                    || subtitle.ends_with("1 photo"),
                "{}/{}: subtitle '{subtitle}' does not end in the capped count",
                s.name,
                m.id
            );
            assert_eq!(
                m.years_ago.is_some(),
                m.kind == "yearsAgo",
                "{}/{}: yearsAgo is set exactly for yearsAgo memories",
                s.name,
                m.id
            );
            assert_eq!(
                m.person_name.is_some(),
                m.kind == "birthday",
                "{}/{}: personName is set exactly for birthdays",
                s.name,
                m.id
            );
            assert_eq!(m.date_range_start.is_some(), m.date_range_end.is_some());
            if !s.inputs.birthdays_enabled {
                assert_ne!(m.kind, "birthday", "{}: the toggle is off", s.name);
            }
        }
    }
}

/// The score ladder, read back off the fixture. These numbers are the contract;
/// `_plans/05-phase-4-indexes-memories.md` documents them in prose and this is
/// the copy that fails when the prose drifts.
#[test]
fn memory_engine_fixture_pins_the_score_ladder() {
    let dump = engine();

    let s = scenario(&dump, "on-this-day-and-years-ago-overlap");
    assert_eq!(s.expected[0].id, "onThisDay-2024-06-11");
    assert_eq!(s.expected[0].score, 55.0, "50 + 5 per distinct year (1)");
    assert_eq!(s.expected[1].score, 40.0, "yearsAgo 5..9");

    let s = scenario(&dump, "years-ago-milestone-ladder");
    assert_eq!(s.expected[0].score, 70.0, "50 + 5 × 4 distinct years");
    let by_id: BTreeMap<&str, &Memory> = s.expected.iter().map(|m| (m.id.as_str(), m)).collect();
    assert_eq!(by_id["yearsAgo-10-2024-06-11"].score, 45.0);
    assert_eq!(by_id["yearsAgo-3-2024-06-11"].score, 35.0);
    assert_eq!(by_id["yearsAgo-1-2024-06-11"].score, 35.0);
    assert!(
        !s.expected.iter().any(|m| m.id.contains("yearsAgo-6")),
        "6 years is not a milestone: [1, 2, 3, 5, 10, 15, 20]"
    );

    let s = scenario(&dump, "photo-density-single-busy-day");
    assert_eq!(s.expected.len(), 1);
    assert_eq!(s.expected[0].id, "density-2022-3-5", "no zero padding");
    assert_eq!(s.expected[0].score, 8.0);
    assert_eq!(s.expected[0].title, "A busy day");

    let s = scenario(&dump, "folder-events");
    assert!(s.expected.iter().all(|m| m.kind == "folderEvent"));
    assert!(
        s.expected.iter().all(|m| (10.0..=24.0).contains(&m.score)),
        "10 + min(daySpan, 14)"
    );
    assert!(s.expected.iter().all(|m| m.id.starts_with("folder-")));

    let s = scenario(&dump, "trip-with-subtrips-cluster-uniqueness");
    assert_eq!(s.expected.len(), 1, "parent + sub-trips are ONE cluster");
    assert_eq!(s.expected[0].id, "trip-2023-9-1");
    assert_eq!(s.expected[0].score, 20.0 + 7.0 * 1.5);
    assert_eq!(
        s.expected[0].title, "Argentina & Chile with Anna & Ben",
        "two countries at 50/50 defeat the 90% dominance rule; mePersonPath is \
         dropped from the suffix and names reduce to first names"
    );

    let s = scenario(&dump, "birthday-today-with-an-undated-photo");
    assert_eq!(s.expected[0].kind, "birthday");
    assert_eq!(s.expected[0].score, 100.0);
    assert_eq!(s.expected[0].title, "Happy birthday, Alice Anderson");
    assert_eq!(s.expected[0].id, "birthday-People/Alice Anderson");
}

/// The landmines: each is a place a reasonable Rust implementation would do
/// something *better* than the Swift, and therefore wrong.
#[test]
fn memory_engine_fixture_still_records_the_known_oddities() {
    let dump = engine();

    // 1. The ID's date is rendered in GMT; the calendar day is local. In Tokyo
    //    a memory about June 12 is called `onThisDay-2024-06-11`.
    let s = scenario(&dump, "non-utc-timezone-asia-tokyo");
    assert_eq!(s.inputs.time_zone, "Asia/Tokyo");
    assert_eq!(s.expected[0].id, "onThisDay-2024-06-11");
    assert!(
        s.expected[0]
            .subtitle
            .as_deref()
            .unwrap()
            .contains("Jun 12"),
        "…while the photos it selected are the June-12-local ones"
    );
    assert_eq!(
        s.expected[0].photo_count, 12,
        "the June-11-local set is excluded"
    );

    // 2. A seen memory (−30) can lose its cluster to its own sub-trip.
    let seen = scenario(&dump, "trip-parent-seen-penalty-promotes-a-subtrip");
    let plain = scenario(&dump, "trip-with-subtrips-cluster-uniqueness");
    assert_eq!(plain.expected[0].id, "trip-2023-9-1");
    assert!(
        seen.expected[0].id.starts_with("subtrip-2023-9-1-"),
        "the −30 penalty must change the SELECTION, not just the order; got {}",
        seen.expected[0].id
    );
    assert_eq!(cluster_key(&seen.expected[0].id), "trip-2023-9-1");
    assert_eq!(
        seen.inputs.seen_memory_ids.len(),
        1,
        "one seen id, applied to the parent alone"
    );

    // 3. The cluster cool-down (−25) hits every member, so a folder event with
    //    a lower raw score outranks a trip.
    let cool = scenario(&dump, "trip-cluster-cooldown-penalty");
    assert_eq!(cool.expected[0].kind, "folderEvent");
    assert_eq!(cool.expected[0].score, 24.0);
    assert_eq!(cool.expected[1].id, "trip-2023-9-1");
    assert!(
        cool.expected[1].score > cool.expected[0].score,
        "the trip's RAW score is higher — only the penalty reorders them, which \
         is why scores and order are pinned separately"
    );

    // 4. Same-name folder memories collapse to the biggest, compared
    //    case-insensitively, and the survivor keeps its own spelling.
    let dup = scenario(&dump, "folder-name-dedupe-keeps-the-biggest");
    assert_eq!(dup.expected.len(), 1);
    assert_eq!(dup.expected[0].title, "unsorted");
    assert_eq!(dup.expected[0].photo_count, 22);

    // 5. finalize caps at 75 by even sampling, and re-points a cover the
    //    sampling dropped.
    let cap = scenario(&dump, "finalize-caps-at-75-and-repoints-the-cover");
    assert_eq!(cap.inputs.photos.len(), 151);
    let input_ids: Vec<&str> = cap.inputs.photos.iter().map(|p| p.id.as_str()).collect();
    for m in &cap.expected {
        assert_eq!(m.photo_count, 75);
        let sampled: Vec<usize> = (0..75)
            .map(|i| (i as f64 * (151.0 / 75.0)) as usize)
            .collect();
        let expected_ids: Vec<&str> = sampled.iter().map(|i| input_ids[*i]).collect();
        assert_eq!(m.photo_ids, expected_ids, "{}: sampling rule", m.id);
        assert!(
            !sampled.contains(&75),
            "index 75 — the original cover — is skipped"
        );
        assert_eq!(
            m.cover_photo_id, m.photo_ids[37],
            "{}: the dropped cover is re-pointed at the sampled middle",
            m.id
        );
        assert!(m.subtitle.as_deref().unwrap().ends_with("75 photos"));
    }

    // 6. Birthday memories include undated photos; every other generator
    //    cannot see them.
    let bday = scenario(&dump, "birthday-today-with-an-undated-photo");
    let undated: BTreeSet<&str> = bday
        .inputs
        .photos
        .iter()
        .filter(|p| p.date_taken.is_none())
        .map(|p| p.id.as_str())
        .collect();
    assert_eq!(undated.len(), 1);
    let birthday = &bday.expected[0];
    assert!(
        birthday
            .photo_ids
            .iter()
            .any(|id| undated.contains(id.as_str())),
        "the undated photo is in the birthday memory"
    );
    assert_eq!(
        birthday.photo_ids[0],
        *undated.iter().next().unwrap(),
        "undated photos sort to the FRONT (distantPast)"
    );
    assert_eq!(
        birthday.cover_photo_id,
        *birthday.photo_ids.last().unwrap(),
        "the cover is ids.last — the most recent dated photo"
    );
    assert!(
        birthday.date_range_start.is_some(),
        "an undated photo must not collapse the range"
    );
    for other in &bday.expected[1..] {
        assert!(!other
            .photo_ids
            .iter()
            .any(|id| undated.contains(id.as_str())));
    }

    // 7. `.disabled` and a hidden person both suppress; `.manual` beats the
    //    name auto-match and the title still uses the TAG's display name.
    let links = scenario(&dump, "birthday-links-manual-disabled-hidden");
    assert_eq!(links.expected.len(), 1);
    assert_eq!(links.expected[0].id, "birthday-People/Dave");
    assert_eq!(links.expected[0].title, "Happy birthday, Dave");
    assert_eq!(links.expected[0].person_name.as_deref(), Some("Dave"));
    assert!(links
        .inputs
        .hidden_people
        .contains(&"People/Erin Hidden".to_string()));
    assert!(links
        .inputs
        .person_contact_links
        .iter()
        .any(|l| l.person_path == "People/Carol Clark" && l.kind == "disabled"));

    // 8. The 10-memory cutoff, with the tail decided purely by the jitter.
    let cutoff = scenario(&dump, "ten-memory-greedy-cutoff");
    assert_eq!(cutoff.expected.len(), 10);
    assert_eq!(cutoff.inputs.leaf_folders.len(), 12);
    let folder_events = cutoff
        .expected
        .iter()
        .filter(|m| m.kind == "folderEvent")
        .count();
    assert_eq!(
        folder_events, 8,
        "12 candidates, 8 seats left after the top 2"
    );

    // 9. An empty library produces nothing at all — no crash, no placeholder.
    assert!(scenario(&dump, "empty-library").expected.is_empty());
}

// ---------------------------------------------------------------------------
// scheduled_memories.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ScheduledDump {
    schema: u32,
    #[serde(rename = "environment")]
    _environment: Environment,
    notes: Vec<String>,
    scenarios: Vec<ScheduledScenario>,
}

#[derive(Deserialize)]
struct ScheduledScenario {
    name: String,
    notes: Vec<String>,
    #[serde(rename = "timeZone")]
    time_zone: String,
    today: String,
    #[serde(rename = "horizonDays")]
    horizon_days: i32,
    #[serde(rename = "photos")]
    _photos: Vec<Photo>,
    #[serde(rename = "birthdaysEnabled")]
    birthdays_enabled: bool,
    scheduled: Vec<ScheduledItem>,
    parity: Vec<ParityDay>,
}

#[derive(Deserialize)]
struct ScheduledItem {
    #[serde(rename = "dayOffset")]
    day_offset: i32,
    #[serde(rename = "validFrom")]
    valid_from: String,
    #[serde(rename = "validTo")]
    valid_to: String,
    memory: Memory,
}

#[derive(Deserialize)]
struct ParityDay {
    #[serde(rename = "dayOffset")]
    day_offset: i32,
    #[serde(rename = "scheduledIDs")]
    scheduled_ids: Vec<String>,
    #[serde(rename = "liveGeneratedIDs")]
    _live_generated_ids: Vec<String>,
    #[serde(rename = "matchedIDs")]
    matched_ids: Vec<String>,
    #[serde(rename = "contentIdenticalForMatchedIDs")]
    content_identical: bool,
    #[serde(rename = "scheduledButNotGeneratedLive")]
    scheduled_but_not_generated_live: Vec<String>,
}

#[test]
fn scheduled_memories_fixture_pins_the_horizon_and_the_parity_invariant() {
    let dump: ScheduledDump = parse("scheduled_memories.json");
    assert_eq!(dump.schema, 1);
    assert!(!dump.notes.is_empty());
    assert!(dump.scenarios.len() >= 4);

    for s in &dump.scenarios {
        assert!(!s.notes.is_empty(), "{} lost its notes", s.name);
        assert_eq!(s.horizon_days, 7);
        assert!(s.today.ends_with('Z'));
        assert_eq!(
            s.parity.iter().map(|p| p.day_offset).collect::<Vec<_>>(),
            (1..=7).collect::<Vec<_>>()
        );
        for item in &s.scheduled {
            assert!(
                (1..=7).contains(&item.day_offset),
                "{}: day 0 is never pre-published — it is already on the rail",
                s.name
            );
            assert!(item.valid_from < item.valid_to);
            assert!(
                matches!(
                    item.memory.kind.as_str(),
                    "onThisDay" | "yearsAgo" | "birthday"
                ),
                "{}: only calendar-tied types are pre-published, got {}",
                s.name,
                item.memory.kind
            );
            assert!(
                item.memory.subtitle.is_some(),
                "the same finalize runs here"
            );
            assert!(item.memory.photo_ids.contains(&item.memory.cover_photo_id));
            assert!(item.memory.photo_count <= 75);
            if !s.birthdays_enabled {
                assert_ne!(item.memory.kind, "birthday");
            }
        }
        assert!(
            s.scheduled.iter().any(|i| !i.memory.id.is_empty()),
            "{} pre-published nothing at all",
            s.name
        );
    }

    // In UTC the acceptance criterion holds: the id pre-published for day N is
    // the id the live pipeline produces on day N, with identical content.
    for s in dump.scenarios.iter().filter(|s| s.time_zone == "UTC") {
        for day in &s.parity {
            assert!(day.content_identical, "{} +{}", s.name, day.day_offset);
            assert!(
                day.scheduled_but_not_generated_live.is_empty(),
                "{} +{}: pre-published ids the live run never produces: {:?}",
                s.name,
                day.day_offset,
                day.scheduled_but_not_generated_live
            );
            assert_eq!(day.matched_ids.len(), day.scheduled_ids.len());
        }
    }

    // …and in a zone ahead of GMT it does NOT. `computeScheduledMemories`
    // walks days from LOCAL midnight while the id is rendered in GMT, so every
    // calendar-tied widget item in Asia/Tokyo carries the previous day's date.
    // Pinned as a fact about the shipping app, not as an aspiration: a port
    // that "fixes" it changes which widget deep links resolve.
    let tokyo = dump
        .scenarios
        .iter()
        .find(|s| s.time_zone == "Asia/Tokyo")
        .expect("the non-UTC scenario is part of the spec");
    let drifted: Vec<&ParityDay> = tokyo
        .parity
        .iter()
        .filter(|p| !p.scheduled_but_not_generated_live.is_empty())
        .collect();
    assert!(
        !drifted.is_empty(),
        "the Tokyo id drift disappeared — if that was deliberate, this test and \
         the README section it points at both need rewriting"
    );
    for day in &drifted {
        assert!(
            day.matched_ids.is_empty(),
            "+{}: the drift is total for calendar-tied items",
            day.day_offset
        );
    }
    // Birthday ids are not date-qualified, so they survive the drift.
    let birthday_days: Vec<&ParityDay> = tokyo
        .parity
        .iter()
        .filter(|p| p.matched_ids.iter().any(|id| id.starts_with("birthday-")))
        .collect();
    assert!(
        !birthday_days.is_empty(),
        "birthday ids carry no date and must still match across the drift"
    );
}

// ---------------------------------------------------------------------------
// search_index.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct SearchDump {
    schema: u32,
    notes: Vec<String>,
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
    notes: Vec<String>,
}

#[test]
fn search_index_fixture_pins_the_sort_and_the_query_semantics() {
    let dump: SearchDump = parse("search_index.json");
    assert_eq!(dump.schema, 1);
    assert!(!dump.notes.is_empty());

    let by_id: BTreeMap<&str, &Photo> = dump.photos.iter().map(|p| (p.id.as_str(), p)).collect();
    assert_eq!(
        dump.sorted_photo_ids.len(),
        dump.photos.len(),
        "the sort must not drop or duplicate photos"
    );

    // Date descending, undated last, ties on url.path ascending.
    let mut seen_undated = false;
    for pair in dump.sorted_photo_ids.windows(2) {
        let a = by_id[pair[0].as_str()];
        let b = by_id[pair[1].as_str()];
        if a.date_taken.is_none() {
            seen_undated = true;
        }
        if seen_undated {
            assert!(
                b.date_taken.is_none(),
                "a dated photo ({}) sorted below an undated one",
                b.path
            );
        }
        match (&a.date_taken, &b.date_taken) {
            (Some(x), Some(y)) if x != y => {
                assert!(x > y, "not date-descending: {} then {}", a.path, b.path)
            }
            _ => assert!(
                a.path < b.path,
                "tied photos are not in ascending path order: {} then {}",
                a.path,
                b.path
            ),
        }
    }

    // The corpus: filename, then (displayName, fullPath) per tag, lowercased.
    let corpus: BTreeMap<&str, &CorpusEntry> = dump
        .corpus
        .iter()
        .map(|c| (c.photo_id.as_str(), c))
        .collect();
    assert_eq!(corpus.len(), dump.photos.len());
    for p in &dump.photos {
        let entry = corpus[p.id.as_str()];
        assert_eq!(entry.terms.len(), 1 + p.tags.len() * 2);
        assert_eq!(entry.terms[0], p.filename.to_lowercase());
        for t in &entry.terms {
            assert_eq!(t, &t.to_lowercase());
        }
    }

    let q = |text: &str, tags: &[&str]| -> &Query {
        dump.queries
            .iter()
            .find(|q| q.query == text && q.required_tag_paths == tags)
            .unwrap_or_else(|| panic!("no query {text:?} with tags {tags:?}"))
    };
    let names = |query: &Query| -> Vec<&str> {
        query
            .expected_photo_ids
            .iter()
            .map(|id| by_id[id.as_str()].filename.as_str())
            .collect()
    };

    assert!(dump.queries.iter().all(|q| !q.notes.is_empty()));

    // Empty query = the sorted list, untouched.
    assert_eq!(q("", &[]).expected_photo_ids, dump.sorted_photo_ids);
    // Case folds.
    assert_eq!(
        q("rome", &[]).expected_photo_ids,
        q("ROME", &[]).expected_photo_ids
    );
    // Results keep the sorted order.
    for query in &dump.queries {
        let positions: Vec<usize> = query
            .expected_photo_ids
            .iter()
            .map(|id| dump.sorted_photo_ids.iter().position(|s| s == id).unwrap())
            .collect();
        assert!(
            positions.windows(2).all(|w| w[0] < w[1]),
            "query {:?} does not preserve the sorted order",
            query.query
        );
    }

    // The tag branch: an exact tag-path query filters by the tag, and a Places
    // namespace also matches everything nested under it.
    let italy = q("places/italy", &[]);
    assert_eq!(italy.expected_photo_ids.len(), 4);
    assert!(
        names(italy).contains(&"milan"),
        "prefix expansion reaches Lombardy/Milan"
    );
    // A virtual prefix nobody carries exactly is still a queryable tag.
    assert_eq!(q("places/italy/lazio", &[]).expected_photo_ids.len(), 3);
    // Non-Places namespaces are exact-match only.
    assert_eq!(q("people/alice anderson", &[]).expected_photo_ids.len(), 2);

    // A multi-token query is ONE substring, not tokens.
    assert_eq!(names(q("beach italy", &[])), vec!["Beach Italy"]);
    assert!(
        q("italy beach", &[]).expected_photo_ids.is_empty(),
        "reversing the words matches nothing — the corpus is a substring, not an index"
    );
    assert!(q("zzz-no-such-thing", &[]).expected_photo_ids.is_empty());

    // LANDMINE: matching is Swift's String search, i.e. canonical equivalence,
    // NOT byte equality — the query is precomposed and the filename on disk is
    // decomposed, and they match anyway. A byte-comparing Rust port silently
    // stops finding accented names.
    assert_eq!(names(q("caf\u{00E9}", &[])).len(), 1);
    let cafe_photo = by_id[q("caf\u{00E9}", &[]).expected_photo_ids[0].as_str()];
    assert!(
        cafe_photo.path.contains('\u{0301}'),
        "the fixture's café is decomposed on disk; if it is not, this case \
         stopped testing what it was written for"
    );
    // …and canonical equivalence is not accent folding.
    assert!(q("cafe", &[]).expected_photo_ids.is_empty());
    // …while a dotted capital İ, whose lowercase is i + U+0307, DOES match a
    // plain "istanbul". Recorded, not explained: reproduce it.
    assert_eq!(q("istanbul", &[]).expected_photo_ids.len(), 1);

    // Required tags AND together, are applied before the query, and get the
    // same Places prefix treatment.
    assert_eq!(q("", &["Places/Italy"]).expected_photo_ids.len(), 4);
    assert_eq!(
        q("", &["Places/Italy", "Scenes/Beach"])
            .expected_photo_ids
            .len(),
        1
    );
    assert_eq!(names(q("alice", &["Scenes/Beach"])), vec!["alice2"]);
    assert_eq!(names(q("", &["Vacation"])), vec!["flat"]);
}

// ---------------------------------------------------------------------------
// tag_index.json
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct TagDump {
    schema: u32,
    notes: Vec<String>,
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

#[derive(Deserialize)]
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

#[test]
fn tag_index_fixture_pins_the_buckets_and_the_prefix_expansion() {
    let dump: TagDump = parse("tag_index.json");
    assert_eq!(dump.schema, 1);
    assert!(
        dump.notes.iter().any(|n| n.contains("NONDETERMINISM")),
        "the tie-order caveat is part of the fixture"
    );

    let photo_order: Vec<&str> = dump.photos.iter().map(|p| p.id.as_str()).collect();
    let by_key: BTreeMap<&str, &Bucket> =
        dump.buckets.iter().map(|b| (b.key.as_str(), b)).collect();

    for b in &dump.buckets {
        assert_eq!(b.key, b.key.to_lowercase());
        let canonical = b
            .canonical_path
            .as_deref()
            .expect("every key has a spelling");
        assert_eq!(canonical.to_lowercase(), b.key);
        let unique: BTreeSet<&str> = b.photo_ids.iter().map(String::as_str).collect();
        assert_eq!(
            unique.len(),
            b.photo_ids.len(),
            "{}: a photo is credited twice",
            b.key
        );
        // Bucket order is `allPhotos` order.
        let positions: Vec<usize> = b
            .photo_ids
            .iter()
            .map(|id| photo_order.iter().position(|p| p == id).unwrap())
            .collect();
        assert!(
            positions.windows(2).all(|w| w[0] < w[1]),
            "{}: bucket order is not allPhotos order",
            b.key
        );
    }

    // Prefix expansion: only for the prefix-matching namespaces, only from
    // depth 2, so the bare namespace is never a bucket.
    assert!(by_key.contains_key("places/italy"));
    assert!(
        by_key.contains_key("places/italy/lazio"),
        "a virtual prefix tag"
    );
    assert!(
        !by_key.contains_key("places"),
        "the bare namespace is not a bucket"
    );
    assert!(
        !by_key.contains_key("people"),
        "People is not a prefix-matching namespace"
    );
    assert_eq!(
        by_key["places/italy"].photo_ids.len(),
        4,
        "3 Rome + 1 Milan, and the photo carrying BOTH Places/Italy and \
         Places/Italy/Lazio/Rome is counted once"
    );
    assert_eq!(by_key["places/italy/lazio"].photo_ids.len(), 3);
    assert_eq!(
        by_key["vacation"].photo_ids.len(),
        1,
        "a flat, namespace-less tag"
    );

    // Suggestions: one per bucket, count == bucket size, grouped count-desc.
    assert_eq!(dump.tag_suggestions.len(), dump.buckets.len());
    for s in &dump.tag_suggestions {
        assert_eq!(s.id, s.full_path.to_lowercase());
        assert_eq!(s.count, by_key[s.id.as_str()].photo_ids.len());
        assert!(s.full_path.ends_with(&s.display_name));
        match s.full_path.split('/').count() {
            1 => assert!(s.namespace.is_none(), "{}", s.full_path),
            _ => assert!(s.namespace.is_some(), "{}", s.full_path),
        }
        assert!(
            s.latest_photo_date.is_none(),
            "latestPhotoDate is a people-list field only"
        );
    }
    assert!(
        dump.tag_suggestions
            .windows(2)
            .all(|w| w[0].count > w[1].count || (w[0].count == w[1].count && w[0].id < w[1].id)),
        "the fixture stores the canonical (count desc, id asc) order"
    );

    for p in &dump.people_suggestions {
        assert_eq!(
            p.namespace.as_deref().map(str::to_lowercase).as_deref(),
            Some("people")
        );
        assert!(
            p.latest_photo_date.as_deref().unwrap().ends_with('Z'),
            "people carry their most recent photo date"
        );
        assert_eq!(p.count, by_key[p.id.as_str()].photo_ids.len());
    }
    assert_eq!(dump.people_suggestions.len(), 2);
}
