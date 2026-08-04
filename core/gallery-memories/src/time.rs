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
//! A **fixed offset from UTC**, not an IANA zone. The workspace has no tz
//! database and no date dependency (see `gallery_model::date`), and shipping
//! one to get `Europe/Berlin`'s DST transitions right would be a large
//! dependency for a small correctness gain: every quantity the engine derives
//! from the calendar is a *day bucket*, and a DST shift moves a day boundary by
//! an hour twice a year. The visible consequence is that a photo taken within
//! an hour of local midnight on a transition day can land in the adjacent day
//! bucket. Both fixture zones (`UTC`, `Asia/Tokyo`) are fixed-offset, so the
//! conformance suite does not exercise the difference.
//!
//! **For the FFI layer:** pass the offset that `TimeZone.current.secondsFromGMT(for:)`
//! returns *for `now`*. That makes the horizon and today's generation exact,
//! and leaves only historical photo bucketing approximate. If that ever stops
//! being good enough, the fix is a zone parameter carrying a transition table,
//! not a change to any of the ladder code.

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

    #[test]
    fn round_trips_through_local_midnight() {
        let cal = LocalCalendar::new(UtcOffset::hours(-8));
        let t = utc(2024, 6, 11, 12, 0);
        let start = cal.start_of_day(t);
        assert_eq!(cal.ymd(start), cal.ymd(t));
        assert_eq!(cal.instant_at_midnight(cal.ymd(t)), start);
    }
}
