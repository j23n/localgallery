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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::photos_with_dates;
    use crate::time::UtcOffset;
    use gallery_model::CivilDateTime;

    /// Ported from the deleted `MemoryEngineCalendarTests`. The two cases below
    /// are the ones `memory_engine.json` cannot state — no fixture scenario has
    /// a current-year photo on today's month/day, and none has a burst that
    /// collapses *below* the threshold. The fixtures were generated from the
    /// shipping Swift and the Swift is now deleted, so a new scenario could only
    /// pin Rust against itself; these assertions carry the Swift's expectations
    /// across instead.
    fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(y, mo, d, h, mi, s).as_naive_unix_secs() as f64
        )
    }

    fn library(dates: &[AppleDate]) -> Vec<PhotoFile> {
        dates
            .iter()
            .enumerate()
            .map(|(i, d)| {
                let mut p = PhotoFile::new(&format!("/lib/otd-{i}.jpg"), format!("otd-{i}"), 0);
                p.date_taken = Some(*d);
                p
            })
            .collect()
    }

    fn cal() -> LocalCalendar {
        LocalCalendar::new(UtcOffset::UTC)
    }

    #[test]
    fn on_this_day_excludes_the_current_year_and_every_other_day() {
        let today = utc(2024, 6, 11, 12, 0, 0);
        let photos = library(&[
            utc(2019, 6, 11, 10, 0, 0),
            utc(2020, 6, 11, 10, 0, 0),
            utc(2021, 6, 11, 10, 0, 0),
            // Same month/day, current year — must not count.
            utc(2024, 6, 11, 10, 0, 0),
            // Different day entirely — must not count.
            utc(2019, 6, 12, 10, 0, 0),
        ]);
        let dated = photos_with_dates(&photos);
        let memory = generate_on_this_day(&cal(), &photos, today, &dated, 3).expect("a memory");
        assert_eq!(memory.photo_ids.len(), 3);
        assert!(!memory.photo_ids.contains(&photos[3].id), "current year leaked in");
        assert!(!memory.photo_ids.contains(&photos[4].id), "June 12 leaked in");
        // Three distinct years → 50 + 15.
        assert_eq!(memory.score, 65.0);
    }

    /// `min_photos` is a **post-dedup** threshold (landmine 15): three shots in
    /// one 60-second window are one photo, which is below 2.
    #[test]
    fn on_this_day_applies_min_photos_after_the_dedup_window() {
        let today = utc(2024, 6, 11, 12, 0, 0);
        let photos = library(&[
            utc(2019, 6, 11, 10, 0, 0),
            utc(2019, 6, 11, 10, 0, 10),
            utc(2019, 6, 11, 10, 0, 20),
        ]);
        let dated = photos_with_dates(&photos);
        assert!(generate_on_this_day(&cal(), &photos, today, &dated, 2).is_none());
        // …and one photo is enough once the threshold is one.
        assert!(generate_on_this_day(&cal(), &photos, today, &dated, 1).is_some());
    }

    #[test]
    fn years_ago_fires_only_on_a_milestone_and_names_the_year() {
        let today = utc(2024, 6, 11, 12, 0, 0);
        let photos = library(&[
            // 5 years ago — a milestone.
            utc(2019, 6, 11, 10, 0, 0),
            utc(2019, 6, 11, 10, 2, 0),
            // 6 years ago — not one.
            utc(2018, 6, 11, 10, 0, 0),
            utc(2018, 6, 11, 10, 2, 0),
        ]);
        let dated = photos_with_dates(&photos);
        let memories = generate_years_ago(&cal(), &photos, today, &dated, 2);
        assert_eq!(memories.len(), 1);
        assert_eq!(memories[0].id, "yearsAgo-5-2024-06-11");
        assert_eq!(memories[0].years_ago, Some(5));
        assert_eq!(memories[0].title, "On this day in 2019");
        let (first, last) = memories[0].date_range.expect("a range");
        assert!(first.0 <= last.0, "the range is ascending");
    }
}
