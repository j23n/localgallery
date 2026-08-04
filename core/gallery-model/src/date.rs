//! Dates in the two shapes the app actually persists and compares.
//!
//! Neither is `chrono`: the workspace has no date dependency, the conversions
//! needed here are a page of arithmetic, and the *exact* semantics are more
//! important than the ergonomics. What matters is which of two clocks a value
//! is on, and Rust's type system is the only thing stopping the two from being
//! added together.

use serde::{Deserialize, Serialize};
use std::fmt;

/// Seconds between the Unix epoch and Apple's reference date, 2001-01-01.
pub const APPLE_EPOCH_OFFSET: f64 = 978_307_200.0;

/// An instant, encoded the way `Foundation.Date` encodes itself.
///
/// `JSONEncoder`'s default strategy is `.deferredToDate`: a bare JSON *number*
/// of seconds since **2001-01-01T00:00:00Z**, fractional part kept. Not ISO
/// 8601, not the Unix epoch — a Unix-epoch reading of `651234567.25` lands in
/// 1990 and the library silently re-dates itself.
///
/// Stored as the `f64` Swift stores, so equality here is exactly Swift's
/// `Date ==`, including its ~microsecond resolution at present-day magnitudes.
/// That is what makes the scanner's cache-hit rule portable.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Deserialize)]
#[serde(transparent)]
pub struct AppleDate(pub f64);

impl Serialize for AppleDate {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        crate::swift_json::serialize_f64(&self.0, s)
    }
}

impl AppleDate {
    /// From seconds since the Unix epoch.
    pub fn from_unix_secs_f64(secs: f64) -> Self {
        AppleDate(secs - APPLE_EPOCH_OFFSET)
    }

    /// From a `(whole seconds, nanoseconds)` pair since the Unix epoch — i.e.
    /// straight off a `stat`.
    pub fn from_unix(secs: i64, subsec_nanos: u32) -> Self {
        AppleDate::from_unix_secs_f64(secs as f64 + f64::from(subsec_nanos) / 1e9)
    }

    /// Seconds since the Unix epoch.
    pub fn unix_secs_f64(self) -> f64 {
        self.0 + APPLE_EPOCH_OFFSET
    }

    /// The earlier of two instants, mirroring `min(creation, modification)` in
    /// `MetadataReader.earliestFilesystemDate` — including its handling of a
    /// missing side, which is "use the other one".
    pub fn earliest(creation: Option<AppleDate>, modification: Option<AppleDate>) -> Option<Self> {
        match (creation, modification) {
            (Some(c), Some(m)) => Some(if c.0 <= m.0 { c } else { m }),
            (Some(c), None) => Some(c),
            (None, Some(m)) => Some(m),
            (None, None) => None,
        }
    }

    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` — the conformance fixtures' `utc` basis.
    ///
    /// Unlike [`CivilDateTime::format_millis`], the milliseconds here are
    /// real: this renders an instant off the filesystem, which routinely has
    /// a sub-second part, rather than an EXIF string, which never does.
    pub fn to_utc_string(self) -> String {
        let secs = self.unix_secs_f64();
        let mut whole = secs.floor();
        let mut millis = ((secs - whole) * 1000.0).round() as u32;
        if millis >= 1000 {
            whole += 1.0;
            millis -= 1000;
        }
        let civil = CivilDateTime::from_unix_secs_f64(whole);
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
            civil.year, civil.month, civil.day, civil.hour, civil.minute, civil.second, millis
        )
    }
}

/// A wall clock with no time zone attached.
///
/// EXIF capture dates carry no zone and `MetadataReader.exifDateFormatter` sets
/// none, so Swift interprets them in the *device* zone: the same file read in
/// Berlin and in Tokyo yields different instants but the same wall clock. The
/// core has no business guessing a zone, so it hands the wall clock back and
/// lets the platform layer resolve it — which also makes the value comparable
/// against the fixtures, whose `localWallClock` basis exists for this reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct CivilDateTime {
    /// Proleptic Gregorian year.
    pub year: i32,
    /// 1-12.
    pub month: u32,
    /// 1-31.
    pub day: u32,
    /// 0-23. An input hour of 24 has already rolled into the next day.
    pub hour: u32,
    /// 0-59.
    pub minute: u32,
    /// 0-59.
    pub second: u32,
}

impl CivilDateTime {
    /// Build from calendar fields, normalising `hour == 24` into 00:00 of the
    /// following day.
    ///
    /// That rollover is not politeness, it is the pinned behaviour: Foundation
    /// accepts `2021:07:04 24:00:00` and returns 2021-07-05T00:00:00 (fixture
    /// `exif/hour_24.jpg`). A strict `0..=23` parser returns nil there and
    /// diverges.
    pub fn new(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> Self {
        let base = CivilDateTime {
            year,
            month,
            day,
            hour: 0,
            minute,
            second,
        };
        if hour >= 24 {
            let rolled = days_from_civil(year, month, day) + i64::from(hour / 24);
            let (y, m, d) = civil_from_days(rolled);
            CivilDateTime {
                year: y,
                month: m,
                day: d,
                hour: hour % 24,
                ..base
            }
        } else {
            CivilDateTime { hour, ..base }
        }
    }

    /// Seconds since the Unix epoch, *pretending the wall clock is UTC*.
    ///
    /// Only meaningful as a comparison key or a transport encoding. Resolving
    /// the true instant needs a zone, which is the platform layer's job.
    pub fn as_naive_unix_secs(self) -> i64 {
        days_from_civil(self.year, self.month, self.day) * 86_400
            + i64::from(self.hour) * 3600
            + i64::from(self.minute) * 60
            + i64::from(self.second)
    }

    /// Inverse of [`Self::as_naive_unix_secs`]; also used to render UTC
    /// instants, which are the same arithmetic with the zone already applied.
    pub fn from_unix_secs_f64(secs: f64) -> Self {
        let whole = secs.floor() as i64;
        let days = whole.div_euclid(86_400);
        let rem = whole.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        CivilDateTime {
            year,
            month,
            day,
            hour: (rem / 3600) as u32,
            minute: ((rem % 3600) / 60) as u32,
            second: (rem % 60) as u32,
        }
    }

    /// `yyyy-MM-dd'T'HH:mm:ss.SSS` (+ `Z` when `utc`) — the fixture spelling.
    ///
    /// Milliseconds are always `.000`: the EXIF format string has no subsecond
    /// field, so `SubSecTimeOriginal` never reaches a parsed date (fixture
    /// `exif/full.jpg`).
    pub fn format_millis(self, utc: bool) -> String {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.000{}",
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
            if utc { "Z" } else { "" }
        )
    }
}

impl fmt::Display for CivilDateTime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.format_millis(false))
    }
}

/// Days in `month` of `year`, proleptic Gregorian.
pub fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn is_leap(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// Howard Hinnant's `days_from_civil`: civil date → days since 1970-01-01.
/// Exact for the whole proleptic Gregorian range, no lookup tables.
fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = i64::from(y) - i64::from(m <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // 0..=399
    let doy = (153 * (i64::from(m) + if m > 2 { -3 } else { 9 }) + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Inverse of [`days_from_civil`].
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // 0..=146096
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (mp + if mp < 10 { 3 } else { -9 }) as u32;
    ((y + i64::from(m <= 2)) as i32, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_days_round_trip_across_era_boundaries() {
        for &(y, m, d) in &[
            (1970, 1, 1),
            (1969, 12, 31),
            (2000, 2, 29),
            (1900, 3, 1),
            (2021, 7, 4),
            (2400, 2, 29),
            (1, 1, 1),
        ] {
            let days = days_from_civil(y, m, d);
            assert_eq!(civil_from_days(days), (y, m, d), "{y}-{m}-{d}");
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(1970, 1, 2), 1);
        assert_eq!(days_from_civil(1969, 12, 31), -1);
    }

    #[test]
    fn hour_24_rolls_into_the_next_day() {
        let t = CivilDateTime::new(2021, 7, 4, 24, 0, 0);
        assert_eq!(t.format_millis(false), "2021-07-05T00:00:00.000");
    }

    #[test]
    fn apple_dates_are_offset_from_2001_not_1970() {
        // The fixture's decorated photo, verbatim.
        let d = AppleDate(651_234_567.25);
        assert_eq!(d.unix_secs_f64(), 651_234_567.25 + 978_307_200.0);
        assert_eq!(d.to_utc_string(), "2021-08-21T10:29:27.250Z");
        // The same number read as a Unix timestamp lands 30 years early —
        // which is exactly the silent failure this type exists to prevent.
        assert_eq!(CivilDateTime::from_unix_secs_f64(651_234_567.25).year, 1990);
        assert_eq!(AppleDate::from_unix_secs_f64(978_307_200.0), AppleDate(0.0));
    }

    #[test]
    fn earliest_matches_the_swift_fallback_ladder() {
        let a = AppleDate(10.0);
        let b = AppleDate(20.0);
        assert_eq!(AppleDate::earliest(Some(b), Some(a)), Some(a));
        assert_eq!(AppleDate::earliest(Some(a), None), Some(a));
        assert_eq!(AppleDate::earliest(None, Some(b)), Some(b));
        assert_eq!(AppleDate::earliest(None, None), None);
    }

    #[test]
    fn utc_rendering_matches_the_fixture_spelling() {
        let t = AppleDate::from_unix_secs_f64(1_614_592_800.0); // 2021-03-01T10:00:00Z
        assert_eq!(t.to_utc_string(), "2021-03-01T10:00:00.000Z");
    }

    #[test]
    fn days_in_month_knows_leap_years() {
        assert_eq!(days_in_month(2021, 2), 28);
        assert_eq!(days_in_month(2020, 2), 29);
        assert_eq!(days_in_month(1900, 2), 28);
        assert_eq!(days_in_month(2000, 2), 29);
        assert_eq!(days_in_month(2021, 13), 0);
    }
}
