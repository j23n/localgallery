//! `GalleryStore.computeScheduledMemories` — the widget's pre-published
//! horizon.
//!
//! Only calendar-tied types are pre-published (onThisDay, yearsAgo, birthdays);
//! no trips, folder events or density. Day 0 is excluded because it is already
//! on the rail. Each item runs through the same [`crate::finalize`] as the daily
//! pipeline, which is what makes a pre-published item identical to the one the
//! foreground catch-up regenerates on its day.
//!
//! # The pinned timezone bug
//!
//! **This function reproduces a real bug in the shipping app on purpose.**
//!
//! The horizon walks days from `Calendar.current.startOfDay(for: now)` — *local*
//! midnight — while a memory id's date is rendered by an `ISO8601DateFormatter`
//! pinned to GMT. In any zone ahead of GMT, local midnight belongs to the
//! previous GMT day, so the id pre-published for day N names day N−1 and the
//! widget deep link does not resolve. `scheduled_memories.json`'s
//! `asia-tokyo-horizon` scenario records it: three of seven days have an empty
//! `matchedIDs`, and day +4's pre-published `onThisDay-2024-06-11` is the *same
//! id with different photos* as day +3's live one. Birthday ids carry no date
//! and are immune.
//!
//! Fixing it changes which widget deep links resolve and belongs in its own
//! change — see landmine 3 in the fixture README. Do not "clean this up".

use std::collections::{HashMap, HashSet};

use gallery_model::AppleDate;

use crate::birthdays::{generate_birthday_memories, PeopleIndex};
use crate::calendar::{generate_on_this_day, generate_years_ago};
use crate::time::MonthDay;
use crate::{finalize, photos_with_dates, DatedPhoto, GenerationInputs, Memory};

/// How far ahead calendar-tied memories are pre-published. Seven days covers a
/// weekly-launch cadence without bloating widget thumbnail storage.
pub const SCHEDULED_MEMORY_HORIZON_DAYS: i64 = 7;

/// A memory pre-published for a future day, with the window it is valid in.
#[derive(Debug, Clone, PartialEq)]
pub struct ScheduledMemory {
    pub memory: Memory,
    /// Local midnight of the day it is about.
    pub valid_from: AppleDate,
    /// Local midnight of the following day.
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
    let cal = inputs.calendar();
    let today = cal.start_of_day(inputs.now);

    // Photos bucketed by (month, day) once, so each horizon day's calendar
    // filter walks a small candidate set instead of the whole library.
    let mut by_month_day: HashMap<MonthDay, Vec<DatedPhoto>> = HashMap::new();
    for entry in photos_with_dates(&inputs.photos) {
        by_month_day
            .entry(cal.month_day(entry.1))
            .or_default()
            .push(entry);
    }
    // Finding 3(c): the person → photos grouping is day-independent, so it is
    // built once here rather than seven times inside the loop.
    let people = if inputs.birthdays_enabled {
        PeopleIndex::build(&inputs.photos)
    } else {
        PeopleIndex::default()
    };

    let mut out = Vec::new();
    for offset in 1..=horizon_days {
        let day = cal.adding_days(today, offset);
        let next_day = cal.adding_days(day, 1);
        let day_md = cal.month_day(day);
        let bucket = by_month_day.get(&day_md).map_or(&[][..], Vec::as_slice);

        let mut day_memories: Vec<Memory> = Vec::new();
        if let Some(m) = generate_on_this_day(&cal, &inputs.photos, day, bucket, 10) {
            day_memories.push(m);
        }
        day_memories.extend(generate_years_ago(&cal, &inputs.photos, day, bucket, 10));
        if inputs.birthdays_enabled {
            // Birthdays walk every photo by People/* tag rather than by date
            // bucket, so they are the one scheduled item whose cost is
            // proportional to the whole library — and the reason the
            // no-birthday early-exit inside `generate_birthday_memories` is
            // worth having.
            day_memories.extend(generate_birthday_memories(
                inputs,
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
                valid_from: day,
                valid_to: next_day,
            });
        }
    }
    out
}
