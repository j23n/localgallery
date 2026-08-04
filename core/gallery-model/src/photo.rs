//! Rust mirrors of the app's currency types.
//!
//! These are not "inspired by" `PhotoFile` / `PhotoFolder` — they *are* those
//! types, down to which keys the encoder omits. The persisted `LibrarySnapshot`
//! is the contract (see [`crate::snapshot`]), and a snapshot the Swift side
//! cannot decode identically turns a warm relaunch into a full rescan.
//!
//! Everything Swift's hand-written `Codable` drops is dropped here too, and for
//! the same reason: [`PhotoFile::locality`] and [`PhotoFile::sidecar_status`]
//! are runtime state, not library content. They come back as
//! `local` / `absent` after a round trip, which the fixture proves on purpose.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::date::AppleDate;
use crate::file_url::{file_url_string, path_from_file_url};
use crate::stable_uuid;

/// A `Uuid` that serialises the way `Foundation.UUID` does: **uppercase**
/// hyphenated. The `uuid` crate's own serde impl is lowercase, and Swift's
/// `UUID(uuidString:)` accepts either — but the fixture pins uppercase, and a
/// wire format nobody can diff against is not a contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct StableId(pub Uuid);

impl StableId {
    /// The id Swift derives for a photo: `StableUUID.derive(url.standardized.path)`.
    ///
    /// The **on-disk** path spelling, not a normalized one. NFC and NFD names
    /// derive different ids and that is pinned by `stable_uuid_vectors.json`.
    pub fn for_photo(path: &str) -> Self {
        StableId(stable_uuid::derive(path))
    }

    /// `PhotoFolder.stableID` — the same derivation over a `folder:`-prefixed
    /// path, so a folder and a photo at the same path cannot collide.
    pub fn for_folder(path: &str) -> Self {
        StableId(stable_uuid::derive(&format!("folder:{path}")))
    }
}

impl std::fmt::Display for StableId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0.to_string().to_uppercase())
    }
}

impl Serialize for StableId {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for StableId {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        Uuid::parse_str(&raw)
            .map(StableId)
            .map_err(serde::de::Error::custom)
    }
}

/// A filesystem path that serialises as `URL.absoluteString`.
///
/// The in-memory form is the plain path — that is what the VFS takes and what
/// `stable_uuid` hashes. The percent-encoded `file://` spelling exists only on
/// the wire.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FileUrl(pub String);

impl FileUrl {
    /// Wrap a path.
    pub fn new(path: impl Into<String>) -> Self {
        FileUrl(path.into())
    }

    /// The path, for the VFS and for id derivation.
    pub fn path(&self) -> &str {
        &self.0
    }
}

impl Serialize for FileUrl {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&file_url_string(&self.0))
    }
}

impl<'de> Deserialize<'de> for FileUrl {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        path_from_file_url(&raw)
            .map(FileUrl)
            .ok_or_else(|| serde::de::Error::custom(format!("not a file URL: {raw}")))
    }
}

/// One `digiKam:TagsList` entry, split the way `HierarchicalTag(raw:)` splits it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HierarchicalTag {
    /// The raw `/`-separated path, e.g. `Places/Italy/Lazio/Rome`.
    #[serde(rename = "fullPath")]
    pub full_path: String,
    /// First segment, or `None` for a flat tag. Omitted from JSON when `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    /// Leaf segment.
    #[serde(rename = "displayName")]
    pub display_name: String,
}

impl HierarchicalTag {
    /// Split a raw tag path.
    ///
    /// Mirrors Swift's `raw.split(separator: "/")`, which **discards empty
    /// segments**: `"a//b"` has two parts, and a single-part result means a
    /// flat tag with no namespace. Each part is whitespace-trimmed, but
    /// `full_path` keeps the raw string.
    pub fn new(raw: &str) -> Self {
        let parts: Vec<&str> = raw
            .split('/')
            .filter(|s| !s.is_empty())
            .map(str::trim)
            .collect();
        if parts.len() > 1 {
            HierarchicalTag {
                full_path: raw.to_string(),
                namespace: Some(parts[0].to_string()),
                display_name: parts[parts.len() - 1].to_string(),
            }
        } else {
            HierarchicalTag {
                full_path: raw.to_string(),
                namespace: None,
                display_name: raw.to_string(),
            }
        }
    }
}

/// One MWG `mwg-rs:RegionInfo` entry. Coordinates are normalised 0…1, centre
/// origin top-left.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FaceRegion {
    /// `mwg-rs:Name`, absent for unnamed rectangles. Omitted when `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Centre x.
    #[serde(
        rename = "centerX",
        serialize_with = "crate::swift_json::serialize_f64"
    )]
    pub center_x: f64,
    /// Centre y.
    #[serde(
        rename = "centerY",
        serialize_with = "crate::swift_json::serialize_f64"
    )]
    pub center_y: f64,
    /// Full width.
    #[serde(serialize_with = "crate::swift_json::serialize_f64")]
    pub width: f64,
    /// Full height.
    #[serde(serialize_with = "crate::swift_json::serialize_f64")]
    pub height: f64,
}

/// Where a photo's bytes live. Runtime state — **never persisted**.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PhotoLocality {
    /// Readable from disk right now.
    #[default]
    Local,
    /// Provider-backed. `downloaded: false` is the placeholder state.
    Remote {
        /// Whether the bytes have been materialised.
        downloaded: bool,
    },
}

impl PhotoLocality {
    /// The spelling the scanner fixture records (`local` /
    /// `remote(downloaded: false)`).
    pub fn describe(self) -> String {
        match self {
            PhotoLocality::Local => "local".to_string(),
            PhotoLocality::Remote { downloaded } => format!("remote(downloaded: {downloaded})"),
        }
    }
}

/// Whether a parsed copy of the photo's sidecar is cached. Runtime state —
/// **never persisted**. The scanner only ever emits `Absent`; the sidecar sync
/// pass is what promotes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SidecarStatus {
    /// No parsed sidecar.
    #[default]
    Absent,
    /// A parsed sidecar is cached.
    Cached,
}

/// One photo or video.
///
/// Field order below matches `CodingKeys`; the JSON key order does not matter
/// (see the fixture README) but the *key set* does, and every `Option` here
/// omits itself when empty exactly like `encodeIfPresent`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhotoFile {
    /// Derived from the path; stable across rescans.
    pub id: StableId,
    /// Absolute path.
    pub url: FileUrl,
    /// Basename without the last extension — **lowercased for a standalone
    /// video** (see [`crate::photo::PhotoFile`] callers and fixture landmine 22).
    pub filename: String,
    /// Size in bytes.
    #[serde(rename = "fileSize")]
    pub file_size: i64,
    /// Capture date, or the filesystem fallback.
    #[serde(rename = "dateTaken", skip_serializing_if = "Option::is_none")]
    pub date_taken: Option<AppleDate>,
    /// Whether `date_taken` came from embedded metadata. Only enrichment sets
    /// this; the scanner always leaves it false.
    #[serde(rename = "dateFromMetadata", default)]
    pub date_from_metadata: bool,
    /// Whether this row is a video.
    #[serde(rename = "isVideo", default)]
    pub is_video: bool,
    /// The paired live-photo movie, when one sits next to it.
    #[serde(rename = "livePhotoVideoURL", skip_serializing_if = "Option::is_none")]
    pub live_photo_video_url: Option<FileUrl>,
    /// Tags read from `digiKam:TagsList`.
    #[serde(rename = "hierarchicalTags", default)]
    pub hierarchical_tags: Vec<HierarchicalTag>,
    /// Uppercase ISO 3166-1 alpha-2.
    #[serde(rename = "countryCode", skip_serializing_if = "Option::is_none")]
    pub country_code: Option<String>,
    /// The file's mtime as of the last successful enrichment; `None` = never.
    #[serde(rename = "enrichedFileDate", skip_serializing_if = "Option::is_none")]
    pub enriched_file_date: Option<AppleDate>,
    /// The file's mtime as of the last scan. Half of the change signal.
    #[serde(
        rename = "fileModificationDate",
        skip_serializing_if = "Option::is_none"
    )]
    pub file_modification_date: Option<AppleDate>,
    /// Latitude, sign already applied from the GPS ref.
    #[serde(
        rename = "gpsLatitude",
        skip_serializing_if = "Option::is_none",
        serialize_with = "crate::swift_json::serialize_opt_f64"
    )]
    pub gps_latitude: Option<f64>,
    /// Longitude, sign already applied from the GPS ref.
    #[serde(
        rename = "gpsLongitude",
        skip_serializing_if = "Option::is_none",
        serialize_with = "crate::swift_json::serialize_opt_f64"
    )]
    pub gps_longitude: Option<f64>,
    /// MWG regions.
    #[serde(rename = "faceRegions", default)]
    pub face_regions: Vec<FaceRegion>,

    /// Not in `CodingKeys`: dropped on save, `Local` after a load.
    #[serde(skip, default)]
    pub locality: PhotoLocality,
    /// Not in `CodingKeys`: dropped on save, `Absent` after a load.
    #[serde(skip, default)]
    pub sidecar_status: SidecarStatus,
}

impl PhotoFile {
    /// A photo with only the always-present fields set, matching Swift's
    /// memberwise defaults.
    pub fn new(path: &str, filename: impl Into<String>, file_size: i64) -> Self {
        PhotoFile {
            id: StableId::for_photo(path),
            url: FileUrl::new(path),
            filename: filename.into(),
            file_size,
            date_taken: None,
            date_from_metadata: false,
            is_video: false,
            live_photo_video_url: None,
            hierarchical_tags: Vec::new(),
            country_code: None,
            enriched_file_date: None,
            file_modification_date: None,
            gps_latitude: None,
            gps_longitude: None,
            face_regions: Vec::new(),
            locality: PhotoLocality::Local,
            sidecar_status: SidecarStatus::Absent,
        }
    }

    /// The photo's path.
    pub fn path(&self) -> &str {
        self.url.path()
    }
}

/// A folder node. `photos` is this folder's own; `total_photo_count` is
/// recursive.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhotoFolder {
    /// Derived from `"folder:" + path`.
    pub id: StableId,
    /// Absolute path.
    pub url: FileUrl,
    /// Last path component.
    pub name: String,
    /// Children, ascending by `localizedStandardCompare` of their names.
    pub subfolders: Vec<PhotoFolder>,
    /// This folder's own photos, in listing order (unspecified).
    pub photos: Vec<PhotoFile>,
    /// `photos.first`, else the first subfolder that has one.
    #[serde(rename = "coverPhotoURL", skip_serializing_if = "Option::is_none")]
    pub cover_photo_url: Option<FileUrl>,
    /// Recursive photo count.
    #[serde(rename = "totalPhotoCount")]
    pub total_photo_count: i64,
    /// Directory mtime.
    #[serde(rename = "dateModified", skip_serializing_if = "Option::is_none")]
    pub date_modified: Option<AppleDate>,
    /// Directory birth time.
    #[serde(rename = "dateCreated", skip_serializing_if = "Option::is_none")]
    pub date_created: Option<AppleDate>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuids_serialise_uppercase() {
        let id = StableId::for_photo("/fixtures/PhotoLibrary/2021/IMG_0001.jpg");
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(
            json,
            format!("\"{}\"", json.trim_matches('"').to_uppercase())
        );
        assert_eq!(json.len(), 38);
        // …and decode back to the same value from either spelling.
        let lower: StableId = serde_json::from_str(&json.to_lowercase()).unwrap();
        assert_eq!(lower, id);
    }

    #[test]
    fn folder_ids_are_namespaced_away_from_photo_ids() {
        assert_ne!(StableId::for_photo("/a/b"), StableId::for_folder("/a/b"));
    }

    #[test]
    fn urls_serialise_percent_encoded_and_decode_back_to_paths() {
        let url = FileUrl::new("/a/spaces and (parens).jpg");
        assert_eq!(
            serde_json::to_string(&url).unwrap(),
            "\"file:///a/spaces%20and%20(parens).jpg\""
        );
        let back: FileUrl =
            serde_json::from_str("\"file:///a/spaces%20and%20(parens).jpg\"").unwrap();
        assert_eq!(back, url);
    }

    #[test]
    fn a_bare_photo_encodes_only_the_non_optional_keys() {
        let photo = PhotoFile::new("/fixtures/PhotoLibrary/2021/IMG_0002.jpg", "IMG_0002", 5121);
        let value: serde_json::Value = serde_json::to_value(&photo).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            vec![
                "dateFromMetadata",
                "faceRegions",
                "fileSize",
                "filename",
                "hierarchicalTags",
                "id",
                "isVideo",
                "url",
            ],
            "nil optionals must be OMITTED, not null"
        );
    }

    #[test]
    fn runtime_only_state_never_reaches_the_wire() {
        let mut photo = PhotoFile::new("/a/b.jpg", "b", 1);
        photo.locality = PhotoLocality::Remote { downloaded: false };
        photo.sidecar_status = SidecarStatus::Cached;
        let json = serde_json::to_string(&photo).unwrap();
        assert!(!json.contains("locality"));
        assert!(!json.contains("sidecar"));

        let back: PhotoFile = serde_json::from_str(&json).unwrap();
        assert_eq!(back.locality, PhotoLocality::Local);
        assert_eq!(back.sidecar_status, SidecarStatus::Absent);
    }

    #[test]
    fn hierarchical_tags_split_like_swift() {
        let nested = HierarchicalTag::new("Places/Italy/Lazio/Rome");
        assert_eq!(nested.namespace.as_deref(), Some("Places"));
        assert_eq!(nested.display_name, "Rome");

        let flat = HierarchicalTag::new("flat-tag");
        assert_eq!(flat.namespace, None);
        assert_eq!(flat.display_name, "flat-tag");
        // A flat tag omits `namespace` entirely.
        let json = serde_json::to_string(&flat).unwrap();
        assert!(!json.contains("namespace"), "{json}");

        // Swift's `split(separator:)` drops empty segments, so a doubled
        // slash does not manufacture an empty namespace.
        let doubled = HierarchicalTag::new("People//Alice");
        assert_eq!(doubled.namespace.as_deref(), Some("People"));
        assert_eq!(doubled.display_name, "Alice");
        assert_eq!(doubled.full_path, "People//Alice");
    }

    #[test]
    fn unnamed_regions_omit_the_name_key() {
        let region = FaceRegion {
            name: None,
            center_x: 0.6,
            center_y: 0.4,
            width: 0.05,
            height: 0.05,
        };
        let json = serde_json::to_string(&region).unwrap();
        assert!(!json.contains("name"), "{json}");
    }
}
