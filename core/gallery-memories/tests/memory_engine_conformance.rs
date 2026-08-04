//! `memory_engine.json`, run against `gallery_memories::generate`.
//!
//! All 15 scenarios, compared memory by memory and field by field: id, type,
//! title, subtitle, the ordered photo list, the cover, the pre-jitter score,
//! `yearsAgo`, `personName` and the date range — **and the order of the list**,
//! which is the only place the seeded jitter is observable.
//!
//! The fixture was generated from the shipping Swift before any of this
//! existed. Where the Swift is buggy the bug is pinned; see the landmine list
//! in `core/fixtures/memories-conformance/README.md`.

#[path = "support/fixture.rs"]
mod fixture;

use fixture::*;
use gallery_memories::{generate, generate_cancellable, GenerationInputs};
use serde::Deserialize;

#[derive(Deserialize)]
struct EngineDump {
    schema: u32,
    environment: Environment,
    scenarios: Vec<Scenario>,
}

#[derive(Deserialize)]
struct Environment {
    #[serde(rename = "localeIdentifier")]
    locale_identifier: String,
    #[serde(rename = "calendarIdentifier")]
    calendar_identifier: String,
}

#[derive(Deserialize)]
struct Scenario {
    name: String,
    notes: Vec<String>,
    inputs: Inputs,
    expected: Vec<ConfMemory>,
}

#[derive(Deserialize)]
struct Inputs {
    now: String,
    #[serde(rename = "timeZone")]
    time_zone: String,
    seed: String,
    #[serde(rename = "birthdaysEnabled")]
    birthdays_enabled: bool,
    #[serde(rename = "mePersonPath")]
    me_person_path: String,
    #[serde(rename = "hiddenPeople")]
    hidden_people: Vec<String>,
    photos: Vec<ConfPhoto>,
    #[serde(rename = "leafFolders")]
    leaf_folders: Vec<ConfFolder>,
    contacts: Vec<ConfContact>,
    #[serde(rename = "personContactLinks")]
    person_contact_links: Vec<ConfLink>,
    #[serde(rename = "seenMemoryIDs")]
    seen_memory_ids: Vec<ConfDateEntry>,
    #[serde(rename = "surfacedClusters")]
    surfaced_clusters: Vec<ConfDateEntry>,
}

impl Scenario {
    fn to_inputs(&self) -> GenerationInputs {
        let i = &self.inputs;
        let mut inputs = inputs_from(
            &i.photos,
            &i.leaf_folders,
            &i.contacts,
            &i.person_contact_links,
            i.birthdays_enabled,
            &i.me_person_path,
            &i.hidden_people,
            &i.now,
            &i.time_zone,
            &i.seed,
        );
        inputs.seen_memory_ids = date_map(&i.seen_memory_ids);
        inputs.surfaced_clusters = date_map(&i.surfaced_clusters);
        inputs
    }
}

fn dump() -> EngineDump {
    read_fixture("memory_engine.json")
}

/// The suite. One assertion per scenario, over the whole selected list.
#[test]
fn every_scenario_reproduces_its_selected_memories() {
    let dump = dump();
    assert_eq!(dump.schema, 1);
    assert_eq!(dump.environment.calendar_identifier, "gregorian");
    assert_eq!(
        dump.environment.locale_identifier, "en_US",
        "the pinned subtitles and country names belong to this locale, and \
         `gallery_memories::locale` implements exactly it"
    );
    assert!(dump.scenarios.len() >= 15, "the scenario set shrank");

    for scenario in &dump.scenarios {
        assert!(
            !scenario.notes.is_empty(),
            "{} lost its notes",
            scenario.name
        );
        let observed: Vec<ConfMemory> = generate(&scenario.to_inputs())
            .iter()
            .map(ConfMemory::of)
            .collect();
        assert_eq!(
            observed, scenario.expected,
            "scenario `{}` diverged",
            scenario.name
        );
    }
}

/// Same inputs, same output — the property the whole fixture rests on, and the
/// one `MemoryEngineConformanceTests.testScenariosAreOrderStable` guards on the
/// Swift side (where it can fail, because two stages walk a `Dictionary`).
#[test]
fn generation_is_reproducible() {
    for scenario in &dump().scenarios {
        let inputs = scenario.to_inputs();
        assert_eq!(
            generate(&inputs),
            generate(&inputs),
            "scenario `{}` is not reproducible",
            scenario.name
        );
    }
}

/// Cancellation between ladder stages, which no completed run can observe and
/// the fixture therefore does not pin. Owned by the port.
#[test]
fn a_cancelled_run_returns_nothing() {
    let scenario = dump()
        .scenarios
        .into_iter()
        .find(|s| s.name == "ten-memory-greedy-cutoff")
        .expect("the largest scenario");
    let inputs = scenario.to_inputs();
    assert!(!generate(&inputs).is_empty());
    assert!(generate_cancellable(&inputs, &|| true).is_empty());
}

// ---------------------------------------------------------------------------
// The landmines, asserted by name
// ---------------------------------------------------------------------------
//
// `every_scenario_reproduces_its_selected_memories` already covers all of
// these. They are restated so that a failure names the behaviour that broke
// instead of an array index, and so a future reader can see which lines of the
// port are load-bearing.

fn scenario_named<'a>(dump: &'a EngineDump, name: &str) -> &'a Scenario {
    dump.scenarios
        .iter()
        .find(|s| s.name == name)
        .unwrap_or_else(|| panic!("no scenario `{name}`"))
}

fn run(dump: &EngineDump, name: &str) -> Vec<ConfMemory> {
    generate(&scenario_named(dump, name).to_inputs())
        .iter()
        .map(ConfMemory::of)
        .collect()
}

/// Landmine 2: the id's date is rendered in GMT while the day it is about is
/// local. In Tokyo the engine selects the June-12-local photos and calls the
/// memory `onThisDay-2024-06-11`.
#[test]
fn a_memory_id_is_gmt_while_its_day_is_local() {
    let dump = dump();
    let out = run(&dump, "non-utc-timezone-asia-tokyo");
    assert_eq!(out[0].id, "onThisDay-2024-06-11");
    assert!(out[0].subtitle.as_deref().unwrap().contains("Jun 12"));
    assert_eq!(out[0].photo_count, 12, "the June-11-local set is excluded");
}

/// Landmine 8, first half: the seen penalty is keyed by memory **id**, so a
/// penalised trip parent loses its cluster to its own sub-trip. The penalty has
/// to change the SELECTION, not just the order.
#[test]
fn the_seen_penalty_can_promote_a_subtrip_over_its_parent() {
    let dump = dump();
    assert_eq!(
        run(&dump, "trip-with-subtrips-cluster-uniqueness")[0].id,
        "trip-2023-9-1"
    );
    let penalised = run(&dump, "trip-parent-seen-penalty-promotes-a-subtrip");
    assert_eq!(penalised.len(), 1);
    assert_eq!(penalised[0].id, "subtrip-2023-9-1-cl");
    assert_eq!(
        gallery_memories::cluster_key(&penalised[0].id),
        "trip-2023-9-1"
    );
}

/// Landmine 8, second half: the cool-down is keyed by **cluster**, so it
/// demotes a trip below a folder event whose raw score is lower.
#[test]
fn the_cluster_cooldown_reorders_by_penalty_not_by_score() {
    let out = run(&dump(), "trip-cluster-cooldown-penalty");
    assert_eq!(out[0].kind, "folderEvent");
    assert_eq!(out[0].score, 24.0);
    assert_eq!(out[1].id, "trip-2023-9-1");
    assert!(
        out[1].score > out[0].score,
        "the trip's RAW score is higher — only the penalty reorders them"
    );
}

/// Landmine 9: two sub-trips are generated and scored; the cluster is claimed
/// by whoever sorts first and the rest vanish without a trace.
#[test]
fn only_one_member_of_a_cluster_reaches_the_rail() {
    let out = run(&dump(), "trip-with-subtrips-cluster-uniqueness");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].id, "trip-2023-9-1");
    assert_eq!(out[0].score, 20.0 + 7.0 * 1.5);
    assert_eq!(
        out[0].title, "Argentina & Chile with Anna & Ben",
        "two countries at 50/50 defeat the 90% dominance rule; the me-tag is \
         dropped and names reduce to first names"
    );
}

/// Landmine 10: same-name folder memories collapse to the biggest, compared
/// case-insensitively, and the survivor keeps its own spelling.
#[test]
fn same_name_folders_collapse_to_the_biggest() {
    let out = run(&dump(), "folder-name-dedupe-keeps-the-biggest");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "unsorted");
    assert_eq!(out[0].photo_count, 22);
}

/// Landmine 11: `finalize` samples `Int(i × count / 75)` and re-points the
/// cover only when the sampling drops it, at the sampled middle. 151 photos is
/// chosen precisely because index 75 — the cover — is one the sampling skips.
#[test]
fn finalize_caps_at_75_and_repoints_a_dropped_cover() {
    let dump = dump();
    let scenario = scenario_named(&dump, "finalize-caps-at-75-and-repoints-the-cover");
    let input_ids: Vec<&str> = scenario
        .inputs
        .photos
        .iter()
        .map(|p| p.id.as_str())
        .collect();
    assert_eq!(input_ids.len(), 151);
    let sampled: Vec<usize> = (0..75)
        .map(|i| (i as f64 * (151.0 / 75.0)) as usize)
        .collect();
    assert!(!sampled.contains(&75), "index 75 is skipped");

    for m in run(&dump, "finalize-caps-at-75-and-repoints-the-cover") {
        assert_eq!(m.photo_count, 75);
        let expected: Vec<&str> = sampled.iter().map(|i| input_ids[*i]).collect();
        assert_eq!(m.photo_ids, expected, "{}: sampling rule", m.id);
        assert_eq!(m.cover_photo_id, m.photo_ids[37]);
        assert!(m.subtitle.as_deref().unwrap().ends_with("75 photos"));
    }
}

/// Landmine 12: undated photos are invisible to every generator except
/// birthdays, where they sort to the FRONT and the cover is `ids.last`.
#[test]
fn undated_photos_reach_birthdays_and_nothing_else() {
    let dump = dump();
    let scenario = scenario_named(&dump, "birthday-today-with-an-undated-photo");
    let undated: Vec<&str> = scenario
        .inputs
        .photos
        .iter()
        .filter(|p| p.date_taken.is_none())
        .map(|p| p.id.as_str())
        .collect();
    assert_eq!(undated.len(), 1);

    let out = run(&dump, "birthday-today-with-an-undated-photo");
    let birthday = &out[0];
    assert_eq!(birthday.kind, "birthday");
    assert_eq!(birthday.score, 100.0);
    assert_eq!(
        birthday.photo_ids[0], undated[0],
        "undated sorts to the front"
    );
    assert_eq!(
        &birthday.cover_photo_id,
        birthday.photo_ids.last().unwrap(),
        "the cover is ids.last — the most recent dated photo"
    );
    assert!(
        birthday.date_range_start.is_some(),
        "one undated photo must not collapse the range"
    );
    for other in &out[1..] {
        assert!(!other.photo_ids.iter().any(|id| id == undated[0]));
    }
}

/// Landmine 13: hidden first, then `.disabled`, then `.manual` over the name
/// auto-match — and the title still uses the **tag's** display name, not the
/// linked contact's.
#[test]
fn birthday_link_resolution_follows_the_pinned_order() {
    let out = run(&dump(), "birthday-links-manual-disabled-hidden");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].id, "birthday-People/Dave");
    assert_eq!(out[0].title, "Happy birthday, Dave");
    assert_eq!(out[0].person_name.as_deref(), Some("Dave"));
}

/// Landmine 14: the milestones are exactly `[1, 2, 3, 5, 10, 15, 20]`, and
/// `onThisDay`'s score counts distinct years rather than photos.
#[test]
fn the_score_ladder_holds() {
    let dump = dump();

    let out = run(&dump, "on-this-day-and-years-ago-overlap");
    assert_eq!(out[0].score, 55.0, "50 + 5 per distinct year (1)");
    assert_eq!(out[1].score, 40.0, "yearsAgo 5..9");

    let out = run(&dump, "years-ago-milestone-ladder");
    assert_eq!(out[0].score, 70.0, "50 + 5 × 4 distinct years");
    assert!(
        !out.iter().any(|m| m.id.contains("yearsAgo-6")),
        "6 years is not a milestone"
    );

    let out = run(&dump, "photo-density-single-busy-day");
    assert_eq!(out[0].id, "density-2022-3-5", "no zero padding");
    assert_eq!(out[0].score, 8.0);

    let out = run(&dump, "folder-events");
    assert!(out.iter().all(|m| (10.0..=24.0).contains(&m.score)));
}

/// The 10-memory cutoff, with the tail decided purely by the jitter — the case
/// that fails if `SeededRng` is off by one bit.
#[test]
fn the_greedy_cutoff_takes_exactly_ten() {
    let out = run(&dump(), "ten-memory-greedy-cutoff");
    assert_eq!(out.len(), 10);
    assert_eq!(
        out.iter().filter(|m| m.kind == "folderEvent").count(),
        8,
        "12 candidates, 8 seats left after the top 2"
    );
}

/// An empty library produces nothing at all: no crash, no placeholder. The
/// once-per-day gate that would normally skip this lives in `MemoryCoordinator`
/// and stays in Swift.
#[test]
fn an_empty_library_produces_nothing() {
    assert!(run(&dump(), "empty-library").is_empty());
}
