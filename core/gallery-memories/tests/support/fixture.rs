//! Shared fixture plumbing for the two memories conformance suites.
//!
//! Compiled into both `memory_engine_conformance.rs` and
//! `scheduled_memories_conformance.rs` with `#[path]`, because Cargo gives
//! integration tests no other way to share code without inventing a crate for
//! it.

#![allow(dead_code)]

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use gallery_memories::{Contact, GenerationInputs, LeafFolder, Memory, PersonLink, UtcOffset};
use gallery_model::{AppleDate, CivilDateTime, HierarchicalTag, PhotoFile, StableId};
use serde::Deserialize;

pub fn read_fixture<T: for<'de> Deserialize<'de>>(name: &str) -> T {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "memories-conformance",
        name,
    ]
    .iter()
    .collect();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` — the fixtures' only date spelling, parsed
/// with `str::parse` rather than through serde's number path (the fixture
/// README records serde_json rounding some decimals one ULP low).
pub fn parse_utc(s: &str) -> AppleDate {
    assert_eq!(s.len(), 24, "unexpected date spelling {s}");
    let n = |a: usize, b: usize| -> i64 { s[a..b].parse().unwrap() };
    let civil = CivilDateTime {
        year: n(0, 4) as i32,
        month: n(5, 7) as u32,
        day: n(8, 10) as u32,
        hour: n(11, 13) as u32,
        minute: n(14, 16) as u32,
        second: n(17, 19) as u32,
    };
    let millis: f64 = s[20..23].parse().unwrap();
    AppleDate::from_unix_secs_f64(civil.as_naive_unix_secs() as f64 + millis / 1000.0)
}

/// The engine fixture names IANA zones; this crate takes a fixed UTC offset.
/// Both zones `memory_engine.json` uses are fixed-offset, so the mapping is
/// exact.
///
/// `scheduled_memories.json` does not go through here: since it grew a scenario
/// whose offset changes *inside* the horizon it records the offsets Foundation
/// resolved as fields of its own, which is the only honest way for a crate with
/// no tz database to read one.
pub fn offset_for(zone: &str) -> UtcOffset {
    match zone {
        "UTC" => UtcOffset::UTC,
        "Asia/Tokyo" => UtcOffset::hours(9),
        other => panic!("no fixed offset recorded for {other}"),
    }
}

// ---------------------------------------------------------------------------
// Input records
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct ConfPhoto {
    pub path: String,
    pub id: String,
    pub filename: String,
    #[serde(rename = "dateTaken")]
    pub date_taken: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(rename = "countryCode")]
    pub country_code: Option<String>,
    #[serde(rename = "gpsLatitude")]
    pub gps_latitude: Option<f64>,
    #[serde(rename = "gpsLongitude")]
    pub gps_longitude: Option<f64>,
    #[serde(rename = "isVideo")]
    pub is_video: bool,
}

impl ConfPhoto {
    pub fn to_photo_file(&self) -> PhotoFile {
        let mut p = PhotoFile::new(&self.path, self.filename.clone(), 0);
        assert_eq!(
            p.id.to_string(),
            self.id,
            "{}: the fixture's id is not what StableId derives from its path",
            self.path
        );
        p.date_taken = self.date_taken.as_deref().map(parse_utc);
        p.hierarchical_tags = self.tags.iter().map(|t| HierarchicalTag::new(t)).collect();
        p.country_code = self.country_code.clone();
        p.gps_latitude = self.gps_latitude;
        p.gps_longitude = self.gps_longitude;
        p.is_video = self.is_video;
        p
    }
}

#[derive(Deserialize)]
pub struct ConfFolder {
    pub path: String,
    pub name: String,
    #[serde(rename = "photoPaths")]
    pub photo_paths: Vec<String>,
}

impl ConfFolder {
    pub fn to_leaf_folder(&self) -> LeafFolder {
        LeafFolder {
            id: StableId::for_folder(&self.path),
            name: self.name.clone(),
            photo_ids: self
                .photo_paths
                .iter()
                .map(|p| StableId::for_photo(p))
                .collect(),
        }
    }
}

#[derive(Deserialize)]
pub struct ConfContact {
    pub id: String,
    #[serde(rename = "givenName")]
    pub given_name: String,
    #[serde(rename = "familyName")]
    pub family_name: String,
    #[serde(rename = "birthdayMonth")]
    pub birthday_month: Option<u32>,
    #[serde(rename = "birthdayDay")]
    pub birthday_day: Option<u32>,
}

impl ConfContact {
    pub fn to_contact(&self) -> Contact {
        Contact {
            id: self.id.clone(),
            given_name: self.given_name.clone(),
            family_name: self.family_name.clone(),
            birthday_month: self.birthday_month,
            birthday_day: self.birthday_day,
        }
    }
}

#[derive(Deserialize)]
pub struct ConfLink {
    #[serde(rename = "personPath")]
    pub person_path: String,
    pub kind: String,
    #[serde(rename = "contactID")]
    pub contact_id: Option<String>,
}

#[derive(Deserialize)]
pub struct ConfDateEntry {
    pub key: String,
    pub date: String,
}

pub fn links_map(links: &[ConfLink]) -> HashMap<String, PersonLink> {
    links
        .iter()
        .map(|l| {
            let link = match l.kind.as_str() {
                "manual" => PersonLink::Manual(l.contact_id.clone().expect("manual needs an id")),
                "disabled" => PersonLink::Disabled,
                other => panic!("unknown link kind {other}"),
            };
            (l.person_path.clone(), link)
        })
        .collect()
}

pub fn date_map(entries: &[ConfDateEntry]) -> HashMap<String, AppleDate> {
    entries
        .iter()
        .map(|e| (e.key.clone(), parse_utc(&e.date)))
        .collect()
}

pub fn string_set(values: &[String]) -> HashSet<String> {
    values.iter().cloned().collect()
}

// ---------------------------------------------------------------------------
// Output record — the comparison unit
// ---------------------------------------------------------------------------

/// A `Memory` in the fixture's shape. Compared field by field: Swift's `Memory`
/// is `Equatable` by **id alone**, so two memories with different photo sets
/// compare equal there and nothing in this suite may rely on it.
#[derive(Deserialize, PartialEq, Debug, Clone)]
pub struct ConfMemory {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub title: String,
    pub subtitle: Option<String>,
    #[serde(rename = "photoIDs")]
    pub photo_ids: Vec<String>,
    #[serde(rename = "photoCount")]
    pub photo_count: usize,
    #[serde(rename = "coverPhotoID")]
    pub cover_photo_id: String,
    pub score: f64,
    #[serde(rename = "yearsAgo")]
    pub years_ago: Option<i32>,
    #[serde(rename = "personName")]
    pub person_name: Option<String>,
    #[serde(rename = "dateRangeStart")]
    pub date_range_start: Option<String>,
    #[serde(rename = "dateRangeEnd")]
    pub date_range_end: Option<String>,
}

impl ConfMemory {
    pub fn of(m: &Memory) -> Self {
        ConfMemory {
            id: m.id.clone(),
            kind: m.kind.raw_value().to_string(),
            title: m.title.clone(),
            subtitle: m.subtitle.clone(),
            photo_ids: m.photo_ids.iter().map(StableId::to_string).collect(),
            photo_count: m.photo_ids.len(),
            cover_photo_id: m.cover_photo_id.to_string(),
            score: m.score,
            years_ago: m.years_ago,
            person_name: m.person_name.clone(),
            date_range_start: m.date_range.map(|(a, _)| a.to_utc_string()),
            date_range_end: m.date_range.map(|(_, b)| b.to_utc_string()),
        }
    }
}

/// Build a `GenerationInputs` from the pieces every scenario carries.
#[allow(clippy::too_many_arguments)]
pub fn inputs_from(
    photos: &[ConfPhoto],
    folders: &[ConfFolder],
    contacts: &[ConfContact],
    links: &[ConfLink],
    birthdays_enabled: bool,
    me_person_path: &str,
    hidden_people: &[String],
    now: &str,
    time_zone: UtcOffset,
    seed: &str,
) -> GenerationInputs {
    let contacts: Vec<Contact> = contacts.iter().map(ConfContact::to_contact).collect();
    let photos: Vec<_> = photos.iter().map(ConfPhoto::to_photo_file).collect();
    GenerationInputs {
        // No fixture scenario has cloud placeholders, so the whole table is the
        // scored pool — and none needs per-photo offsets: every scenario photo
        // sits near midday, so the ±1 h a DST zone would contribute cannot move
        // one onto another day. The horizon offsets are the caller's to fill;
        // those a scenario can observe.
        ladder_photo_count: photos.len(),
        photo_time_zone_offsets: Vec::new(),
        horizon_time_zone_offsets: Vec::new(),
        photos,
        leaf_folders: folders.iter().map(ConfFolder::to_leaf_folder).collect(),
        contacts,
        person_contact_links: links_map(links),
        birthdays_enabled,
        me_person_path: me_person_path.to_string(),
        hidden_people: string_set(hidden_people),
        now: parse_utc(now),
        time_zone,
        seed: seed.to_string(),
        seen_memory_ids: HashMap::new(),
        surfaced_clusters: HashMap::new(),
    }
}
