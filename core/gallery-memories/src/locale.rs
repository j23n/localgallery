//! The locale question, answered explicitly.
//!
//! Two of the engine's outputs are ICU strings in the shipping app:
//!
//! - `MemoryEngine.subtitleWithCount` formats its date range with
//!   `DateFormatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")`, and
//! - `MemoryEngine.countryName(from:)` is
//!   `Locale.current.localizedString(forRegionCode:)`.
//!
//! So `"Jun 11, 2019 · 12 photos"` and `"Argentina & Chile with Anna & Ben"`
//! are **localised strings**, and `memory_engine.json` carries an
//! `environment.localeIdentifier` of `en_US` because of it. The fixture README
//! puts the choice to the port: bundle ICU, take the strings from the platform,
//! or move subtitle composition to the UI.
//!
//! **This crate implements `en_US` and only `en_US`, in Rust, with no ICU.**
//! Bundling ICU to render `"Jun 11, 2019"` is several megabytes for one
//! date skeleton, and moving composition to the UI would put the subtitle
//! outside the conformance fixture that pins it — the two strings *are* part of
//! a `Memory`, and the widget snapshot serialises them. Two consequences the
//! FFI layer owns:
//!
//! 1. A non-`en_US` user sees English memory subtitles and English country
//!    names. That is a **behaviour change** from the shipping app, which
//!    follows the device locale. It is not a regression the fixtures can catch,
//!    because the fixtures are `en_US`.
//! 2. If localisation matters later, the seam is this module: `Memory` grows a
//!    structured date range (it already carries one) and the platform formats
//!    it, or a locale parameter arrives here. Nothing above this file needs to
//!    change.
//!
//! The country table below is not hand-written: it was dumped from ICU
//! `en_US` on macOS via `Locale.localizedString(forRegionCode:)` for every
//! `Locale.Region.isoRegions` entry with a two-letter identifier, which is
//! exactly the function being replaced. Unknown codes fall back to the code
//! itself, mirroring the `?? code` at every Swift call site.

use crate::time::LocalCalendar;
use gallery_model::AppleDate;

/// `MMM` in `en_US`.
const SHORT_MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// `Locale(identifier: "en_US").localizedString(forRegionCode:)`, dumped.
static COUNTRY_NAMES: &[(&str, &str)] = &[
    ("AC", "Ascension Island"),
    ("AD", "Andorra"),
    ("AE", "United Arab Emirates"),
    ("AF", "Afghanistan"),
    ("AG", "Antigua & Barbuda"),
    ("AI", "Anguilla"),
    ("AL", "Albania"),
    ("AM", "Armenia"),
    ("AO", "Angola"),
    ("AQ", "Antarctica"),
    ("AR", "Argentina"),
    ("AS", "American Samoa"),
    ("AT", "Austria"),
    ("AU", "Australia"),
    ("AW", "Aruba"),
    ("AX", "Åland Islands"),
    ("AZ", "Azerbaijan"),
    ("BA", "Bosnia & Herzegovina"),
    ("BB", "Barbados"),
    ("BD", "Bangladesh"),
    ("BE", "Belgium"),
    ("BF", "Burkina Faso"),
    ("BG", "Bulgaria"),
    ("BH", "Bahrain"),
    ("BI", "Burundi"),
    ("BJ", "Benin"),
    ("BL", "St. Barthélemy"),
    ("BM", "Bermuda"),
    ("BN", "Brunei"),
    ("BO", "Bolivia"),
    ("BQ", "Caribbean Netherlands"),
    ("BR", "Brazil"),
    ("BS", "Bahamas"),
    ("BT", "Bhutan"),
    ("BV", "Bouvet Island"),
    ("BW", "Botswana"),
    ("BY", "Belarus"),
    ("BZ", "Belize"),
    ("CA", "Canada"),
    ("CC", "Cocos (Keeling) Islands"),
    ("CD", "Congo - Kinshasa"),
    ("CF", "Central African Republic"),
    ("CG", "Congo - Brazzaville"),
    ("CH", "Switzerland"),
    ("CI", "Côte d’Ivoire"),
    ("CK", "Cook Islands"),
    ("CL", "Chile"),
    ("CM", "Cameroon"),
    ("CN", "China mainland"),
    ("CO", "Colombia"),
    ("CP", "Clipperton Island"),
    ("CQ", "Sark"),
    ("CR", "Costa Rica"),
    ("CU", "Cuba"),
    ("CV", "Cape Verde"),
    ("CW", "Curaçao"),
    ("CX", "Christmas Island"),
    ("CY", "Cyprus"),
    ("CZ", "Czechia"),
    ("DE", "Germany"),
    ("DG", "Diego Garcia"),
    ("DJ", "Djibouti"),
    ("DK", "Denmark"),
    ("DM", "Dominica"),
    ("DO", "Dominican Republic"),
    ("DZ", "Algeria"),
    ("EA", "Ceuta & Melilla"),
    ("EC", "Ecuador"),
    ("EE", "Estonia"),
    ("EG", "Egypt"),
    ("EH", "Western Sahara"),
    ("ER", "Eritrea"),
    ("ES", "Spain"),
    ("ET", "Ethiopia"),
    ("EU", "European Union"),
    ("EZ", "Eurozone"),
    ("FI", "Finland"),
    ("FJ", "Fiji"),
    ("FK", "Falkland Islands"),
    ("FM", "Micronesia"),
    ("FO", "Faroe Islands"),
    ("FR", "France"),
    ("GA", "Gabon"),
    ("GB", "United Kingdom"),
    ("GD", "Grenada"),
    ("GE", "Georgia"),
    ("GF", "French Guiana"),
    ("GG", "Guernsey"),
    ("GH", "Ghana"),
    ("GI", "Gibraltar"),
    ("GL", "Greenland"),
    ("GM", "Gambia"),
    ("GN", "Guinea"),
    ("GP", "Guadeloupe"),
    ("GQ", "Equatorial Guinea"),
    ("GR", "Greece"),
    ("GS", "So. Georgia & So. Sandwich Isl."),
    ("GT", "Guatemala"),
    ("GU", "Guam"),
    ("GW", "Guinea-Bissau"),
    ("GY", "Guyana"),
    ("HK", "Hong Kong"),
    ("HM", "Heard & McDonald Islands"),
    ("HN", "Honduras"),
    ("HR", "Croatia"),
    ("HT", "Haiti"),
    ("HU", "Hungary"),
    ("IC", "Canary Islands"),
    ("ID", "Indonesia"),
    ("IE", "Ireland"),
    ("IL", "Israel"),
    ("IM", "Isle of Man"),
    ("IN", "India"),
    ("IO", "Chagos Archipelago"),
    ("IQ", "Iraq"),
    ("IR", "Iran"),
    ("IS", "Iceland"),
    ("IT", "Italy"),
    ("JE", "Jersey"),
    ("JM", "Jamaica"),
    ("JO", "Jordan"),
    ("JP", "Japan"),
    ("KE", "Kenya"),
    ("KG", "Kyrgyzstan"),
    ("KH", "Cambodia"),
    ("KI", "Kiribati"),
    ("KM", "Comoros"),
    ("KN", "St. Kitts & Nevis"),
    ("KP", "North Korea"),
    ("KR", "South Korea"),
    ("KW", "Kuwait"),
    ("KY", "Cayman Islands"),
    ("KZ", "Kazakhstan"),
    ("LA", "Laos"),
    ("LB", "Lebanon"),
    ("LC", "St. Lucia"),
    ("LI", "Liechtenstein"),
    ("LK", "Sri Lanka"),
    ("LR", "Liberia"),
    ("LS", "Lesotho"),
    ("LT", "Lithuania"),
    ("LU", "Luxembourg"),
    ("LV", "Latvia"),
    ("LY", "Libya"),
    ("MA", "Morocco"),
    ("MC", "Monaco"),
    ("MD", "Moldova"),
    ("ME", "Montenegro"),
    ("MF", "St. Martin"),
    ("MG", "Madagascar"),
    ("MH", "Marshall Islands"),
    ("MK", "North Macedonia"),
    ("ML", "Mali"),
    ("MM", "Myanmar (Burma)"),
    ("MN", "Mongolia"),
    ("MO", "Macao"),
    ("MP", "Northern Mariana Islands"),
    ("MQ", "Martinique"),
    ("MR", "Mauritania"),
    ("MS", "Montserrat"),
    ("MT", "Malta"),
    ("MU", "Mauritius"),
    ("MV", "Maldives"),
    ("MW", "Malawi"),
    ("MX", "Mexico"),
    ("MY", "Malaysia"),
    ("MZ", "Mozambique"),
    ("NA", "Namibia"),
    ("NC", "New Caledonia"),
    ("NE", "Niger"),
    ("NF", "Norfolk Island"),
    ("NG", "Nigeria"),
    ("NI", "Nicaragua"),
    ("NL", "Netherlands"),
    ("NO", "Norway"),
    ("NP", "Nepal"),
    ("NR", "Nauru"),
    ("NU", "Niue"),
    ("NZ", "New Zealand"),
    ("OM", "Oman"),
    ("PA", "Panama"),
    ("PE", "Peru"),
    ("PF", "French Polynesia"),
    ("PG", "Papua New Guinea"),
    ("PH", "Philippines"),
    ("PK", "Pakistan"),
    ("PL", "Poland"),
    ("PM", "St. Pierre & Miquelon"),
    ("PN", "Pitcairn Islands"),
    ("PR", "Puerto Rico"),
    ("PS", "Palestinian Territories"),
    ("PT", "Portugal"),
    ("PW", "Palau"),
    ("PY", "Paraguay"),
    ("QA", "Qatar"),
    ("QO", "Outlying Oceania"),
    ("RE", "Réunion"),
    ("RO", "Romania"),
    ("RS", "Serbia"),
    ("RU", "Russia"),
    ("RW", "Rwanda"),
    ("SA", "Saudi Arabia"),
    ("SB", "Solomon Islands"),
    ("SC", "Seychelles"),
    ("SD", "Sudan"),
    ("SE", "Sweden"),
    ("SG", "Singapore"),
    ("SH", "St. Helena"),
    ("SI", "Slovenia"),
    ("SJ", "Svalbard & Jan Mayen"),
    ("SK", "Slovakia"),
    ("SL", "Sierra Leone"),
    ("SM", "San Marino"),
    ("SN", "Senegal"),
    ("SO", "Somalia"),
    ("SR", "Suriname"),
    ("SS", "South Sudan"),
    ("ST", "São Tomé & Príncipe"),
    ("SV", "El Salvador"),
    ("SX", "Sint Maarten"),
    ("SY", "Syria"),
    ("SZ", "Eswatini"),
    ("TA", "Tristan da Cunha"),
    ("TC", "Turks & Caicos Islands"),
    ("TD", "Chad"),
    ("TF", "French Southern Territories"),
    ("TG", "Togo"),
    ("TH", "Thailand"),
    ("TJ", "Tajikistan"),
    ("TK", "Tokelau"),
    ("TL", "Timor-Leste"),
    ("TM", "Turkmenistan"),
    ("TN", "Tunisia"),
    ("TO", "Tonga"),
    ("TR", "Türkiye"),
    ("TT", "Trinidad & Tobago"),
    ("TV", "Tuvalu"),
    ("TW", "Taiwan"),
    ("TZ", "Tanzania"),
    ("UA", "Ukraine"),
    ("UG", "Uganda"),
    ("UM", "U.S. Outlying Islands"),
    ("UN", "United Nations"),
    ("US", "United States"),
    ("UY", "Uruguay"),
    ("UZ", "Uzbekistan"),
    ("VA", "Vatican City"),
    ("VC", "St. Vincent & Grenadines"),
    ("VE", "Venezuela"),
    ("VG", "British Virgin Islands"),
    ("VI", "U.S. Virgin Islands"),
    ("VN", "Vietnam"),
    ("VU", "Vanuatu"),
    ("WF", "Wallis & Futuna"),
    ("WS", "Samoa"),
    ("XK", "Kosovo"),
    ("YE", "Yemen"),
    ("YT", "Mayotte"),
    ("ZA", "South Africa"),
    ("ZM", "Zambia"),
    ("ZW", "Zimbabwe"),
];

/// `MemoryEngine.countryName(from:)`. `None` for a code ICU does not know,
/// which every call site turns back into the raw code.
pub fn country_name(code: &str) -> Option<&'static str> {
    let upper = code.to_ascii_uppercase();
    COUNTRY_NAMES
        .binary_search_by(|(c, _)| (*c).cmp(upper.as_str()))
        .ok()
        .map(|i| COUNTRY_NAMES[i].1)
}

/// One date in the `en_US` rendering of the `"d MMM yyyy"` skeleton: `MMM d, y`
/// — `"Jun 11, 2019"`, no zero padding on the day.
///
/// The **year** is zero-padded to four digits, and that is not decoration:
/// `yyyy` is a padded field in ICU, so a photo whose EXIF year came back as
/// 875 formats as `"Jan 1, 0875"` in the shipping app and `"Jan 1, 875"` from a
/// bare `{}`. Nothing in the fixtures reaches a year below 1000 — every
/// scenario is 2014 or later — so this is a divergence no scenario could have
/// caught, and the four-digit form is the one the deleted Swift produced.
fn format_day(cal: &LocalCalendar, t: AppleDate) -> String {
    let c = cal.civil(t);
    let month = SHORT_MONTHS
        .get((c.month as usize).wrapping_sub(1))
        .copied()
        .unwrap_or("");
    format!("{} {}, {:04}", month, c.day, c.year)
}

/// `MemoryEngine.formatDateRange`. One date when both ends fall on the same
/// local day, otherwise `"<first> – <last>"` with an EN DASH.
pub fn format_date_range(cal: &LocalCalendar, first: AppleDate, last: AppleDate) -> String {
    if cal.is_same_day(first, last) {
        return format_day(cal, first);
    }
    format!(
        "{} \u{2013} {}",
        format_day(cal, first),
        format_day(cal, last)
    )
}

/// `MemoryEngine.subtitleWithCount`: `"<range> · N photos"`, or just the count
/// when there is no range (a birthday memory whose photos are all undated).
pub fn subtitle_with_count(
    cal: &LocalCalendar,
    date_range: Option<(AppleDate, AppleDate)>,
    count: usize,
) -> String {
    let count_text = format!("{} {}", count, if count == 1 { "photo" } else { "photos" });
    match date_range {
        None => count_text,
        Some((first, last)) => format!(
            "{} \u{00B7} {}",
            format_date_range(cal, first, last),
            count_text
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::UtcOffset;
    use gallery_model::CivilDateTime;

    fn utc(y: i32, mo: u32, d: u32, h: u32) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(y, mo, d, h, 0, 0).as_naive_unix_secs() as f64
        )
    }

    #[test]
    fn the_country_table_is_sorted_and_covers_the_fixture_codes() {
        assert!(COUNTRY_NAMES.windows(2).all(|w| w[0].0 < w[1].0));
        assert_eq!(country_name("AR"), Some("Argentina"));
        assert_eq!(country_name("CL"), Some("Chile"));
        assert_eq!(country_name("DE"), Some("Germany"));
        assert_eq!(country_name("ar"), Some("Argentina"), "codes fold to upper");
        assert_eq!(country_name("ZZ"), None);
    }

    #[test]
    fn subtitles_match_the_pinned_en_us_spellings() {
        let cal = LocalCalendar::new(UtcOffset::UTC);
        let a = utc(2019, 6, 11, 12);
        assert_eq!(
            subtitle_with_count(&cal, Some((a, a)), 12),
            "Jun 11, 2019 \u{00B7} 12 photos"
        );
        assert_eq!(
            subtitle_with_count(&cal, Some((utc(2014, 6, 11, 12), utc(2023, 6, 11, 12))), 44),
            "Jun 11, 2014 \u{2013} Jun 11, 2023 \u{00B7} 44 photos"
        );
        assert_eq!(subtitle_with_count(&cal, None, 1), "1 photo");
    }

    /// ICU's `yyyy` is a **padded** field. A three-digit year — reachable from
    /// a mis-parsed EXIF date, which is where absurd `dateTaken` values come
    /// from — renders as `0875`, not `875`. No fixture scenario goes near it.
    #[test]
    fn the_year_is_padded_to_four_digits_the_way_icu_pads_yyyy() {
        let cal = LocalCalendar::new(UtcOffset::UTC);
        assert_eq!(
            subtitle_with_count(&cal, Some((utc(875, 1, 1, 12), utc(875, 1, 1, 12))), 2),
            "Jan 1, 0875 \u{00B7} 2 photos"
        );
        assert_eq!(
            subtitle_with_count(&cal, Some((utc(9, 3, 4, 12), utc(9, 3, 4, 12))), 1),
            "Mar 4, 0009 \u{00B7} 1 photo"
        );
        // …and a normal four-digit year is unchanged, which is what keeps every
        // fixture green.
        assert_eq!(
            subtitle_with_count(&cal, Some((utc(2019, 6, 11, 12), utc(2019, 6, 11, 12))), 3),
            "Jun 11, 2019 \u{00B7} 3 photos"
        );
    }

    #[test]
    fn a_range_inside_one_local_day_collapses_to_one_date() {
        let cal = LocalCalendar::new(UtcOffset::UTC);
        assert_eq!(
            subtitle_with_count(&cal, Some((utc(2022, 3, 5, 9), utc(2022, 3, 5, 20))), 40),
            "Mar 5, 2022 \u{00B7} 40 photos"
        );
    }
}
