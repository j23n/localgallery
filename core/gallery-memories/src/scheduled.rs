//! `GalleryStore.computeScheduledMemories` — the widget's pre-published
//! horizon.
//!
//! Only calendar-tied types are pre-published (onThisDay, yearsAgo, birthdays);
//! no trips, folder events or density. Day 0 is excluded because it is already
//! on the rail. Each item runs through the same [`crate::finalize`] as the daily
//! pipeline, which is what makes a pre-published item identical to the one the
//! foreground catch-up regenerates on its day.
//!
//! # The zone a pre-published id is rendered in
//!
//! This is the second caller of the calendar generators, and it used to be the
//! one that broke them. It walked days from `Calendar.current.startOfDay(for:
//! now)` — *local* midnight — while a memory id's date was rendered by an
//! `ISO8601DateFormatter` pinned to GMT, so in any zone ahead of GMT the id
//! pre-published for day N named day N−1 and the widget deep link did not
//! resolve. Landmine 3 in the fixture README describes the old behaviour and
//! `scheduled_memories.json`'s `asia-tokyo-horizon` scenario, which recorded
//! three of seven days with an empty `matchedIDs`, is now the regression test
//! for the fix (`_plans/10-widget-timezone-fix.md`).
//!
//! Two things keep it fixed:
//!
//! 1. The horizon steps **civil days** ([`crate::time::YearMonthDay`]), and the
//!    instant the generators read a day off is derived back from those fields
//!    in the run's own calendar — so `iso_day` returns the day the loop is on
//!    by construction, and so does `cal.ymd(now)` on the day it arrives.
//! 2. The **validity window** is derived under that day's own offset
//!    ([`crate::time::Zone::at_horizon_day`]), because a seven-day horizon can
//!    straddle a DST transition and a window is compared against the wall
//!    clock. The two are deliberately not the same calendar: one has to name a
//!    day, the other has to open at the right moment.
//!
//! Birthday ids carry no date and were immune to all of it.

use std::collections::{HashMap, HashSet};

use gallery_model::AppleDate;

use crate::birthdays::{generate_birthday_memories, PeopleIndex};
use crate::calendar::{generate_on_this_day, generate_years_ago};
use crate::time::MonthDay;
use crate::{finalize, photos_with_dates, DatedPhoto, GenerationInputs, Memory, PersonKeys};

/// How far ahead calendar-tied memories are pre-published. Seven days covers a
/// weekly-launch cadence without bloating widget thumbnail storage.
pub const SCHEDULED_MEMORY_HORIZON_DAYS: i64 = 7;

/// A memory pre-published for a future day, with the window it is valid in.
#[derive(Debug, Clone, PartialEq)]
pub struct ScheduledMemory {
    pub memory: Memory,
    /// Local midnight of the day it is about, in the offset in force **on that
    /// day** rather than on the day the horizon was computed.
    pub valid_from: AppleDate,
    /// Local midnight of the following day, in that day's own offset — so a
    /// day's `valid_to` is the next day's `valid_from` even across a
    /// transition, and the horizon has no gaps or overlaps.
    pub valid_to: AppleDate,
}

/// Pre-compute `horizon_days` days of calendar-tied memories.
///
/// `hidden_memories` is `MemoryCoordinator.hiddenMemories`; it stays in Swift
/// and arrives here as a plain set.
///
/// Reads only the calendar-relevant half of [`GenerationInputs`]: `seed`,
/// `leaf_folders`, `seen_memory_ids` and `surfaced_clusters` play no part —
/// nothing here is scored or selected.
pub fn compute_scheduled(
    inputs: &GenerationInputs,
    horizon_days: i64,
    hidden_memories: &HashSet<String>,
) -> Vec<ScheduledMemory> {
    let zone = inputs.zone();
    let cal = zone.now();
    let today = cal.ymd(inputs.now);

    // Photos bucketed by (month, day) once, so each horizon day's calendar
    // filter walks a small candidate set instead of the whole library. Bucketed
    // by each photo's OWN offset, which is what `generate_on_this_day` then
    // re-filters by — the two must agree or the bucket hides its own members.
    let mut by_month_day: HashMap<MonthDay, Vec<DatedPhoto>> = HashMap::new();
    for entry in photos_with_dates(inputs.ladder_photos()) {
        by_month_day
            .entry(zone.at(entry.0).month_day(entry.1))
            .or_default()
            .push(entry);
    }
    // Finding 3(c): the person → photos grouping and the folded person keys are
    // both day-independent, so they are built once here rather than seven times
    // inside the loop.
    let people = if inputs.birthdays_enabled {
        PeopleIndex::build(inputs.ladder_photos())
    } else {
        PeopleIndex::default()
    };
    let keys = PersonKeys::build(inputs);

    let mut out = Vec::new();
    for offset in 1..=horizon_days {
        let ymd = today.adding_days(offset);
        let day_md = MonthDay {
            month: ymd.month,
            day: ymd.day,
        };
        // What the generators read the day off. The run's own calendar, so that
        // `cal.ymd` of it is `ymd` exactly and the id matches the one the live
        // run renders from its `now` on that day. The window below is the other
        // calendar — see the module docs.
        let day = cal.instant_at_midnight(ymd);
        let valid_from = zone.at_horizon_day(offset).instant_at_midnight(ymd);
        let valid_to = zone
            .at_horizon_day(offset + 1)
            .instant_at_midnight(ymd.adding_days(1));
        let bucket = by_month_day.get(&day_md).map_or(&[][..], Vec::as_slice);

        let mut day_memories: Vec<Memory> = Vec::new();
        if let Some(m) = generate_on_this_day(&zone, &inputs.photos, day, bucket, 10) {
            day_memories.push(m);
        }
        day_memories.extend(generate_years_ago(&zone, &inputs.photos, day, bucket, 10));
        if inputs.birthdays_enabled {
            // Birthdays walk every photo by People/* tag rather than by date
            // bucket, so they are the one scheduled item whose cost is
            // proportional to the whole library — and the reason the
            // no-birthday early-exit inside `generate_birthday_memories` is
            // worth having.
            day_memories.extend(generate_birthday_memories(
                inputs,
                &keys,
                &people,
                day_md.month,
                day_md.day,
            ));
        }

        for memory in finalize(&cal, day_memories) {
            if hidden_memories.contains(&memory.id) {
                continue;
            }
            out.push(ScheduledMemory {
                memory,
                valid_from,
                valid_to,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::UtcOffset;
    use crate::{generate, MemoryType};
    use gallery_model::{CivilDateTime, PhotoFile};

    fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(y, mo, d, h, mi, 0).as_naive_unix_secs() as f64
        )
    }

    /// Twelve photos three minutes apart from `start` — past the 60 s dedup
    /// window and over the calendar generators' 10-photo floor.
    fn day_of_photos(prefix: &str, start: AppleDate) -> Vec<PhotoFile> {
        (0..12)
            .map(|i| {
                let mut p = PhotoFile::new(
                    &format!("/lib/{prefix}-{i:02}.jpg"),
                    format!("{prefix}-{i:02}"),
                    1,
                );
                p.date_taken = Some(AppleDate(start.0 + i as f64 * 180.0));
                p
            })
            .collect()
    }

    fn inputs(now: AppleDate, offset: i32, photos: Vec<PhotoFile>) -> GenerationInputs {
        GenerationInputs::empty(now, UtcOffset(offset), "seed").with_photos(photos)
    }

    fn ids_for_day(items: &[ScheduledMemory], from: AppleDate) -> Vec<&str> {
        items
            .iter()
            .filter(|s| s.valid_from == from)
            .map(|s| s.memory.id.as_str())
            .collect()
    }

    /// The exit criterion of `_plans/10`, hand-computed in the zone that showed
    /// the bug. `now` is 2024-06-08T03:00Z — 12:00 JST — and the library sits on
    /// 2019-06-11T12:00Z, which is 21:00 JST on the 11th. Day +3 is therefore
    /// Tokyo's June 11, and the pre-published id says so.
    ///
    /// It used to say `onThisDay-2024-06-10`: the horizon passed local midnight
    /// (15:00Z on the 10th) to an id formatter pinned to GMT. The live run on
    /// that day produced `onThisDay-2024-06-11`, so the deep link resolved to
    /// nothing — landmine 3.
    #[test]
    fn a_tokyo_horizon_pre_publishes_the_id_the_live_run_will_produce() {
        let jst = 9 * 3600;
        let photos = day_of_photos("jst", utc(2019, 6, 11, 12, 0));
        let scheduled = compute_scheduled(
            &inputs(utc(2024, 6, 8, 3, 0), jst, photos.clone()),
            SCHEDULED_MEMORY_HORIZON_DAYS,
            &HashSet::new(),
        );

        // Local midnight of 2024-06-11 in Tokyo is 2024-06-10T15:00Z.
        let day_three = utc(2024, 6, 10, 15, 0);
        assert_eq!(
            ids_for_day(&scheduled, day_three),
            vec!["onThisDay-2024-06-11", "yearsAgo-5-2024-06-11"]
        );
        assert_eq!(
            scheduled
                .iter()
                .find(|s| s.valid_from == day_three)
                .map(|s| s.valid_to),
            Some(utc(2024, 6, 11, 15, 0))
        );

        // …and the run on the day it arrives, from any hour of it, agrees.
        for hour in [15, 20, 3, 14] {
            let now = if hour >= 15 {
                utc(2024, 6, 10, hour, 30) // evening JST on the 11th
            } else {
                utc(2024, 6, 11, hour, 30) // morning and afternoon JST
            };
            let live: Vec<String> = generate(&inputs(now, jst, photos.clone()))
                .into_iter()
                .map(|m| m.id)
                .collect();
            assert!(
                live.contains(&"onThisDay-2024-06-11".to_string()),
                "live ids at {now:?} were {live:?}"
            );
        }
    }

    /// The mirrored failure, behind GMT: the *live* id used to roll forward
    /// once local time passed 24−h, so Los Angeles produced
    /// `onThisDay-2024-06-12` for a memory about June 11 from 17:00 onwards
    /// while the horizon kept pre-publishing June 11. Evening usage only, which
    /// is why the fixture's morning `now` never saw it.
    #[test]
    fn an_evening_in_los_angeles_names_the_day_it_is_still_on() {
        let pdt = -7 * 3600;
        let photos = day_of_photos("pdt", utc(2019, 6, 11, 20, 0));
        // 2024-06-12T01:00Z is 18:00 PDT on the 11th.
        let live: Vec<String> = generate(&inputs(utc(2024, 6, 12, 1, 0), pdt, photos.clone()))
            .into_iter()
            .map(|m| m.id)
            .collect();
        assert!(
            live.contains(&"onThisDay-2024-06-11".to_string()),
            "{live:?}"
        );

        // The horizon three days earlier pre-published the same string.
        let scheduled = compute_scheduled(
            &inputs(utc(2024, 6, 9, 1, 0), pdt, photos),
            SCHEDULED_MEMORY_HORIZON_DAYS,
            &HashSet::new(),
        );
        assert!(scheduled
            .iter()
            .any(|s| s.memory.id == "onThisDay-2024-06-11"));
    }

    /// Berlin, with the horizon straddling the October fallback: `now` is
    /// 2024-10-24 12:00 CEST and the clocks go back at 03:00 CEST on the 27th,
    /// so the platform resolves +2 for days 0–2 and +1 from day 3 on.
    ///
    /// The windows have to follow it. A single `now` offset would open every
    /// window from the 27th an hour early and keep doing it for the rest of the
    /// horizon; with the per-day table only the transition day itself is off,
    /// and by the hour the module docs account for (the offset is sampled at
    /// local noon, which on the 27th is already CET).
    #[test]
    fn a_berlin_horizon_follows_the_offset_across_the_fallback() {
        let cest = 2 * 3600;
        let cet = 3600;
        let mut photos = day_of_photos("oct26", utc(2019, 10, 26, 10, 0));
        photos.extend(day_of_photos("oct27", utc(2019, 10, 27, 10, 0)));
        let per_photo = vec![cest; photos.len()];
        let horizon = vec![cest, cest, cest, cet, cet, cet, cet, cet, cet];

        let scheduled = compute_scheduled(
            &GenerationInputs {
                photo_time_zone_offsets: per_photo,
                horizon_time_zone_offsets: horizon,
                ..inputs(utc(2024, 10, 24, 10, 0), cest, photos)
            },
            SCHEDULED_MEMORY_HORIZON_DAYS,
            &HashSet::new(),
        );

        // Day +2 is 2024-10-26: midnight CEST, so 2024-10-25T22:00Z.
        let oct26 = utc(2024, 10, 25, 22, 0);
        // Day +3 is 2024-10-27, sampled at noon and therefore CET:
        // 2024-10-26T23:00Z. One hour after true local midnight, and the same
        // instant as the 26th's `valid_to` — the windows stay contiguous.
        let oct27 = utc(2024, 10, 26, 23, 0);
        assert_eq!(
            ids_for_day(&scheduled, oct26),
            vec!["onThisDay-2024-10-26", "yearsAgo-5-2024-10-26"]
        );
        assert_eq!(
            ids_for_day(&scheduled, oct27),
            vec!["onThisDay-2024-10-27", "yearsAgo-5-2024-10-27"]
        );
        let twenty_sixth = scheduled
            .iter()
            .find(|s| s.valid_from == oct26)
            .expect("the 26th");
        assert_eq!(twenty_sixth.valid_to, oct27);
        assert_eq!(
            scheduled
                .iter()
                .find(|s| s.valid_from == oct27)
                .map(|s| s.valid_to),
            Some(utc(2024, 10, 27, 23, 0))
        );
    }

    /// An offset that is not a whole number of hours, because every piece of
    /// this arithmetic is in seconds and nothing else proves it. Kathmandu is
    /// +5:45; `now` is 2024-06-08T18:30Z, which is 00:15 on the 9th there — so
    /// "today" is already the 9th and day +2 is the 11th.
    #[test]
    fn a_forty_five_minute_offset_lands_on_the_right_day() {
        let npt = 5 * 3600 + 45 * 60;
        let photos = day_of_photos("npt", utc(2019, 6, 10, 20, 0)); // 2019-06-11 01:45 NPT
        let scheduled = compute_scheduled(
            &inputs(utc(2024, 6, 8, 18, 30), npt, photos),
            SCHEDULED_MEMORY_HORIZON_DAYS,
            &HashSet::new(),
        );
        // Local midnight of 2024-06-11 in Kathmandu is 2024-06-10T18:15Z.
        assert_eq!(
            ids_for_day(&scheduled, utc(2024, 6, 10, 18, 15)),
            vec!["onThisDay-2024-06-11", "yearsAgo-5-2024-06-11"]
        );
    }

    /// Day 0 is never pre-published — it is already on the rail — and the
    /// horizon covers exactly the days after it.
    #[test]
    fn the_horizon_skips_today_and_stops_at_seven_days() {
        let photos = day_of_photos("utc", utc(2019, 6, 11, 12, 0));
        let scheduled = compute_scheduled(
            &inputs(utc(2024, 6, 8, 12, 0), 0, photos),
            SCHEDULED_MEMORY_HORIZON_DAYS,
            &HashSet::new(),
        );
        assert!(scheduled
            .iter()
            .all(|s| s.valid_from >= utc(2024, 6, 9, 0, 0)));
        assert!(scheduled
            .iter()
            .all(|s| s.valid_to <= utc(2024, 6, 16, 0, 0)));
        assert!(scheduled
            .iter()
            .all(|s| s.memory.kind != MemoryType::PhotoDensity));
    }
}
