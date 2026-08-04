//! A literal port of `MetadataReader`'s XMP scanning, bugs included.
//!
//! This is **not** [`crate::read`]. That module parses XMP properly, by
//! namespace URI, and is what the *writer* checks itself against. This one
//! reproduces what the shipping app actually sees: a substring scan for
//! `<digiKam:TagsList>`, `<rdf:li>`, `<mwg-rs:Area` and
//! `<photo-tools:CountryCode>` over the raw text.
//!
//! Every difference between the two is a divergence the port must keep, not
//! close. The conformance fixtures pin nine of them (`assets/regions/`,
//! `assets/sidecar/`); the three that bite hardest:
//!
//! - a region's name is found by searching **backwards** from its `Area`, so
//!   an `Area`-before-`Name` serialisation labels every region with its
//!   predecessor's name and loses the last one;
//! - an unterminated `<mwg-rs:Area` swallows the next well-formed region,
//!   because the look-ahead for `</mwg-rs:Area>` reaches across it;
//! - a sidecar with no closing `</digiKam:TagsList>` yields zero tags, not a
//!   partial list, and says nothing about it.
//!
//! Fixing any of them is a deliberate change with a `LibrarySnapshot` version
//! bump attached, because it re-dates and re-tags every library in the field.

/// How far back from an `<mwg-rs:Area` the name search looks, in **characters**.
///
/// Swift counts `String.Index` distance, i.e. grapheme clusters; this counts
/// Unicode scalars. The two differ only for combining sequences inside the
/// window, which no fixture exercises — see the port's "fixture gaps" note.
const NAME_LOOKBACK_CHARS: usize = 2_000;

/// Everything `MetadataReader` extracts from one XMP text.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct SwiftXmpParse {
    /// `digiKam:TagsList` entries, in document order, whitespace-trimmed,
    /// empties dropped. **Only** that property: `lr:hierarchicalSubject` and
    /// `dc:subject` are invisible to the app even when they disagree.
    pub raw_tags: Vec<String>,
    /// `photo-tools:CountryCode` or `phototools:CountryCode`, uppercased.
    pub country_code: Option<String>,
    /// MWG regions, with the name shift described above already applied.
    pub face_regions: Vec<SwiftFaceRegion>,
}

/// One region as the app sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct SwiftFaceRegion {
    /// Nearest `mwg-rs:Name` *preceding* the area — frequently the wrong one.
    pub name: Option<String>,
    /// `stArea:x`.
    pub center_x: f64,
    /// `stArea:y`.
    pub center_y: f64,
    /// `stArea:w`.
    pub width: f64,
    /// `stArea:h`.
    pub height: f64,
}

/// Decode an XMP byte buffer to text the way `String(data:encoding:)` does.
///
/// UTF-8 first, **strictly** — a lossy decode would turn a UTF-16 packet into
/// mojibake that parses to nothing instead of falling through. UTF-16 second,
/// honouring a BOM and defaulting to big-endian without one, which is what
/// `NSUTF16StringEncoding` does and what the XMP spec allows.
pub fn decode_xmp_text(data: &[u8]) -> Option<String> {
    if let Ok(text) = std::str::from_utf8(data) {
        return Some(text.to_string());
    }
    let (body, little_endian) = match data {
        [0xFF, 0xFE, rest @ ..] => (rest, true),
        [0xFE, 0xFF, rest @ ..] => (rest, false),
        _ => (data, false),
    };
    if body.len() % 2 != 0 {
        return None;
    }
    let units: Vec<u16> = body
        .chunks_exact(2)
        .map(|c| {
            if little_endian {
                u16::from_le_bytes([c[0], c[1]])
            } else {
                u16::from_be_bytes([c[0], c[1]])
            }
        })
        .collect();
    String::from_utf16(&units).ok()
}

/// `MetadataReader.parseXMPBytes`.
pub fn parse_xmp_bytes(data: &[u8]) -> SwiftXmpParse {
    match decode_xmp_text(data) {
        Some(text) => parse_xmp_text(&text),
        // Neither encoding decoded: Swift returns empty and logs nothing.
        None => SwiftXmpParse::default(),
    }
}

/// [`parse_xmp_bytes`] on already-decoded text.
pub fn parse_xmp_text(xml: &str) -> SwiftXmpParse {
    SwiftXmpParse {
        raw_tags: parse_tags_list(xml),
        country_code: parse_country_code(xml),
        face_regions: parse_mwg_regions(xml),
    }
}

/// `<digiKam:TagsList>` … `</digiKam:TagsList>`, `<rdf:li>` entries only.
///
/// The open-tag probe is `<digiKam:TagsList>` first, then
/// `<digiKam:TagsList ` (trailing space) for attribute-carrying forms — in
/// that order, which is why an attribute form is found at all. The container
/// (`rdf:Seq` vs `rdf:Bag`) is never examined.
fn parse_tags_list(xml: &str) -> Vec<String> {
    const CLOSE: &str = "</digiKam:TagsList>";
    let start = xml
        .find("<digiKam:TagsList>")
        .map(|i| i + "<digiKam:TagsList>".len())
        .or_else(|| {
            xml.find("<digiKam:TagsList ")
                .map(|i| i + "<digiKam:TagsList ".len())
        });
    let Some(start) = start else {
        return Vec::new();
    };
    // No closing tag ⇒ the whole block is skipped. A truncated sidecar looks
    // untagged rather than half-tagged, silently.
    let Some(end_rel) = xml[start..].find(CLOSE) else {
        return Vec::new();
    };
    let block = &xml[start..start + end_rel];

    let mut out = Vec::new();
    let mut cursor = 0usize;
    while let Some(li_rel) = block[cursor..].find("<rdf:li>") {
        let li_start = cursor + li_rel + "<rdf:li>".len();
        let Some(li_end_rel) = block[li_start..].find("</rdf:li>") else {
            break;
        };
        let value = block[li_start..li_start + li_end_rel].trim();
        if !value.is_empty() {
            out.push(value.to_string());
        }
        cursor = li_start + li_end_rel + "</rdf:li>".len();
    }
    out
}

/// The two spellings of the country property, probed in order. The first that
/// yields a non-empty value wins; the value is uppercased.
fn parse_country_code(xml: &str) -> Option<String> {
    for prefix in ["photo-tools:CountryCode", "phototools:CountryCode"] {
        let open = format!("<{prefix}>");
        let close = format!("</{prefix}>");
        if let Some(i) = xml.find(&open) {
            let from = i + open.len();
            if let Some(j) = xml[from..].find(&close) {
                let value = xml[from..from + j].trim();
                if !value.is_empty() {
                    return Some(value.to_uppercase());
                }
            }
        }
    }
    None
}

/// `MetadataReader.parseMWGRegions`.
///
/// Targets `<mwg-rs:Area` directly rather than walking `rdf:li` boundaries,
/// because every writer nests the region container differently but all of them
/// emit exactly one `Area` per region. The cost of that shortcut is the name
/// shift and the malformed-Area swallow documented on this module.
pub fn parse_mwg_regions(xml: &str) -> Vec<SwiftFaceRegion> {
    let mut regions = Vec::new();
    let mut search = 0usize;
    while let Some(rel) = xml[search..].find("<mwg-rs:Area") {
        let area_start = search + rel;
        let Some(gt_rel) = xml[area_start..].find('>') else {
            break;
        };
        let open_end = area_start + gt_rel + 1;
        let open_tag = &xml[area_start..open_end];
        let mut attrs = open_tag.to_string();

        if open_tag.ends_with("/>") {
            search = open_end;
        } else if let Some(close_rel) = xml[open_end..].find("</mwg-rs:Area>") {
            // The look-ahead is unbounded, so an unterminated Area reaches
            // into the *next* region's closing tag and absorbs it whole.
            attrs.push_str(&xml[open_end..open_end + close_rel]);
            search = open_end + close_rel + "</mwg-rs:Area>".len();
        } else {
            // Malformed and nothing after it: skip this Area only.
            search = open_end;
            continue;
        }

        // Absent unit is accepted; anything but "normalized" (any case) drops
        // the region without aborting the walk.
        if let Some(unit) = read_field(&attrs, "stArea:unit") {
            if unit.to_lowercase() != "normalized" {
                continue;
            }
        }
        let (Some(x), Some(y), Some(w), Some(h)) = (
            read_field(&attrs, "stArea:x").and_then(|v| parse_double(&v)),
            read_field(&attrs, "stArea:y").and_then(|v| parse_double(&v)),
            read_field(&attrs, "stArea:w").and_then(|v| parse_double(&v)),
            read_field(&attrs, "stArea:h").and_then(|v| parse_double(&v)),
        ) else {
            continue;
        };

        regions.push(SwiftFaceRegion {
            name: last_mwg_name(lookback(xml, area_start)),
            center_x: x,
            center_y: y,
            width: w,
            height: h,
        });
    }
    regions
}

/// The window `lastMWGName` searches: up to [`NAME_LOOKBACK_CHARS`] characters
/// immediately before `area_start`.
fn lookback(xml: &str, area_start: usize) -> &str {
    let mut start = area_start;
    for _ in 0..NAME_LOOKBACK_CHARS {
        if start == 0 {
            break;
        }
        start -= 1;
        while start > 0 && !xml.is_char_boundary(start) {
            start -= 1;
        }
    }
    &xml[start..area_start]
}

/// Closest-preceding `mwg-rs:Name`: attribute form first, then element form.
fn last_mwg_name(fragment: &str) -> Option<String> {
    if let Some(i) = fragment.rfind("mwg-rs:Name=\"") {
        let from = i + "mwg-rs:Name=\"".len();
        if let Some(j) = fragment[from..].find('"') {
            let v = fragment[from..from + j].trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    if let Some(i) = fragment.rfind("<mwg-rs:Name>") {
        let from = i + "<mwg-rs:Name>".len();
        if let Some(j) = fragment[from..].find("</mwg-rs:Name>") {
            let v = fragment[from..from + j].trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// A field in an XMP fragment: `name="…"` first (untrimmed), then
/// `<name>…</name>` (trimmed).
fn read_field(fragment: &str, name: &str) -> Option<String> {
    let attr = format!("{name}=\"");
    if let Some(i) = fragment.find(&attr) {
        let from = i + attr.len();
        if let Some(j) = fragment[from..].find('"') {
            return Some(fragment[from..from + j].to_string());
        }
    }
    let leaf = name.rsplit('/').next().unwrap_or(name);
    let open = format!("<{leaf}>");
    let close = format!("</{leaf}>");
    let i = fragment.find(&open)?;
    let from = i + open.len();
    let j = fragment[from..].find(&close)?;
    Some(fragment[from..from + j].trim().to_string())
}

/// Swift's `Double(String)`.
///
/// Narrower than Rust's `str::parse::<f64>()`, which also accepts `inf`, `NaN`
/// and hex floats. A coordinate of `"nan"` would sail through the Rust parser
/// and land in the snapshot as a region nothing can draw.
fn parse_double(raw: &str) -> Option<f64> {
    let v: f64 = raw.parse().ok()?;
    v.is_finite().then_some(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(regions: &[SwiftFaceRegion]) -> Vec<Option<&str>> {
        regions.iter().map(|r| r.name.as_deref()).collect()
    }

    #[test]
    fn a_truncated_tags_list_yields_nothing_rather_than_a_partial_list() {
        let xml = "<digiKam:TagsList>\n<rdf:Seq>\n<rdf:li>Places/Ghost</rdf:li>\n";
        assert!(parse_tags_list(xml).is_empty());
    }

    #[test]
    fn the_open_tag_probe_accepts_attributes() {
        let xml = "<digiKam:TagsList xml:lang=\"x-default\">\
                   <rdf:Seq><rdf:li>Places/Norway</rdf:li></rdf:Seq></digiKam:TagsList>";
        assert_eq!(parse_tags_list(xml), vec!["Places/Norway"]);
    }

    #[test]
    fn empty_entries_are_dropped_and_survivors_trimmed() {
        let xml = "<digiKam:TagsList><rdf:Seq>\
                   <rdf:li></rdf:li><rdf:li>   </rdf:li><rdf:li>  Places/Spain  </rdf:li>\
                   </rdf:Seq></digiKam:TagsList>";
        assert_eq!(parse_tags_list(xml), vec!["Places/Spain"]);
    }

    #[test]
    fn the_country_prefixes_are_probed_in_order_and_uppercased() {
        assert_eq!(
            parse_country_code("<photo-tools:CountryCode>it</photo-tools:CountryCode>"),
            Some("IT".into())
        );
        assert_eq!(
            parse_country_code("<phototools:CountryCode>se</phototools:CountryCode>"),
            Some("SE".into())
        );
        assert_eq!(
            parse_country_code("<dc:CountryCode>fr</dc:CountryCode>"),
            None
        );
    }

    #[test]
    fn area_before_name_shifts_every_name_by_one() {
        // exiftool's alphabetical field order. Written Alice, Bob, Carol.
        let xml = ["Alice", "Bob", "Carol"]
            .iter()
            .enumerate()
            .map(|(i, n)| {
                format!(
                    "<rdf:li><mwg-rs:Area stArea:x=\"0.{i}\" stArea:y=\"0.1\" \
                     stArea:w=\"0.1\" stArea:h=\"0.1\" stArea:unit=\"normalized\"/>\
                     <mwg-rs:Name>{n}</mwg-rs:Name></rdf:li>"
                )
            })
            .collect::<String>();
        assert_eq!(
            names(&parse_mwg_regions(&xml)),
            vec![None, Some("Alice"), Some("Bob")],
            "region 0 loses its name and Carol's is dropped entirely"
        );
    }

    #[test]
    fn name_before_area_is_the_ordering_that_works() {
        let xml = "<mwg-rs:Name>Alice</mwg-rs:Name>\
                   <mwg-rs:Area stArea:x=\"0.2\" stArea:y=\"0.1\" stArea:w=\"0.1\" \
                   stArea:h=\"0.1\" stArea:unit=\"normalized\"/>";
        assert_eq!(names(&parse_mwg_regions(xml)), vec![Some("Alice")]);
    }

    #[test]
    fn an_unterminated_area_swallows_the_next_region() {
        let xml = "<mwg-rs:Name>Judy</mwg-rs:Name>\
                   <mwg-rs:Area stArea:x=\"0.1\" stArea:y=\"0.1\" stArea:w=\"0.1\" \
                   stArea:h=\"0.1\" stArea:unit=\"normalized\">\
                   <mwg-rs:Name>Karl</mwg-rs:Name>\
                   <mwg-rs:Area rdf:parseType=\"Resource\">\
                   <stArea:x>0.6</stArea:x><stArea:y>0.6</stArea:y>\
                   <stArea:w>0.2</stArea:w><stArea:h>0.2</stArea:h>\
                   <stArea:unit>normalized</stArea:unit></mwg-rs:Area>";
        let regions = parse_mwg_regions(xml);
        assert_eq!(regions.len(), 1, "the second region disappears");
        assert_eq!(
            regions[0].center_x, 0.1,
            "coords come from the malformed Area"
        );
        assert_eq!(regions[0].name.as_deref(), Some("Judy"));
    }

    #[test]
    fn an_unterminated_area_at_the_end_is_simply_skipped() {
        let xml = "<mwg-rs:Name>Hank</mwg-rs:Name>\
                   <mwg-rs:Area stArea:x=\"0.2\" stArea:y=\"0.2\" stArea:w=\"0.1\" \
                   stArea:h=\"0.1\" stArea:unit=\"normalized\"/>\
                   <mwg-rs:Name>Ivan</mwg-rs:Name>\
                   <mwg-rs:Area stArea:x=\"0.9\" stArea:y=\"0.9\" stArea:w=\"0.05\" \
                   stArea:h=\"0.05\" stArea:unit=\"normalized\">";
        assert_eq!(names(&parse_mwg_regions(xml)), vec![Some("Hank")]);
    }

    #[test]
    fn units_are_accepted_when_absent_or_normalized_in_any_case() {
        let area = |unit: &str, x: &str| {
            format!(
                "<mwg-rs:Area stArea:x=\"{x}\" stArea:y=\"0.1\" stArea:w=\"0.1\" \
                 stArea:h=\"0.1\"{unit}/>"
            )
        };
        let xml = format!(
            "{}{}{}",
            area(" stArea:unit=\"pixel\"", "10"),
            area("", "0.7"),
            area(" stArea:unit=\"Normalized\"", "0.8")
        );
        let regions = parse_mwg_regions(&xml);
        assert_eq!(
            regions.iter().map(|r| r.center_x).collect::<Vec<_>>(),
            vec![0.7, 0.8]
        );
    }

    #[test]
    fn a_name_further_back_than_the_window_is_not_found() {
        let xml = format!(
            "<mwg-rs:Name>Grace</mwg-rs:Name>{}\
             <mwg-rs:Area stArea:x=\"0.3\" stArea:y=\"0.3\" stArea:w=\"0.05\" \
             stArea:h=\"0.05\" stArea:unit=\"normalized\"/>",
            "x".repeat(2_500)
        );
        assert_eq!(names(&parse_mwg_regions(&xml)), vec![None]);
    }

    #[test]
    fn a_non_numeric_coordinate_drops_only_its_own_region() {
        let xml = "<mwg-rs:Name>Bad</mwg-rs:Name>\
                   <mwg-rs:Area stArea:x=\"nope\" stArea:y=\"0.2\" stArea:w=\"0.1\" \
                   stArea:h=\"0.1\" stArea:unit=\"normalized\"/>\
                   <mwg-rs:Name>Good</mwg-rs:Name>\
                   <mwg-rs:Area stArea:x=\"0.3\" stArea:y=\"0.3\" stArea:w=\"0.1\" \
                   stArea:h=\"0.1\" stArea:unit=\"normalized\"/>";
        assert_eq!(names(&parse_mwg_regions(xml)), vec![Some("Good")]);
    }

    #[test]
    fn infinities_are_not_coordinates() {
        // Rust's f64 parser accepts these; Swift's `Double(_:)` does not, and
        // a region at infinity is not something the UI can crop to.
        assert_eq!(parse_double("inf"), None);
        assert_eq!(parse_double("NaN"), None);
        assert_eq!(parse_double("0.25"), Some(0.25));
    }

    #[test]
    fn utf16_packets_decode_through_the_fallback() {
        let text = "<digiKam:TagsList><rdf:Seq><rdf:li>Places/Iceland</rdf:li>\
                    </rdf:Seq></digiKam:TagsList>";
        let mut bytes = vec![0xFF, 0xFE];
        for unit in text.encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        assert_eq!(parse_xmp_bytes(&bytes).raw_tags, vec!["Places/Iceland"]);
    }

    #[test]
    fn a_non_xml_sidecar_parses_to_nothing_without_complaint() {
        let parsed = parse_xmp_bytes(b"this is not an XMP packet at all\n");
        assert_eq!(parsed, SwiftXmpParse::default());
    }
}
