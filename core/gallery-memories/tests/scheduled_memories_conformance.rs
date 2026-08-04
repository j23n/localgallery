//! `scheduled_memories.json`, run against `gallery_memories::compute_scheduled`.
//!
//! Four scenarios × a 7-day horizon, plus the day-N parity check the widget
//! deep links depend on: the id pre-published for day N must be the id the live
//! pipeline produces on day N, with identical content.
//!
//! In UTC that holds and is asserted. In `Asia/Tokyo` it does **not**, and the
//! fixture pins the failure — the horizon walks local midnights while the id is
//! rendered in GMT. See `scheduled::compute_scheduled`'s docs and landmine 3.

#[path = "support/fixture.rs"]
mod fixture;

use std::collections::{HashMap, HashSet};

use fixture::*;
use gallery_memories::{compute_scheduled, generate, GenerationInputs, LocalCalendar};
use gallery_model::AppleDate;
use serde::Deserialize;

const HORIZON_DAYS: i64 = 7;

#[derive(Deserialize)]
struct ScheduledDump {
    schema: u32,
    scenarios: Vec<Scenario>,
}

#[derive(Deserialize)]
struct Scenario {
    name: String,
    notes: Vec<String>,
    #[serde(rename = "timeZone")]
    time_zone: String,
    today: String,
    #[serde(rename = "horizonDays")]
    horizon_days: i64,
    photos: Vec<ConfPhoto>,
    contacts: Vec<ConfContact>,
    #[serde(rename = "personContactLinks")]
    person_contact_links: Vec<ConfLink>,
    #[serde(rename = "birthdaysEnabled")]
    birthdays_enabled: bool,
    scheduled: Vec<Item>,
    parity: Vec<ParityDay>,
}

#[derive(Deserialize, PartialEq, Debug)]
struct Item {
    #[serde(rename = "dayOffset")]
    day_offset: i64,
    #[serde(rename = "validFrom")]
    valid_from: String,
    #[serde(rename = "validTo")]
    valid_to: String,
    memory: ConfMemory,
}

#[derive(Deserialize, PartialEq, Debug)]
struct ParityDay {
    #[serde(rename = "dayOffset")]
    day_offset: i64,
    #[serde(rename = "scheduledIDs")]
    scheduled_ids: Vec<String>,
    #[serde(rename = "liveGeneratedIDs")]
    live_generated_ids: Vec<String>,
    #[serde(rename = "matchedIDs")]
    matched_ids: Vec<String>,
    #[serde(rename = "contentIdenticalForMatchedIDs")]
    content_identical: bool,
    #[serde(rename = "scheduledButNotGeneratedLive")]
    scheduled_but_not_generated_live: Vec<String>,
}

impl Scenario {
    /// The snapshot both halves run over. `seed` is filled in per parity day;
    /// the scheduled pass never reads it.
    fn to_inputs(&self, now: &str, seed: &str) -> GenerationInputs {
        inputs_from(
            &self.photos,
            &[],
            &self.contacts,
            &self.person_contact_links,
            self.birthdays_enabled,
            "",
            &[],
            now,
            &self.time_zone,
            seed,
        )
    }

    fn observed_items(&self) -> Vec<Item> {
        let inputs = self.to_inputs(&self.today, "");
        let cal = inputs.calendar();
        let start_of_today = cal.start_of_day(inputs.now);
        compute_scheduled(&inputs, HORIZON_DAYS, &HashSet::new())
            .into_iter()
            .map(|s| Item {
                day_offset: cal.day_difference(start_of_today, s.valid_from),
                valid_from: s.valid_from.to_utc_string(),
                valid_to: s.valid_to.to_utc_string(),
                memory: ConfMemory::of(&s.memory),
            })
            .collect()
    }

    /// `WidgetDayKey.string(for:)` — the LOCAL calendar day, zero-padded. The
    /// same instant seeds differently in different zones (landmine 4).
    fn day_key(cal: &LocalCalendar, day: AppleDate) -> String {
        let c = cal.civil(day);
        format!("{:04}-{:02}-{:02}", c.year, c.month, c.day)
    }

    fn observed_parity(&self, items: &[Item]) -> Vec<ParityDay> {
        let base = self.to_inputs(&self.today, "");
        let cal = base.calendar();
        let start_of_today = cal.start_of_day(base.now);

        (1..=HORIZON_DAYS)
            .map(|offset| {
                let day = cal.adding_days(start_of_today, offset);
                let noon = AppleDate(day.0 + 12.0 * 3600.0);
                let mut live_inputs = self.to_inputs(&self.today, &Self::day_key(&cal, day));
                live_inputs.now = noon;
                let live = generate(&live_inputs);
                let live_by_id: HashMap<String, ConfMemory> = live
                    .iter()
                    .map(|m| (m.id.clone(), ConfMemory::of(m)))
                    .collect();

                let for_day: Vec<&Item> = items.iter().filter(|i| i.day_offset == offset).collect();
                let matched: Vec<&&Item> = for_day
                    .iter()
                    .filter(|i| live_by_id.contains_key(&i.memory.id))
                    .collect();
                ParityDay {
                    day_offset: offset,
                    scheduled_ids: for_day.iter().map(|i| i.memory.id.clone()).collect(),
                    live_generated_ids: live.iter().map(|m| m.id.clone()).collect(),
                    matched_ids: matched.iter().map(|i| i.memory.id.clone()).collect(),
                    content_identical: matched.iter().all(|i| live_by_id[&i.memory.id] == i.memory),
                    scheduled_but_not_generated_live: for_day
                        .iter()
                        .filter(|i| !live_by_id.contains_key(&i.memory.id))
                        .map(|i| i.memory.id.clone())
                        .collect(),
                }
            })
            .collect()
    }
}

fn dump() -> ScheduledDump {
    read_fixture("scheduled_memories.json")
}

/// The suite: every pre-published item, its validity window and its day offset.
#[test]
fn every_scenario_reproduces_its_horizon() {
    let dump = dump();
    assert_eq!(dump.schema, 1);
    assert!(dump.scenarios.len() >= 4);

    for scenario in &dump.scenarios {
        assert!(
            !scenario.notes.is_empty(),
            "{} lost its notes",
            scenario.name
        );
        assert_eq!(scenario.horizon_days, HORIZON_DAYS);
        assert_eq!(
            scenario.observed_items(),
            scenario.scheduled,
            "scenario `{}` horizon diverged",
            scenario.name
        );
    }
}

/// The parity block, recomputed the way the Swift harness computes it: the live
/// pipeline run at noon of each horizon day with that day's widget seed.
#[test]
fn every_scenario_reproduces_its_parity_block() {
    for scenario in &dump().scenarios {
        let items = scenario.observed_items();
        assert_eq!(
            scenario.observed_parity(&items),
            scenario.parity,
            "scenario `{}` parity diverged",
            scenario.name
        );
    }
}

/// The plan's acceptance criterion, asserted where it holds.
#[test]
fn utc_pre_published_ids_match_the_live_run_on_their_day() {
    let dump = dump();
    for scenario in dump.scenarios.iter().filter(|s| s.time_zone == "UTC") {
        let items = scenario.observed_items();
        let parity = scenario.observed_parity(&items);
        for day in &parity {
            assert!(
                day.content_identical,
                "{} +{}: a pre-published memory differs from the live one",
                scenario.name, day.day_offset
            );
            assert!(
                day.scheduled_but_not_generated_live.is_empty(),
                "{} +{}: pre-published ids the live run never produces: {:?}",
                scenario.name,
                day.day_offset,
                day.scheduled_but_not_generated_live
            );
        }
        assert!(
            parity.iter().any(|d| !d.scheduled_ids.is_empty()),
            "{} pre-published nothing at all",
            scenario.name
        );
    }
}

/// …and the pinned bug where it does not. A port that "fixes" the GMT id
/// rendering changes which widget deep links resolve, so the drift is asserted
/// rather than merely tolerated.
#[test]
fn the_tokyo_horizon_still_drifts_by_a_day() {
    let dump = dump();
    let tokyo = dump
        .scenarios
        .iter()
        .find(|s| s.time_zone == "Asia/Tokyo")
        .expect("the non-UTC scenario is part of the spec");
    let items = tokyo.observed_items();
    let parity = tokyo.observed_parity(&items);

    let drifted: Vec<&ParityDay> = parity
        .iter()
        .filter(|p| !p.scheduled_but_not_generated_live.is_empty())
        .collect();
    assert!(
        !drifted.is_empty(),
        "the Tokyo id drift disappeared — if that was deliberate, this test, \
         the fixture and the README section it points at all need rewriting"
    );
    for day in &drifted {
        assert!(
            day.matched_ids.is_empty(),
            "+{}: the drift is total for calendar-tied items",
            day.day_offset
        );
    }
    // Birthday ids are not date-qualified, so they survive it.
    assert!(
        parity
            .iter()
            .any(|p| p.matched_ids.iter().any(|id| id.starts_with("birthday-"))),
        "birthday ids carry no date and must still match across the drift"
    );
    // The sharpest form: day +4 pre-publishes the very id day +3 generates
    // live, with different photos behind it.
    let scheduled_plus_4: Vec<&str> = items
        .iter()
        .filter(|i| i.day_offset == 4)
        .map(|i| i.memory.id.as_str())
        .collect();
    assert!(scheduled_plus_4.contains(&"onThisDay-2024-06-11"));
    assert!(parity[2]
        .live_generated_ids
        .iter()
        .any(|id| id == "onThisDay-2024-06-11"));
}

/// Only calendar-tied types are pre-published, day 0 never is, and every item
/// went through the same `finalize` as the daily pipeline.
#[test]
fn the_horizon_shape_holds() {
    for scenario in &dump().scenarios {
        for item in scenario.observed_items() {
            assert!(
                (1..=HORIZON_DAYS).contains(&item.day_offset),
                "{}: day 0 must not be pre-published",
                scenario.name
            );
            assert!(item.valid_from < item.valid_to);
            assert!(
                ["onThisDay", "yearsAgo", "birthday"].contains(&item.memory.kind.as_str()),
                "{}: only calendar-tied types are pre-published, got {}",
                scenario.name,
                item.memory.kind
            );
            assert!(
                item.memory.subtitle.is_some(),
                "the same finalize runs here"
            );
            assert!(item.memory.photo_count <= 75);
            if !scenario.birthdays_enabled {
                assert_ne!(item.memory.kind, "birthday");
            }
        }
    }
}

/// `hiddenMemories` filtering: no fixture scenario exercises it (hiding from a
/// test store fires the widget exporter), so the port tests it directly.
#[test]
fn hidden_memories_are_dropped_from_the_horizon() {
    let dump = dump();
    let scenario = &dump.scenarios[0];
    let inputs = scenario.to_inputs(&scenario.today, "");
    let all = compute_scheduled(&inputs, HORIZON_DAYS, &HashSet::new());
    let hide: HashSet<String> = [all[0].memory.id.clone()].into_iter().collect();
    let filtered = compute_scheduled(&inputs, HORIZON_DAYS, &hide);
    assert_eq!(filtered.len(), all.len() - 1);
    assert!(!filtered.iter().any(|s| hide.contains(&s.memory.id)));
}
