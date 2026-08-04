//! EXIF capture date, GPS and orientation, matching what ImageIO hands the app.
//!
//! Two things here look like bugs and are not:
//!
//! - the date parser is **strict about months and days but lenient about hour
//!   24** ([`parse_exif_datetime`]);
//! - the GPS hemisphere refs are compared **case-sensitively**, so a raw
//!   lowercase `"s"` leaves a southern point in the northern hemisphere.
//!
//! Both are pinned by `assets/exif/` and `assets/gps/`. Fixing either changes
//! the date or the location of photos already in every user's library.

use exif::{In, Tag, Value};
use gallery_model::date::{days_in_month, CivilDateTime};

/// What ImageIO's property dictionaries give the scanner.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct ExifFacts {
    /// `DateTimeOriginal` → `DateTimeDigitized` → TIFF `DateTime`, first that
    /// parses. A **wall clock**, deliberately zone-less: see
    /// [`gallery_model::date::CivilDateTime`].
    pub capture_wall_clock: Option<CivilDateTime>,
    /// Signed latitude, or `None` when either coordinate is missing.
    pub gps_latitude: Option<f64>,
    /// Signed longitude, or `None` when either coordinate is missing.
    pub gps_longitude: Option<f64>,
    /// TIFF orientation 1–8.
    ///
    /// `MetadataReader` never reads it — decoding does, in `gallery-ml`. It is
    /// surfaced here so the enrichment path has it without a second parse, and
    /// nothing in the conformance dump compares it.
    pub orientation: Option<u16>,
}

/// Read everything above out of a whole image file.
///
/// Returns defaults rather than an error when the container has no EXIF: a
/// zero-byte file and a PNG with no metadata are both ordinary library
/// contents, not failures (`assets/containers/`).
pub fn read_exif_facts(bytes: &[u8]) -> ExifFacts {
    let mut cursor = std::io::Cursor::new(bytes);
    let Ok(exif) = exif::Reader::new().read_from_container(&mut cursor) else {
        return ExifFacts::default();
    };

    let ascii = |tag: Tag| -> Option<String> {
        let field = exif.get_field(tag, In::PRIMARY)?;
        match &field.value {
            Value::Ascii(values) => values.first().map(|bytes| {
                String::from_utf8_lossy(bytes)
                    .trim_matches(|c: char| c == '\0' || c.is_whitespace())
                    .to_string()
            }),
            _ => None,
        }
    };

    // The fallback chain, in order. A candidate that fails to *parse* falls
    // through to the next one — which is how `0000:00:00 00:00:00` ends up
    // reported as the digitized date rather than as nothing.
    let capture_wall_clock = [Tag::DateTimeOriginal, Tag::DateTimeDigitized, Tag::DateTime]
        .into_iter()
        .filter_map(ascii)
        .find_map(|raw| parse_exif_datetime(&raw));

    let (gps_latitude, gps_longitude) = read_gps(&exif);

    ExifFacts {
        capture_wall_clock,
        gps_latitude,
        gps_longitude,
        orientation: exif
            .get_field(Tag::Orientation, In::PRIMARY)
            .and_then(|f| f.value.get_uint(0))
            .map(|v| v as u16),
    }
}

/// Parse `yyyy:MM:dd HH:mm:ss` the way Foundation's non-lenient POSIX
/// `DateFormatter` does.
///
/// # The strictness table, as observed
///
/// | input | result | fixture |
/// |---|---|---|
/// | `2021:07:04 08:09:10` | accepted | `exif/full.jpg` |
/// | `0000:00:00 00:00:00` | **rejected** (month 0, day 0) | `exif/zero_date.jpg` |
/// | `2021:13:45 08:09:10` | **rejected** (month 13, day 45) | `exif/impossible_date.jpg` |
/// | `2021:07:04 24:00:00` | **accepted**, rolls to the 5th at 00:00 | `exif/hour_24.jpg` |
///
/// Subseconds and `OffsetTimeOriginal` are dropped, because the format string
/// has no field for either — `exif/full.jpg` carries both and neither shows up.
///
/// Hours above 24, and minutes or seconds above 59, are rejected. No fixture
/// pins those, and rejecting is the conservative reading of a formatter that
/// already rejects month 13.
pub fn parse_exif_datetime(raw: &str) -> Option<CivilDateTime> {
    let s = raw.trim_matches(|c: char| c == '\0' || c.is_whitespace());
    let b = s.as_bytes();
    if b.len() != 19 {
        return None;
    }
    if [b[4], b[7], b[13], b[16]] != *b"::::" || b[10] != b' ' {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<u32> {
        let part = &s[range];
        part.bytes().all(|c| c.is_ascii_digit()).then_some(())?;
        part.parse().ok()
    };
    let year = num(0..4)? as i32;
    let month = num(5..7)?;
    let day = num(8..10)?;
    let hour = num(11..13)?;
    let minute = num(14..16)?;
    let second = num(17..19)?;

    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if hour > 24 || minute > 59 || second > 59 {
        return None;
    }
    Some(CivilDateTime::new(year, month, day, hour, minute, second))
}

/// `kCGImagePropertyGPSLatitude` / `…Longitude`, with the refs applied.
///
/// **Both coordinates are required**: a lone latitude yields nothing at all,
/// because the Swift reader binds them in one `guard` (`assets/gps/lat_only.jpg`).
/// Altitude and its ref are never read — there is nowhere to put them.
fn read_gps(exif: &exif::Exif) -> (Option<f64>, Option<f64>) {
    let magnitude = |tag: Tag| -> Option<f64> {
        let field = exif.get_field(tag, In::PRIMARY)?;
        match &field.value {
            Value::Rational(parts) if !parts.is_empty() => {
                let at = |i: usize| parts.get(i).map_or(0.0, |r| r.to_f64());
                Some(at(0) + at(1) / 60.0 + at(2) / 3600.0)
            }
            _ => None,
        }
    };
    let reference = |tag: Tag| -> Option<String> {
        let field = exif.get_field(tag, In::PRIMARY)?;
        match &field.value {
            Value::Ascii(values) => values
                .first()
                .map(|b| String::from_utf8_lossy(b).trim_matches('\0').to_string()),
            _ => None,
        }
    };

    let (Some(lat), Some(lon)) = (magnitude(Tag::GPSLatitude), magnitude(Tag::GPSLongitude)) else {
        return (None, None);
    };
    // `latRef == "S"`, case-sensitive. A camera that wrote a raw lowercase
    // "s" — which exiftool's PrintConv would have normalised — leaves the
    // point in the wrong hemisphere, and always has.
    let lat = if reference(Tag::GPSLatitudeRef).as_deref() == Some("S") {
        -lat
    } else {
        lat
    };
    let lon = if reference(Tag::GPSLongitudeRef).as_deref() == Some("W") {
        -lon
    } else {
        lon
    };
    (Some(lat), Some(lon))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(raw: &str) -> Option<String> {
        parse_exif_datetime(raw).map(|d| d.format_millis(false))
    }

    #[test]
    fn a_well_formed_date_parses() {
        assert_eq!(
            parsed("2021:07:04 08:09:10").as_deref(),
            Some("2021-07-04T08:09:10.000")
        );
    }

    #[test]
    fn the_camera_zero_sentinel_is_rejected() {
        // Month 00 and day 00 are out of range for a non-lenient formatter, so
        // the walk falls through to DateTimeDigitized. A chrono parser that
        // accepted year 0 would silently date the photo to the year 0.
        assert_eq!(parsed("0000:00:00 00:00:00"), None);
    }

    #[test]
    fn impossible_months_and_days_are_rejected() {
        assert_eq!(parsed("2021:13:45 08:09:10"), None);
        assert_eq!(parsed("2021:02:30 08:09:10"), None);
        assert_eq!(parsed("2021:00:04 08:09:10"), None);
        // …but a real leap day is fine.
        assert_eq!(
            parsed("2020:02:29 08:09:10").as_deref(),
            Some("2020-02-29T08:09:10.000")
        );
    }

    #[test]
    fn hour_24_is_accepted_and_rolls_over() {
        assert_eq!(
            parsed("2021:07:04 24:00:00").as_deref(),
            Some("2021-07-05T00:00:00.000"),
            "a strict 0..=23 parser returns None here and diverges"
        );
        assert_eq!(parsed("2021:07:04 25:00:00"), None);
        assert_eq!(parsed("2021:07:04 08:60:00"), None);
    }

    #[test]
    fn the_shape_must_match_exactly() {
        assert_eq!(parsed("2021-07-04 08:09:10"), None);
        assert_eq!(parsed("2021:07:04T08:09:10"), None);
        assert_eq!(parsed("2021:7:4 8:9:10"), None);
        assert_eq!(parsed(""), None);
        // Trailing NUL padding is normal in EXIF ASCII and is trimmed.
        assert_eq!(
            parsed("2021:07:04 08:09:10\0").as_deref(),
            Some("2021-07-04T08:09:10.000")
        );
    }

    #[test]
    fn a_file_with_no_exif_reports_defaults_rather_than_failing() {
        assert_eq!(read_exif_facts(b""), ExifFacts::default());
        assert_eq!(read_exif_facts(b"not an image"), ExifFacts::default());
    }
}
