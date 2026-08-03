//! What the iOS app will actually see.
//!
//! `LocalGallery/Services/MetadataReader.swift` does not use an XML parser: it
//! scans the sidecar text for literal `<digiKam:TagsList>`, `<rdf:li>`,
//! `<mwg-rs:Area` and `<photo-tools:CountryCode>` markers. A sidecar can be
//! perfectly valid XMP and still be invisible to it. The functions below are a
//! direct port of that Swift logic, so these tests fail the moment the writer
//! emits a shape the app cannot read.
//!
//! Keep them in sync with `parseXMPBytes` / `parseMWGRegions`.

mod common;

use common::fixture;
use gallery_meta::{
    apply_faces, apply_tags, Area, FaceRegionWrite, FaceWriteRequest, TagWriteRequest,
};

// ---------------------------------------------------------------------------
// Port of MetadataReader.parseXMPBytes / parseMWGRegions
// ---------------------------------------------------------------------------

#[derive(Debug, PartialEq)]
struct SwiftFaceRegion {
    name: Option<String>,
    center_x: f64,
    center_y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, PartialEq)]
struct SwiftParse {
    raw_tags: Vec<String>,
    country_code: Option<String>,
    face_regions: Vec<SwiftFaceRegion>,
}

fn parse_xmp_bytes(data: &[u8]) -> SwiftParse {
    let xml = String::from_utf8_lossy(data).to_string();

    let mut raw_tags = Vec::new();
    let start = xml
        .find("<digiKam:TagsList>")
        .map(|i| i + "<digiKam:TagsList>".len())
        .or_else(|| {
            xml.find("<digiKam:TagsList ")
                .map(|i| i + "<digiKam:TagsList ".len())
        });
    if let Some(start) = start {
        if let Some(end_rel) = xml[start..].find("</digiKam:TagsList>") {
            let block = &xml[start..start + end_rel];
            let mut cursor = 0;
            while let Some(li_rel) = block[cursor..].find("<rdf:li>") {
                let li_start = cursor + li_rel + "<rdf:li>".len();
                let Some(li_end_rel) = block[li_start..].find("</rdf:li>") else {
                    break;
                };
                let value = block[li_start..li_start + li_end_rel].trim();
                if !value.is_empty() {
                    raw_tags.push(value.to_string());
                }
                cursor = li_start + li_end_rel + "</rdf:li>".len();
            }
        }
    }

    let mut country_code = None;
    for prefix in ["photo-tools:CountryCode", "phototools:CountryCode"] {
        let open = format!("<{prefix}>");
        let close = format!("</{prefix}>");
        if let Some(i) = xml.find(&open) {
            let from = i + open.len();
            if let Some(j) = xml[from..].find(&close) {
                let value = xml[from..from + j].trim();
                if !value.is_empty() {
                    country_code = Some(value.to_uppercase());
                    break;
                }
            }
        }
    }

    SwiftParse {
        raw_tags,
        country_code,
        face_regions: parse_mwg_regions(&xml),
    }
}

fn parse_mwg_regions(xml: &str) -> Vec<SwiftFaceRegion> {
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
            attrs.push_str(&xml[open_end..open_end + close_rel]);
            search = open_end + close_rel + "</mwg-rs:Area>".len();
        } else {
            search = open_end;
            continue;
        }

        if let Some(unit) = read_field(&attrs, "stArea:unit") {
            if unit.to_lowercase() != "normalized" {
                continue;
            }
        }
        let (Some(x), Some(y), Some(w), Some(h)) = (
            read_field(&attrs, "stArea:x").and_then(|v| v.parse::<f64>().ok()),
            read_field(&attrs, "stArea:y").and_then(|v| v.parse::<f64>().ok()),
            read_field(&attrs, "stArea:w").and_then(|v| v.parse::<f64>().ok()),
            read_field(&attrs, "stArea:h").and_then(|v| v.parse::<f64>().ok()),
        ) else {
            continue;
        };

        let back = area_start.saturating_sub(2_000);
        regions.push(SwiftFaceRegion {
            name: last_mwg_name(&xml[back..area_start]),
            center_x: x,
            center_y: y,
            width: w,
            height: h,
        });
    }
    regions
}

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn request(tags: &[&str]) -> TagWriteRequest {
    TagWriteRequest::new(
        tags.iter().map(|s| s.to_string()),
        "mobileclip-s2-2026.1",
        "2026-08-03T10:00:00Z",
    )
}

#[test]
fn the_app_reads_hierarchical_paths_out_of_a_sidecar_we_created() {
    let bytes = apply_tags(
        None,
        &request(&["Objects/Animal/Dog", "Scenes/Nature/Forest"]),
    )
    .unwrap()
    .bytes;
    let parsed = parse_xmp_bytes(&bytes);
    assert_eq!(
        parsed.raw_tags,
        vec!["Objects/Animal/Dog", "Scenes/Nature/Forest"]
    );
}

#[test]
fn the_app_reads_our_tags_appended_to_a_photo_tools_sidecar() {
    let original = fixture("phototools.jpg.xmp");
    let before = parse_xmp_bytes(&original);
    assert_eq!(before.country_code.as_deref(), Some("IT"));

    let bytes = apply_tags(Some(&original), &request(&["Objects/Animal/Dog"]))
        .unwrap()
        .bytes;
    let after = parse_xmp_bytes(&bytes);

    // Everything it saw before is still there, plus ours.
    for tag in &before.raw_tags {
        assert!(after.raw_tags.contains(tag), "lost {tag}");
    }
    assert!(after.raw_tags.contains(&"Objects/Animal/Dog".to_string()));
    assert_eq!(after.country_code, before.country_code);
}

#[test]
fn face_regions_still_parse_after_a_write() {
    let original = fixture("digikam.jpg.xmp");
    let before = parse_mwg_regions(&String::from_utf8_lossy(&original));
    assert_eq!(before.len(), 2);
    assert!((before[0].center_x - 0.4).abs() < 1e-9);
    assert!((before[1].center_x - 0.7).abs() < 1e-9);

    let bytes = apply_tags(Some(&original), &request(&["Objects/Animal/Dog"]))
        .unwrap()
        .bytes;
    let after = parse_mwg_regions(&String::from_utf8_lossy(&bytes));
    assert_eq!(after, before, "the app would now see different faces");
}

#[test]
fn region_names_are_already_wrong_for_exiftool_ordered_regions() {
    // Pre-existing app bug, captured here so the next person does not blame the
    // writer for it. `MetadataReader.parseMWGRegions` finds a region's name by
    // scanning *backwards* from `<mwg-rs:Area`, which assumes digiKam's
    // element order (Name, Type, Area). exiftool sorts struct fields
    // alphabetically (Area, Name, Type), so the lookback misses the region's
    // own name and picks up the previous region's instead: the first region
    // comes out unnamed and every later one is labelled with its predecessor.
    //
    // gallery-meta's own reader gets this right (`roundtrip.rs`
    // `digikam_fixture_reads_back_people_and_regions`); the Swift side does
    // not, and this is unchanged by anything we write.
    let regions = parse_mwg_regions(&String::from_utf8_lossy(&fixture("digikam.jpg.xmp")));
    assert_eq!(regions[0].name, None, "first region: no preceding Name");
    assert_eq!(
        regions[1].name.as_deref(),
        Some("Alice"),
        "second region wears the first region's name"
    );
}

#[test]
fn people_entries_stay_visible_to_the_app_alongside_our_tags() {
    let bytes = apply_tags(
        Some(&fixture("digikam.jpg.xmp")),
        &request(&["Objects/Animal/Dog"]),
    )
    .unwrap()
    .bytes;
    let parsed = parse_xmp_bytes(&bytes);
    assert_eq!(
        parsed.raw_tags,
        vec![
            "People/Alice",
            "People/Bob",
            "Events/Birthday",
            "Objects/Animal/Dog",
        ]
    );
}

// ---------------------------------------------------------------------------
// The face writer
// ---------------------------------------------------------------------------

fn face_region(name: &str, x: f64, y: f64, w: f64, h: f64) -> FaceRegionWrite {
    FaceRegionWrite {
        name: name.to_string(),
        area: Area::new(x, y, w, h),
    }
}

fn face_request(regions: Vec<FaceRegionWrite>) -> FaceWriteRequest {
    FaceWriteRequest::new(regions, "buffalo_sc-2026.1", "2026-08-03T10:00:00Z")
        .with_image_size(4032, 3024)
}

#[test]
fn the_app_reads_back_the_regions_we_write_with_the_right_names_on_them() {
    // The whole reason the writer emits Name, Type, Area rather than exiftool's
    // alphabetical Area, Name, Type: `parseMWGRegions` finds a region's name by
    // scanning backwards from `<mwg-rs:Area`, so with the field order reversed
    // every name lands on the wrong box (see the test below this one).
    let bytes = apply_faces(
        None,
        &face_request(vec![
            face_region("Alice", 0.4, 0.35, 0.12, 0.16),
            face_region("Bob", 0.7, 0.3, 0.1, 0.14),
        ]),
    )
    .unwrap()
    .bytes;

    let regions = parse_mwg_regions(&String::from_utf8_lossy(&bytes));
    assert_eq!(regions.len(), 2);
    assert_eq!(regions[0].name.as_deref(), Some("Alice"));
    assert!((regions[0].center_x - 0.4).abs() < 1e-9);
    assert!((regions[0].width - 0.12).abs() < 1e-9);
    assert_eq!(regions[1].name.as_deref(), Some("Bob"));
    assert!((regions[1].center_y - 0.3).abs() < 1e-9);

    // And the People keywords land where the app's tag scan looks for them.
    let parsed = parse_xmp_bytes(&bytes);
    assert_eq!(parsed.raw_tags, vec!["People/Alice", "People/Bob"]);
}

#[test]
fn our_region_appended_to_a_digikam_file_reads_correctly_even_though_theirs_does_not() {
    // The fixture is exiftool-ordered, so the app mis-attributes *its* names
    // (documented above). Ours is written digiKam-style and is unaffected —
    // the lookback finds the `<mwg-rs:Name>` immediately before our Area.
    let bytes = apply_faces(
        Some(&fixture("digikam.jpg.xmp")),
        &face_request(vec![face_region("Carol", 0.2, 0.8, 0.1, 0.1)]),
    )
    .unwrap()
    .bytes;

    let regions = parse_mwg_regions(&String::from_utf8_lossy(&bytes));
    assert_eq!(regions.len(), 3);
    assert_eq!(
        regions[2].name.as_deref(),
        Some("Carol"),
        "our region must carry its own name"
    );
    assert!((regions[2].center_x - 0.2).abs() < 1e-9);
}

#[test]
fn a_face_write_leaves_the_apps_view_of_foreign_regions_exactly_as_it_was() {
    let original = fixture("digikam.jpg.xmp");
    let before = parse_mwg_regions(&String::from_utf8_lossy(&original));
    let bytes = apply_faces(
        Some(&original),
        &face_request(vec![face_region("Carol", 0.2, 0.8, 0.1, 0.1)]),
    )
    .unwrap()
    .bytes;
    let after = parse_mwg_regions(&String::from_utf8_lossy(&bytes));
    assert_eq!(&after[..before.len()], &before[..]);
}

#[test]
fn the_apps_literal_prefix_scan_is_blind_to_rebound_prefixes() {
    // Documented limitation, not a regression: `MetadataReader` looks for the
    // literal string `<digiKam:TagsList>`, so a sidecar that binds the digiKam
    // URI to `dk:` is invisible to it — before *and* after we write. The writer
    // reuses the file's own prefix rather than adding a second one, so this
    // stays exactly as bad as it already was and no worse.
    let original = fixture("weird_rdf.jpg.xmp");
    assert!(parse_xmp_bytes(&original).raw_tags.is_empty());

    let bytes = apply_tags(Some(&original), &request(&["Objects/Animal/Dog"]))
        .unwrap()
        .bytes;
    assert!(parse_xmp_bytes(&bytes).raw_tags.is_empty());
    // The region parser keys off `mwg-rs:`/`stArea:` and this file rebinds
    // those too, so it sees nothing there either — again, unchanged by us.
    assert!(parse_mwg_regions(&String::from_utf8_lossy(&bytes)).is_empty());
}
