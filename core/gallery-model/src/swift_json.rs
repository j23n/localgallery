//! Number formatting that matches `Foundation.JSONEncoder`.
//!
//! Swift writes a `Double` whose value is integral **without** a fractional
//! part: `649000000`, not `649000000.0`. serde_json always writes the `.0`.
//! Both decode to the same `Double` on either side, so nothing breaks — but
//! "the same JSON object" is a much easier property to test than "close
//! enough", and the fixture round-trip in
//! `tests/library_snapshot_roundtrip.rs` is only meaningful if the re-encoded
//! bytes really are the bytes the app writes.

use serde::Serializer;

/// A `Double`, spelled the way `JSONEncoder` spells it.
///
/// Negative zero is the one integral value kept in float form: Swift writes it
/// as `-0`, and an `i64` cast would silently turn a southern-hemisphere zero
/// latitude into a northern one. serde_json renders it `-0.0`, which differs
/// from Swift by one character and decodes to the same `Double` — the only
/// place this module knowingly diverges.
pub fn serialize_f64<S: Serializer>(value: &f64, s: S) -> Result<S::Ok, S::Error> {
    let integral = value.is_finite()
        && value.fract() == 0.0
        && value.abs() < 9_007_199_254_740_992.0
        && !(*value == 0.0 && value.is_sign_negative());
    if integral {
        s.serialize_i64(*value as i64)
    } else {
        s.serialize_f64(*value)
    }
}

/// [`serialize_f64`] for a field that is skipped when `None`.
pub fn serialize_opt_f64<S: Serializer>(value: &Option<f64>, s: S) -> Result<S::Ok, S::Error> {
    match value {
        Some(v) => serialize_f64(v, s),
        None => s.serialize_none(),
    }
}

/// `skip_serializing_if` for an optional `Double` field: **absent, or not a
/// number**.
///
/// Swift's `JSONEncoder` refuses to encode a non-finite `Double` — it throws
/// `invalidValue`, and `JSONDiskCache.save` logs that and moves on, so a single
/// NaN latitude stops the library snapshot ever reaching disk again. serde_json
/// is the other way round and quietly writes `null`, which Swift then decodes
/// as `nil` anyway.
///
/// Both readings agree that a non-finite number carries no information, so the
/// field is treated as **absent** rather than written in either spelling. The
/// sources are fixed where the values enter (`gallery_meta`'s `read_gps` drops
/// a `0/0` rational); this is the backstop that keeps a value nothing can use
/// out of the wire format regardless.
pub fn is_absent_f64(value: &Option<f64>) -> bool {
    !matches!(value, Some(v) if v.is_finite())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Serialize;

    #[derive(Serialize)]
    struct Wrapper(#[serde(serialize_with = "serialize_f64")] f64);

    fn render(v: f64) -> String {
        serde_json::to_string(&Wrapper(v)).unwrap()
    }

    #[test]
    fn integral_doubles_lose_the_fractional_part() {
        assert_eq!(render(649_000_000.0), "649000000");
        assert_eq!(render(0.0), "0");
        assert_eq!(render(-12.0), "-12");
    }

    #[test]
    fn fractional_doubles_keep_every_digit() {
        assert_eq!(render(651_234_567.25), "651234567.25");
        assert_eq!(render(41.9028), "41.9028");
        assert_eq!(render(-151.2093), "-151.2093");
    }

    #[test]
    fn a_non_finite_optional_is_absent_not_null() {
        assert!(is_absent_f64(&None));
        assert!(is_absent_f64(&Some(f64::NAN)));
        assert!(is_absent_f64(&Some(f64::INFINITY)));
        assert!(is_absent_f64(&Some(f64::NEG_INFINITY)));
        // …and a real coordinate, including the equator, is present.
        assert!(!is_absent_f64(&Some(48.8581)));
        assert!(!is_absent_f64(&Some(0.0)));
        assert!(!is_absent_f64(&Some(-0.0)));
    }

    #[test]
    fn negative_zero_keeps_its_sign() {
        assert_eq!(
            render(-0.0),
            "-0.0",
            "an i64 cast would move the equator into the northern hemisphere"
        );
    }
}
