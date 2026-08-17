//! `scheduled_memories.json`, run against `gallery_memories::compute_scheduled`.
//!
//! Seven scenarios × a 7-day horizon, plus the day-N parity check the widget
//! deep links depend on: the id pre-published for day N must be the id the live
//! pipeline produces on day N, with identical content.
//!
//! The live half of that check runs at the scenario's **own wall-clock time**,
//! not at noon. Noon is the one hour of the day at which both halves of the old
//! bug cancel out in every zone, so a fixture that only ever looked there could
//! not see the mirrored evening failure behind GMT
//! (`america-los-angeles-evening-horizon`). Every scenario that predates that
//! one is set at local noon, so their parity blocks are unchanged by it.
//!
//! It holds in every scenario since `_plans/10-widget-timezone-fix.md`. It used
//! not to: the horizon walked local midnights while the id was rendered in GMT,
//! so `asia-tokyo-horizon` recorded three of seven days with an empty
//! `matchedIDs`. That scenario is now the regression test for the fix, and
//! landmines 2 and 3 in the fixture README describe what it used to record.
//!
//! **Schema 2** carries the resolved offsets — `timeZoneOffsetSeconds` and the
//! per-horizon-day `horizonOffsetSeconds` — beside the IANA `timeZone` name.
//! This crate has no tz database, so a scenario whose offset changes *inside*
//! the horizon (`europe-berlin-dst-fallback-horizon`) is only reproducible from
//! the numbers Foundation resolved. The name stays as provenance: it is what
//! makes the numbers legible.

#[path = "support/fixture.rs"]
mod fixture;

use std::collections::{HashMap, HashSet};

use fixture::*;
use gallery_memories::{compute_scheduled, generate, GenerationInputs, LocalCalendar, UtcOffset};
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
    /// Provenance for the two offset fields below, and the zone the Swift
    /// harness moved the process to.
    #[serde(rename = "timeZone")]
    time_zone: String,
    #[serde(rename = "timeZoneOffsetSeconds")]
    time_zone_offset_seconds: i32,
    /// One per day from today, sampled at that day's local noon.
    #[serde(rename = "horizonOffsetSeconds")]
    horizon_offset_seconds: Vec<i32>,
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
        let mut inputs = inputs_from(
            &self.photos,
            &[],
            &self.contacts,
            &self.person_contact_links,
            self.birthdays_enabled,
            "",
            &[],
            now,
            UtcOffset(self.time_zone_offset_seconds),
            seed,
        );
        inputs.horizon_time_zone_offsets = self.horizon_offset_seconds.clone();
        inputs
    }

    fn observed_items(&self) -> Vec<Item> {
        let inputs = self.to_inputs(&self.today, "");
        let cal = inputs.calendar();
        let start_of_today = cal.start_of_day(inputs.now);
        compute_scheduled(&inputs, HORIZON_DAYS, &HashSet::new())
            .into_iter()
            .map(|s| Item {
                // Rounded, not floored: a window opens at ITS day's offset, so
                // across a transition it sits an hour either side of a whole
                // number of days from today's midnight. Flooring reports the
                // previous day when the clocks go forward.
                day_offset: ((s.valid_from.0 - start_of_today.0) / 86_400.0).round() as i64,
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

        // The scenario's own time of day, carried onto each horizon day — see
        // the module docs for why noon would hide half the bug this fixture is
        // the regression test for.
        let seconds_into_day = base.now.0 - start_of_today.0;

        (1..=HORIZON_DAYS)
            .map(|offset| {
                let day = cal.adding_days(start_of_today, offset);
                let same_hour = AppleDate(day.0 + seconds_into_day);
                let mut live_inputs = self.to_inputs(&self.today, &Self::day_key(&cal, day));
                live_inputs.now = same_hour;
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
    assert_eq!(dump.schema, 2, "schema 2 carries the resolved offsets");
    assert!(dump.scenarios.len() >= 7);

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

/// The acceptance criterion, asserted in **every** zone since `_plans/10`.
/// Before it, this held in UTC alone and the filter here said so.
#[test]
fn pre_published_ids_match_the_live_run_on_their_day() {
    let dump = dump();
    for scenario in &dump.scenarios {
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

/// The scenario the fix was written for, asserted in the sharpest form the old
/// behaviour failed: Tokyo pre-published `onThisDay-2024-06-11` on day **+4**
/// while the live run produced it on day **+3** — the same id with different
/// photos behind it. Now the horizon names June 11 on the day June 11 is, every
/// day of it resolves, and no two days share an id.
#[test]
fn the_tokyo_horizon_no_longer_drifts_by_a_day() {
    let dump = dump();
    let tokyo = dump
        .scenarios
        .iter()
        .find(|s| s.time_zone == "Asia/Tokyo")
        .expect("the zone the bug was found in is part of the spec");
    let items = tokyo.observed_items();
    let parity = tokyo.observed_parity(&items);

    for day in &parity {
        assert!(
            day.scheduled_but_not_generated_live.is_empty(),
            "+{}: pre-published ids the live run never produces: {:?}",
            day.day_offset,
            day.scheduled_but_not_generated_live
        );
        assert_eq!(
            day.matched_ids.len(),
            day.scheduled_ids.len(),
            "+{}: every pre-published id must resolve",
            day.day_offset
        );
        assert!(day.content_identical, "+{}", day.day_offset);
    }
    // Day +3 is Tokyo's June 11 and is the only day that can carry that id.
    let day_of = |id: &str| -> Vec<i64> {
        items
            .iter()
            .filter(|i| i.memory.id == id)
            .map(|i| i.day_offset)
            .collect()
    };
    assert_eq!(day_of("onThisDay-2024-06-11"), vec![3]);
    // Birthday ids carry no date and were immune to the drift; they still are.
    assert!(parity
        .iter()
        .any(|p| p.matched_ids.iter().any(|id| id.starts_with("birthday-"))));
}

/// The three zones `_plans/10` added, checked against **hand-computed**
/// windows rather than against whatever the regeneration produced. Each is a
/// symptom the original pair (UTC and Tokyo, both DST-free, both at local noon)
/// could not see.
#[test]
fn the_zone_scenarios_open_their_windows_where_the_arithmetic_says() {
    let dump = dump();
    let named = |name: &str| -> &Scenario {
        dump.scenarios
            .iter()
            .find(|s| s.name == name)
            .unwrap_or_else(|| panic!("no scenario `{name}`"))
    };
    let window = |s: &Scenario, id: &str| -> (i64, String, String) {
        let item = s
            .scheduled
            .iter()
            .find(|i| i.memory.id == id)
            .unwrap_or_else(|| panic!("{}: no `{id}`", s.name));
        (
            item.day_offset,
            item.valid_from.clone(),
            item.valid_to.clone(),
        )
    };

    // Los Angeles, −7, `now` 18:00 local on 2024-06-08 — the hour at which the
    // live id used to roll forward to the 12th while the horizon kept
    // pre-publishing the 11th. Local midnight of the 11th is 07:00Z.
    let la = named("america-los-angeles-evening-horizon");
    assert_eq!(la.time_zone_offset_seconds, -7 * 3600);
    assert_eq!(la.today, "2024-06-09T01:00:00.000Z");
    assert_eq!(
        window(la, "onThisDay-2024-06-11"),
        (
            3,
            "2024-06-11T07:00:00.000Z".into(),
            "2024-06-12T07:00:00.000Z".into()
        )
    );

    // Berlin, with the horizon straddling the October fallback. The offset is
    // sampled at each day's local noon, so it is +1 from the 27th on, and the
    // 26th's `valid_to` is the 27th's `valid_from` — contiguous across the
    // transition rather than an hour short of it.
    let berlin = named("europe-berlin-dst-fallback-horizon");
    assert_eq!(berlin.time_zone_offset_seconds, 2 * 3600);
    assert_eq!(
        berlin.horizon_offset_seconds,
        vec![7200, 7200, 7200, 3600, 3600, 3600, 3600, 3600, 3600],
        "one per day from today, two entries past the horizon so the last \
         window can close"
    );
    assert_eq!(
        window(berlin, "onThisDay-2024-10-26"),
        (
            2,
            "2024-10-25T22:00:00.000Z".into(),
            "2024-10-26T23:00:00.000Z".into()
        )
    );
    assert_eq!(
        window(berlin, "onThisDay-2024-10-27"),
        (
            3,
            "2024-10-26T23:00:00.000Z".into(),
            "2024-10-27T23:00:00.000Z".into()
        )
    );

    // Kathmandu, +5:45. `now` is 00:45 local, so "today" is already the 9th and
    // day +2 is the 11th; local midnight of it is 18:15Z the evening before.
    // Nothing else in this suite proves the arithmetic is in seconds.
    let kathmandu = named("asia-kathmandu-horizon");
    assert_eq!(kathmandu.time_zone_offset_seconds, 5 * 3600 + 45 * 60);
    assert_eq!(
        window(kathmandu, "onThisDay-2024-06-11"),
        (
            2,
            "2024-06-10T18:15:00.000Z".into(),
            "2024-06-11T18:15:00.000Z".into()
        )
    );
}

/// The invariant `asia-tokyo-horizon` should always have had, now cheap enough
/// to demand of every scenario: an id belongs to one horizon day.
#[test]
fn no_two_horizon_days_share_an_id() {
    for scenario in &dump().scenarios {
        let mut seen: HashMap<String, i64> = HashMap::new();
        for item in scenario.observed_items() {
            if let Some(other) = seen.insert(item.memory.id.clone(), item.day_offset) {
                panic!(
                    "{}: `{}` is pre-published for both +{} and +{}",
                    scenario.name, item.memory.id, other, item.day_offset
                );
            }
        }
    }
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
