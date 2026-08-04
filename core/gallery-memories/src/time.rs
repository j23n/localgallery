//! The calendar `MemoryEngine.generate` never took.
//!
//! Landmine 1 in the fixture README: the Swift `generate` reads
//! `Calendar.current`, even though every sub-generator it calls takes a
//! calendar parameter. The only way the conformance harness could exercise a
//! non-UTC scenario was to move the *process* time zone. Here it is an explicit
//! input threaded through every stage — strictly better, and the reason this
//! crate is testable without a global.
//!
//! ## What a zone is, here
//!
//! A **fixed offset from UTC**, not an IANA zone — but *which* fixed offset is
//! resolved per instant by the caller, not once per run. The workspace has no
//! tz database and no date dependency (see `gallery_model::date`), so a
//! [`LocalCalendar`] is one offset; a [`Zone`] is the offsets the platform's
//! real calendar returned, one per photo plus one for `now`.
//!
//! That split exists because resolving a single offset at `now` and applying it
//! to the whole library is wrong for every DST user, in a way that is invisible
//! until it corrupts the daily rail's own history:
//!
//! > Berlin. A photo taken 2019-07-15 00:30 CEST (UTC+2) is 2019-07-14 22:30Z.
//! > Generate in July and the run's offset is +2, so the photo buckets on
//! > **July 15**. Generate the same library in January and the offset is +1, so
//! > it buckets on **July 14**. The density memory's id flips between
//! > `density-2019-7-15` and `density-2019-7-14`, a trip starting that morning
//! > flips its `trip-<y>-<m>-<d>` key and therefore its **cluster key**, and the
//! > seen (−30) and cool-down (−25) penalties stop matching the history the
//! > user's own taps wrote. Twice a year, for half the world.
//!
//! So: **photo day-bucketing uses the photo's own offset** ([`Zone::at`]) and
//! **today / horizon math uses the offset at `now`** ([`Zone::now`]).
//!
//! ### What is still approximate
//!
//! *Rendering.* Subtitles ([`crate::locale::format_date_range`]) format a
//! memory's date range with the `now` calendar, because `finalize` sees the
//! range's two instants and not the photos they came from. A Berlin user
//! reading a July memory in January sees the same one-hour skew in the printed
//! date that the bucketing no longer has. Fixing it means carrying the range's
//! offsets on `Memory` itself, which is a wire change for a one-hour label
//! error on two days a year.
//!
//! *Instants derived from a day.* [`LocalCalendar::instant_at_midnight`] and
//! [`LocalCalendar::start_of_day`] are always the `now` calendar's. Both are
//! only ever compared against `now`, so there is nothing per-photo about them.
//!
//! **For the FFI layer:** pass `time_zone_offset_seconds` =
//! `Calendar.current.timeZone.secondsFromGMT(for: now)` and one
//! `secondsFromGMT(for: photo.dateTaken)` per photo. Passing no per-photo
//! offsets is allowed and means "use the `now` offset for everything" — the
//! pre-fix behaviour, and what a caller with no real calendar can still do.
//! Both fixture zones (`UTC`, `Asia/Tokyo`) have no DST, so every per-photo
//! offset there equals the constant and the conformance suite cannot tell the
//! two apart.

use gallery_model::{AppleDate, CivilDateTime};

const SECONDS_PER_DAY: f64 = 86_400.0;

/// A fixed offset from UTC, in seconds east of Greenwich.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UtcOffset(pub i32);

impl UtcOffset {
    /// GMT. Also the zone every memory **id** is rendered in — see
    /// [`LocalCalendar::iso_day_gmt`].
    pub const UTC: UtcOffset = UtcOffset(0);

    /// Hours east of Greenwich.
    pub fn hours(h: i32) -> Self {
        UtcOffset(h * 3600)
    }
}

/// A Gregorian calendar pinned to one [`UtcOffset`] — the explicit stand-in for
/// `Calendar.current`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalCalendar {
    pub offset: UtcOffset,
}

/// The offsets a run works in: one for `now`, and one per photo.
///
/// Cheap to carry and cheap to ask — [`Self::at`] is an index into a `Vec<i32>`
/// and returns a `Copy` calendar, so a per-photo call site costs the same as
/// the shared-calendar one it replaced. See the module docs for why the
/// distinction exists at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Zone {
    at_now: LocalCalendar,
    /// Parallel to the run's photo table. **May be empty**, meaning "no
    /// per-photo information available, use `at_now` for everything" — the
    /// behaviour before per-photo offsets existed, and still what a caller
    /// without a real calendar passes.
    per_photo: Vec<i32>,
}

impl Zone {
    /// One offset for everything. What a fixed-offset zone (`UTC`, `Asia/Tokyo`)
    /// collapses to, and the shape every Rust unit test uses.
    pub fn fixed(offset: UtcOffset) -> Self {
        Zone {
            at_now: LocalCalendar::new(offset),
            per_photo: Vec::new(),
        }
    }

    /// `at_now` plus the platform-resolved offset of each photo's own instant.
    pub fn new(at_now: UtcOffset, per_photo: Vec<i32>) -> Self {
        Zone {
            at_now: LocalCalendar::new(at_now),
            per_photo,
        }
    }

    /// The calendar for `now`: today's day, the horizon's days, the six-month
    /// and three-day penalty windows, and every rendered date.
    pub fn now(&self) -> LocalCalendar {
        self.at_now
    }

    /// The calendar a photo's own wall clock was on. Falls back to [`Self::now`]
    /// for an index the caller supplied no offset for, so a short or empty
    /// table degrades to the old behaviour instead of panicking.
    pub fn at(&self, photo_index: u32) -> LocalCalendar {
        match self.per_photo.get(photo_index as usize) {
            Some(offset) => LocalCalendar::new(UtcOffset(*offset)),
            None => self.at_now,
        }
    }

    /// Whether any per-photo offset differs from `now`'s — i.e. whether this
    /// run can bucket a photo differently than a single-offset run would.
    /// Diagnostics only.
    pub fn has_per_photo_offsets(&self) -> bool {
        self.per_photo.iter().any(|o| *o != self.at_now.offset.0)
    }
}

/// A local calendar day, the granularity nearly every generator groups by.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct YearMonthDay {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

/// A `(month, day)` pair — birthdays and the on-this-day filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MonthDay {
    pub month: u32,
    pub day: u32,
}

impl LocalCalendar {
    pub fn new(offset: UtcOffset) -> Self {
        LocalCalendar { offset }
    }

    /// Local wall-clock fields for an instant.
    pub fn civil(&self, t: AppleDate) -> CivilDateTime {
        CivilDateTime::from_unix_secs_f64(t.unix_secs_f64() + f64::from(self.offset.0))
    }

    /// `calendar.dateComponents([.year, .month, .day], from:)`.
    pub fn ymd(&self, t: AppleDate) -> YearMonthDay {
        let c = self.civil(t);
        YearMonthDay {
            year: c.year,
            month: c.month,
            day: c.day,
        }
    }

    /// `calendar.dateComponents([.month, .day], from:)`.
    pub fn month_day(&self, t: AppleDate) -> MonthDay {
        let c = self.civil(t);
        MonthDay {
            month: c.month,
            day: c.day,
        }
    }

    /// `calendar.component(.year, from:)`.
    pub fn year(&self, t: AppleDate) -> i32 {
        self.civil(t).year
    }

    /// The instant local midnight of `t`'s day. `calendar.startOfDay(for:)`.
    pub fn start_of_day(&self, t: AppleDate) -> AppleDate {
        let shifted = t.unix_secs_f64() + f64::from(self.offset.0);
        let floored = (shifted / SECONDS_PER_DAY).floor() * SECONDS_PER_DAY;
        AppleDate::from_unix_secs_f64(floored - f64::from(self.offset.0))
    }

    /// Local midnight of an explicit `y/m/d`. `calendar.date(from: dayComps)`.
    pub fn instant_at_midnight(&self, day: YearMonthDay) -> AppleDate {
        let civil = CivilDateTime::new(day.year, day.month, day.day, 0, 0, 0);
        AppleDate::from_unix_secs_f64(civil.as_naive_unix_secs() as f64 - f64::from(self.offset.0))
    }

    /// `calendar.date(byAdding: .day, value:, to:)`. With a fixed offset the
    /// wall clock is preserved by construction.
    pub fn adding_days(&self, t: AppleDate, days: i64) -> AppleDate {
        AppleDate(t.0 + days as f64 * SECONDS_PER_DAY)
    }

    /// `calendar.date(byAdding: .month, value:, to:)`, including Foundation's
    /// day clamping: one month before March 31 is the last day of February.
    pub fn adding_months(&self, t: AppleDate, months: i64) -> AppleDate {
        let c = self.civil(t);
        let total = i64::from(c.year) * 12 + i64::from(c.month) - 1 + months;
        let year = total.div_euclid(12) as i32;
        let month = (total.rem_euclid(12) + 1) as u32;
        let day = c.day.min(gallery_model::date::days_in_month(year, month));
        let civil = CivilDateTime::new(year, month, day, c.hour, c.minute, c.second);
        AppleDate::from_unix_secs_f64(civil.as_naive_unix_secs() as f64 - f64::from(self.offset.0))
    }

    /// `calendar.date(byAdding: .year, value:, to:)`.
    pub fn adding_years(&self, t: AppleDate, years: i64) -> AppleDate {
        self.adding_months(t, years * 12)
    }

    /// `calendar.dateComponents([.day], from: a, to: b).day` — the count of
    /// *whole* days between two instants, which for a fixed offset is the floor
    /// of the elapsed time in days.
    pub fn day_difference(&self, from: AppleDate, to: AppleDate) -> i64 {
        ((to.0 - from.0) / SECONDS_PER_DAY).floor() as i64
    }

    /// `calendar.isDate(_:inSameDayAs:)`.
    pub fn is_same_day(&self, a: AppleDate, b: AppleDate) -> bool {
        self.ymd(a) == self.ymd(b)
    }

    /// **The id's date is rendered in GMT while the day it is about is local.**
    ///
    /// `MemoryEngine`'s `iso8601Day` is a bare `ISO8601DateFormatter` with
    /// `.withFullDate`, and its time zone defaults to GMT. In Tokyo the engine
    /// correctly selects the June-12-local photos and calls the result
    /// `onThisDay-2024-06-11`. Landmine 2, and the root of the widget
    /// deep-link drift in landmine 3 — pinned, not fixed.
    pub fn iso_day_gmt(t: AppleDate) -> String {
        let c = CivilDateTime::from_unix_secs_f64(t.unix_secs_f64());
        format!("{:04}-{:02}-{:02}", c.year, c.month, c.day)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(y, mo, d, h, mi, 0).as_naive_unix_secs() as f64
        )
    }

    #[test]
    fn tokyo_midnight_is_the_previous_gmt_afternoon() {
        let tokyo = LocalCalendar::new(UtcOffset::hours(9));
        // 2024-06-08T03:00Z is 12:00 JST on the 8th.
        let noon_jst = utc(2024, 6, 8, 3, 0);
        assert_eq!(
            tokyo.ymd(noon_jst),
            YearMonthDay {
                year: 2024,
                month: 6,
                day: 8
            }
        );
        let start = tokyo.start_of_day(noon_jst);
        assert_eq!(start, utc(2024, 6, 7, 15, 0));
        // …and that is where the widget's pre-published id drift comes from.
        assert_eq!(LocalCalendar::iso_day_gmt(start), "2024-06-07");
    }

    #[test]
    fn the_id_is_gmt_even_when_the_day_is_local() {
        let tokyo = LocalCalendar::new(UtcOffset::hours(9));
        let t = utc(2024, 6, 11, 15, 30); // 2024-06-12 00:30 JST
        assert_eq!(tokyo.month_day(t), MonthDay { month: 6, day: 12 });
        assert_eq!(LocalCalendar::iso_day_gmt(t), "2024-06-11");
    }

    #[test]
    fn whole_days_are_floored_not_rounded() {
        let cal = LocalCalendar::new(UtcOffset::UTC);
        assert_eq!(
            cal.day_difference(utc(2023, 3, 5, 9, 0), utc(2023, 3, 9, 15, 0)),
            4
        );
        assert_eq!(
            cal.day_difference(utc(2023, 3, 5, 9, 0), utc(2023, 3, 9, 8, 0)),
            3
        );
    }

    #[test]
    fn month_arithmetic_clamps_the_day() {
        let cal = LocalCalendar::new(UtcOffset::UTC);
        let march31 = utc(2024, 3, 31, 12, 0);
        assert_eq!(cal.ymd(cal.adding_months(march31, -1)).day, 29);
        assert_eq!(cal.ymd(cal.adding_months(march31, -6)).month, 9);
        assert_eq!(cal.ymd(cal.adding_months(march31, -6)).year, 2023);
    }

    /// The exact scenario the per-photo offset exists for. A single offset
    /// resolved at `now` buckets a July photo on a different day depending on
    /// which season the generation runs in; the per-photo offset does not.
    #[test]
    fn a_berlin_summer_photo_buckets_the_same_in_january_and_in_july() {
        // 2019-07-14T22:30Z is 2019-07-15 00:30 CEST (UTC+2).
        let photo = utc(2019, 7, 14, 22, 30);
        let cest = 2 * 3600;
        let cet = 3600;

        // The bug: one offset for the whole run.
        let summer_run = Zone::fixed(UtcOffset(cest));
        let winter_run = Zone::fixed(UtcOffset(cet));
        assert_eq!(summer_run.at(0).ymd(photo).day, 15);
        assert_eq!(
            winter_run.at(0).ymd(photo).day,
            14,
            "precondition: a winter-resolved offset moves the photo a day back"
        );

        // The fix: the photo carries the offset that was in force when it was
        // taken, whichever season the run happens in.
        let summer = Zone::new(UtcOffset(cest), vec![cest]);
        let winter = Zone::new(UtcOffset(cet), vec![cest]);
        assert_eq!(summer.at(0).ymd(photo), winter.at(0).ymd(photo));
        assert_eq!(winter.at(0).ymd(photo).day, 15);
        // …while `now` still uses the run's own offset, which is what the
        // horizon and the penalty windows need.
        assert_eq!(winter.now().offset, UtcOffset(cet));
    }

    /// An empty per-photo table is the documented "no calendar available"
    /// input, not a bug: it degrades to the single-offset behaviour.
    #[test]
    fn a_missing_per_photo_offset_falls_back_to_now() {
        let zone = Zone::new(UtcOffset::hours(9), vec![3600]);
        assert_eq!(zone.at(0).offset, UtcOffset(3600));
        assert_eq!(zone.at(7).offset, UtcOffset::hours(9), "past the table");
        assert!(zone.has_per_photo_offsets());
        assert!(!Zone::fixed(UtcOffset::hours(9)).has_per_photo_offsets());
    }

    #[test]
    fn round_trips_through_local_midnight() {
        let cal = LocalCalendar::new(UtcOffset::hours(-8));
        let t = utc(2024, 6, 11, 12, 0);
        let start = cal.start_of_day(t);
        assert_eq!(cal.ymd(start), cal.ymd(t));
        assert_eq!(cal.instant_at_midnight(cal.ymd(t)), start);
    }
}
