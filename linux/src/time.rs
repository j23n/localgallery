//! Local wall-clock display for EXIF-derived instants.
//!
//! Capture dates are zone-less wall clocks. The host resolves them with
//! `mktime` (device zone) when storing an [`AppleDate`]; UI must render that
//! instant back through `localtime_r`, not as UTC civil fields.

use gallery_model::date::{AppleDate, CivilDateTime};

/// Resolve a zone-less EXIF wall clock in the process local zone (`mktime`).
pub fn instant_from_local_wall(c: CivilDateTime) -> AppleDate {
    let mut tm = unsafe { std::mem::zeroed::<libc::tm>() };
    tm.tm_sec = c.second as i32;
    tm.tm_min = c.minute as i32;
    tm.tm_hour = c.hour as i32;
    tm.tm_mday = c.day as i32;
    tm.tm_mon = c.month as i32 - 1;
    tm.tm_year = c.year - 1900;
    tm.tm_isdst = -1;
    let unix = unsafe { libc::mktime(&mut tm) };
    if unix < 0 {
        return AppleDate::from_unix_secs_f64(c.as_naive_unix_secs() as f64);
    }
    AppleDate::from_unix_secs_f64(unix as f64)
}

/// Civil fields of `date` in the process local zone (`localtime_r`).
pub fn local_civil(date: AppleDate) -> CivilDateTime {
    let unix = date.unix_secs_f64().floor() as libc::time_t;
    let mut tm = unsafe { std::mem::zeroed::<libc::tm>() };
    let ptr = unsafe { libc::localtime_r(&unix, &mut tm) };
    if ptr.is_null() {
        return CivilDateTime::from_unix_secs_f64(date.unix_secs_f64());
    }
    CivilDateTime::new(
        tm.tm_year + 1900,
        (tm.tm_mon + 1) as u32,
        tm.tm_mday as u32,
        tm.tm_hour as u32,
        tm.tm_min as u32,
        tm.tm_sec.max(0) as u32,
    )
}

/// `YYYY-MM-DD` in the local zone.
pub fn format_local_day(date: AppleDate) -> String {
    let c = local_civil(date);
    format!("{:04}-{:02}-{:02}", c.year, c.month, c.day)
}

/// `YYYY-MM-DD  HH:MM` in the local zone (info panel).
pub fn format_local_datetime(date: AppleDate) -> String {
    let c = local_civil(date);
    format!(
        "{:04}-{:02}-{:02}  {:02}:{:02}",
        c.year, c.month, c.day, c.hour, c.minute
    )
}

/// Inclusive local-day range, or a single day when they match.
pub fn format_local_day_range(dates: impl IntoIterator<Item = AppleDate>) -> Option<String> {
    let mut days: Vec<String> = dates.into_iter().map(format_local_day).collect();
    if days.is_empty() {
        return None;
    }
    days.sort();
    let first = days.first()?.clone();
    let last = days.last()?.clone();
    if first == last {
        Some(first)
    } else {
        Some(format!("{first} – {last}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    static TZ_LOCK: Mutex<()> = Mutex::new(());

    unsafe extern "C" {
        fn tzset();
    }

    fn lock_tz(tz: &str) -> MutexGuard<'static, ()> {
        let guard = TZ_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // TZ must be process-wide for `localtime_r` / `mktime`.
        unsafe {
            std::env::set_var("TZ", tz);
            tzset();
        }
        guard
    }

    #[test]
    fn utc_display_matches_the_unix_civil_fields() {
        let _tz = lock_tz("UTC");
        let d = AppleDate::from_unix_secs_f64(1_614_592_800.0); // 2021-03-01T10:00:00Z
        assert_eq!(format_local_day(d), "2021-03-01");
        assert_eq!(format_local_datetime(d), "2021-03-01  10:00");
        let c = local_civil(d);
        let utc = CivilDateTime::from_unix_secs_f64(d.unix_secs_f64());
        assert_eq!(
            (c.year, c.month, c.day, c.hour, c.minute),
            (utc.year, utc.month, utc.day, utc.hour, utc.minute)
        );
    }

    #[test]
    fn local_wall_clock_round_trips_in_offset_zones() {
        for tz in ["UTC", "America/New_York", "Asia/Tokyo", "Europe/Berlin"] {
            let _guard = lock_tz(tz);
            let wall = CivilDateTime::new(2021, 7, 4, 15, 30, 0);
            let instant = instant_from_local_wall(wall);
            let back = local_civil(instant);
            assert_eq!(
                (
                    back.year,
                    back.month,
                    back.day,
                    back.hour,
                    back.minute,
                    back.second
                ),
                (2021, 7, 4, 15, 30, 0),
                "tz={tz}"
            );
            assert_eq!(
                format_local_datetime(instant),
                "2021-07-04  15:30",
                "tz={tz}"
            );
        }
    }

    #[test]
    fn utc_civil_fields_are_the_wrong_clock_outside_utc() {
        let _tz = lock_tz("America/New_York");
        let wall = CivilDateTime::new(2021, 7, 4, 15, 30, 0);
        let instant = instant_from_local_wall(wall);
        let utc = CivilDateTime::from_unix_secs_f64(instant.unix_secs_f64());
        assert_ne!(
            (utc.hour, utc.minute),
            (15, 30),
            "UTC rendering accidentally matched the wall clock"
        );
        assert_eq!(format_local_datetime(instant), "2021-07-04  15:30");
    }

    #[test]
    fn day_range_collapses_a_single_local_day() {
        let _tz = lock_tz("UTC");
        let a = AppleDate::from_unix_secs_f64(1_614_592_800.0);
        let b = AppleDate::from_unix_secs_f64(1_614_592_800.0 + 3600.0);
        assert_eq!(
            format_local_day_range([a, b]).as_deref(),
            Some("2021-03-01")
        );
        let c = AppleDate::from_unix_secs_f64(1_614_592_800.0 + 86_400.0);
        assert_eq!(
            format_local_day_range([a, c]).as_deref(),
            Some("2021-03-01 – 2021-03-02")
        );
    }
}
