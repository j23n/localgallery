//! `MemoryEngine+Calendar.swift`: the deterministic per-day generators.
//!
//! Shared by the daily pipeline (for today) and by [`crate::scheduled`], which
//! pre-publishes the next few days into the widget snapshot. Same code, same
//! ids — that is the invariant the widget deep links rest on.

use gallery_model::{AppleDate, PhotoFile};
use std::collections::HashSet;

use crate::time::LocalCalendar;
use crate::{dedup_by_time_window, ids_of, sorted_ascending, DatedPhoto, Memory, MemoryType};

/// The milestones a "years ago" memory is allowed to sit on. **Exactly**
/// these: six years ago produces nothing (landmine 14).
pub const MILESTONES: [i64; 7] = [1, 2, 3, 5, 10, 15, 20];

/// Every entry from `day`'s month/day in a *different* year.
fn same_month_day_other_years(
    cal: &LocalCalendar,
    day: AppleDate,
    dated: &[DatedPhoto],
    year_filter: impl Fn(i32) -> bool,
) -> Vec<DatedPhoto> {
    let target = cal.month_day(day);
    let matched: Vec<DatedPhoto> = dated
        .iter()
        .copied()
        .filter(|(_, date)| {
            let c = cal.civil(*date);
            c.month == target.month && c.day == target.day && year_filter(c.year)
        })
        .collect();
    dedup_by_time_window(&sorted_ascending(matched))
}

/// `generateOnThisDay` — one memory covering every past year that shares
/// `day`'s month and day.
///
/// The id is **date-qualified** (`onThisDay-2024-06-11`): a constant id would
/// let one viewing apply the 6-month seen penalty to every future day's
/// on-this-day memory. The date in it is rendered in **GMT** while the day it
/// selects is local — see [`LocalCalendar::iso_day_gmt`], landmine 2.
pub fn generate_on_this_day(
    cal: &LocalCalendar,
    photos: &[PhotoFile],
    day: AppleDate,
    dated: &[DatedPhoto],
    min_photos: usize,
) -> Option<Memory> {
    let current_year = cal.year(day);
    let deduped = same_month_day_other_years(cal, day, dated, |y| y != current_year);
    if deduped.len() < min_photos {
        return None;
    }
    // The score counts distinct YEARS, not photos.
    let years: HashSet<i32> = deduped.iter().map(|e| cal.year(e.1)).collect();
    let ids = ids_of(photos, &deduped);
    Some(Memory {
        id: format!("onThisDay-{}", LocalCalendar::iso_day_gmt(day)),
        kind: MemoryType::OnThisDay,
        title: "On this day".to_string(),
        subtitle: None,
        cover_photo_id: ids[ids.len() / 2],
        photo_ids: ids,
        date_range: Some((deduped[0].1, deduped[deduped.len() - 1].1)),
        score: 50.0 + years.len() as f64 * 5.0,
        years_ago: None,
        person_name: None,
    })
}

/// `generateYearsAgo` — one memory per milestone year with enough photos, in
/// milestone order. That order is part of the contract: it decides which jitter
/// draw each candidate receives.
pub fn generate_years_ago(
    cal: &LocalCalendar,
    photos: &[PhotoFile],
    day: AppleDate,
    dated: &[DatedPhoto],
    min_photos: usize,
) -> Vec<Memory> {
    let mut out = Vec::new();
    for milestone in MILESTONES {
        let target_year = cal.year(cal.adding_years(day, -milestone));
        let deduped = same_month_day_other_years(cal, day, dated, |y| y == target_year);
        if deduped.len() < min_photos {
            continue;
        }
        let ids = ids_of(photos, &deduped);
        out.push(Memory {
            id: format!("yearsAgo-{}-{}", milestone, LocalCalendar::iso_day_gmt(day)),
            kind: MemoryType::YearsAgo,
            title: format!("On this day in {target_year}"),
            subtitle: None,
            cover_photo_id: ids[ids.len() / 2],
            photo_ids: ids,
            date_range: Some((deduped[0].1, deduped[deduped.len() - 1].1)),
            score: if milestone >= 10 {
                45.0
            } else if milestone >= 5 {
                40.0
            } else {
                35.0
            },
            years_ago: Some(milestone as i32),
            person_name: None,
        });
    }
    out
}
