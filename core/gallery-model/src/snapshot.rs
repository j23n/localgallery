//! The persisted library, and the versioned envelope it lives in.
//!
//! Wire compatibility with `JSONDiskCache<LibrarySnapshot>` is the whole point
//! of this module. The failure mode of getting it wrong is quiet: the app
//! starts, finds a snapshot it cannot decode, evicts it, and does a full
//! rescan — minutes of provider round-trips, on every launch, with no error
//! anywhere. `core/fixtures/scan-conformance/library_snapshot_v20.json` is a
//! real file off the real save path, and the round-trip test over it is the
//! only thing standing between a refactor and that outcome.

use serde::{Deserialize, Serialize};

use crate::date::AppleDate;
use crate::photo::{FileUrl, PhotoFile, PhotoFolder, StableId};

/// `LibrarySnapshot.version`. A mismatch **evicts** the file (and the memories
/// cache with it), so this number is a rescan for every install — bump it only
/// when the payload genuinely cannot be read.
pub const LIBRARY_SNAPSHOT_VERSION: i64 = 20;

/// What `JSONDiskCache` writes: `{"version": Int, "value": …}`.
///
/// Load order matters. Swift decodes `version` **on its own first**
/// ([`probe_version`]) so that a payload change — which makes the full decode
/// throw — still reports as a version mismatch rather than a corrupt file. The
/// two outcomes are treated identically today (both evict), but only one of
/// them is a bug.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope<T> {
    /// Schema version of `value`.
    pub version: i64,
    /// The payload.
    pub value: T,
}

/// The persisted result of the last scan.
///
/// `sidecar_manifest` is the field `_plans/06` Finding 2 adds: **optional, no
/// version bump**. A v20 file written before it existed decodes with `None`,
/// pays one legacy re-probe, and persists it from then on. Bumping instead
/// would force a full rescan on every install to save a single pass.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LibrarySnapshot {
    /// The folder tree.
    #[serde(rename = "rootFolder")]
    pub root_folder: PhotoFolder,
    /// Every photo, flat.
    #[serde(rename = "allPhotos")]
    pub all_photos: Vec<PhotoFile>,
    /// Sidecar rows from the same scan. Absent in files written before the
    /// field existed; omitted on write when `None`, so the core does not
    /// invent a key an older Swift build would ignore anyway.
    #[serde(
        rename = "sidecarManifest",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub sidecar_manifest: Option<Vec<SidecarCandidate>>,
}

/// One row of the sidecar manifest: which `.xmp` belongs to which photo, and
/// what version of it the scan saw.
///
/// # Coordination note for the Swift side
///
/// `FolderScanner.SidecarCandidate` is not `Codable` today. When it becomes
/// one, `DownloadStatus` must gain `String` raw values — a Swift enum without
/// them synthesises `{"local": {}}`, not `"local"`, and this encoder emits the
/// string.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SidecarCandidate {
    /// The photo the sidecar belongs to.
    #[serde(rename = "photoID")]
    pub photo_id: StableId,
    /// Path of the `.xmp`.
    #[serde(rename = "sidecarURL")]
    pub sidecar_url: FileUrl,
    /// The sidecar's identity at scan time.
    #[serde(rename = "currentVersion")]
    pub current_version: ContentVersion,
    /// Whether the sidecar's own bytes are present.
    #[serde(rename = "downloadStatus")]
    pub download_status: DownloadStatus,
}

/// How a file's content is identified without reading it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ContentVersion {
    /// Provider-vended identifier (`fileContentIdentifierKey`). A `String`
    /// here where Swift has an `Int64`, because SAF and every non-Apple
    /// provider vend opaque tokens; the bridge stringifies.
    #[serde(rename = "contentIdentifier", skip_serializing_if = "Option::is_none")]
    pub content_identifier: Option<String>,
    /// Modification date, the fallback identity.
    #[serde(rename = "modificationDate", skip_serializing_if = "Option::is_none")]
    pub modification_date: Option<AppleDate>,
    /// Size in bytes, the other half of the fallback.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,
}

impl ContentVersion {
    /// Nothing known about this file's identity.
    pub fn is_empty(&self) -> bool {
        self.content_identifier.is_none() && self.modification_date.is_none() && self.size.is_none()
    }

    /// `FileProviderDetector.ContentVersion.sameContent`, verbatim: identifiers
    /// win when **both** sides have one; `(mtime, size)` decides when neither
    /// does; mixed presence is "different", because one side knows something
    /// the other cannot confirm.
    pub fn same_content(lhs: &ContentVersion, rhs: &ContentVersion) -> bool {
        match (&lhs.content_identifier, &rhs.content_identifier) {
            (Some(l), Some(r)) => l == r,
            (None, None) => lhs.modification_date == rhs.modification_date && lhs.size == rhs.size,
            _ => false,
        }
    }
}

/// Whether a provider-backed file's bytes are here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DownloadStatus {
    /// Bytes present.
    #[default]
    Local,
    /// Listing entry only.
    Placeholder,
    /// Fetch in flight.
    Downloading,
    /// Present but known out of date.
    Stale,
}

impl DownloadStatus {
    /// The spelling the scanner fixture records.
    pub fn describe(self) -> &'static str {
        match self {
            DownloadStatus::Local => "local",
            DownloadStatus::Placeholder => "placeholder",
            DownloadStatus::Downloading => "downloading",
            DownloadStatus::Stale => "stale",
        }
    }
}

/// Why a snapshot could not be loaded.
#[derive(Debug, Clone, PartialEq)]
pub enum SnapshotError {
    /// The file is not JSON, or has no `version`.
    Corrupt(String),
    /// The `version` is not one this build understands.
    VersionMismatch {
        /// What the file claims.
        found: i64,
        /// What this build writes.
        expected: i64,
    },
    /// The version matched but the payload did not decode.
    Payload(String),
}

impl std::fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SnapshotError::Corrupt(m) => write!(f, "corrupt snapshot: {m}"),
            SnapshotError::VersionMismatch { found, expected } => {
                write!(f, "snapshot version {found}, expected {expected}")
            }
            SnapshotError::Payload(m) => write!(f, "snapshot payload did not decode: {m}"),
        }
    }
}

impl std::error::Error for SnapshotError {}

#[derive(Deserialize)]
struct VersionProbe {
    version: i64,
}

/// Read `version` without touching the payload.
pub fn probe_version(bytes: &[u8]) -> Result<i64, SnapshotError> {
    serde_json::from_slice::<VersionProbe>(bytes)
        .map(|p| p.version)
        .map_err(|e| SnapshotError::Corrupt(e.to_string()))
}

/// Decode a snapshot file, version-checking first.
///
/// Unknown keys inside the payload are ignored, so a snapshot written by a
/// *newer* build with the same version number still loads — which is what makes
/// adding an optional field cheap.
pub fn load(bytes: &[u8]) -> Result<LibrarySnapshot, SnapshotError> {
    let version = probe_version(bytes)?;
    if version != LIBRARY_SNAPSHOT_VERSION {
        return Err(SnapshotError::VersionMismatch {
            found: version,
            expected: LIBRARY_SNAPSHOT_VERSION,
        });
    }
    serde_json::from_slice::<Envelope<LibrarySnapshot>>(bytes)
        .map(|e| e.value)
        .map_err(|e| SnapshotError::Payload(e.to_string()))
}

/// Encode a snapshot in the current version's envelope.
pub fn save(snapshot: &LibrarySnapshot) -> Result<Vec<u8>, SnapshotError> {
    serde_json::to_vec(&Envelope {
        version: LIBRARY_SNAPSHOT_VERSION,
        value: snapshot,
    })
    .map_err(|e| SnapshotError::Payload(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_root() -> PhotoFolder {
        PhotoFolder {
            id: StableId::for_folder("/lib"),
            url: FileUrl::new("/lib"),
            name: "lib".into(),
            subfolders: vec![],
            photos: vec![],
            cover_photo_url: None,
            total_photo_count: 0,
            date_modified: None,
            date_created: None,
        }
    }

    fn snapshot() -> LibrarySnapshot {
        LibrarySnapshot {
            root_folder: empty_root(),
            all_photos: vec![],
            sidecar_manifest: None,
        }
    }

    #[test]
    fn the_envelope_is_version_then_value() {
        let bytes = save(&snapshot()).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(keys, vec!["value", "version"]);
        assert_eq!(value["version"], 20);
    }

    #[test]
    fn the_version_is_probed_before_the_payload() {
        // A payload this build cannot decode must still report as a version
        // mismatch, not as corruption — otherwise a schema change looks like
        // disk damage and gets investigated as one.
        let bytes = br#"{"version": 3, "value": {"nonsense": true}}"#;
        assert_eq!(probe_version(bytes), Ok(3));
        assert_eq!(
            load(bytes),
            Err(SnapshotError::VersionMismatch {
                found: 3,
                expected: 20
            })
        );
    }

    #[test]
    fn a_matching_version_with_a_broken_payload_is_a_payload_error() {
        let bytes = br#"{"version": 20, "value": {"allPhotos": []}}"#;
        assert!(matches!(load(bytes), Err(SnapshotError::Payload(_))));
    }

    /// Swift's `JSONEncoder` throws on a non-finite `Double`, and
    /// `JSONDiskCache.save` logs the throw and carries on — so one NaN
    /// coordinate in `allPhotos` means the library snapshot is never written
    /// again, silently, for the life of the install. Nothing the core emits may
    /// contain one, so a snapshot round-trip is a guarantee that every number in
    /// it is finite.
    #[test]
    fn a_non_finite_coordinate_is_written_as_absent_not_as_a_number() {
        let mut photo = PhotoFile::new("/lib/a.jpg", "a", 10);
        photo.gps_latitude = Some(f64::NAN);
        photo.gps_longitude = Some(f64::INFINITY);
        let bytes = save(&LibrarySnapshot {
            all_photos: vec![photo],
            ..snapshot()
        })
        .unwrap();

        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(!text.contains("gpsLatitude"), "{text}");
        assert!(!text.contains("gpsLongitude"), "{text}");
        assert!(!text.contains("null"), "null is not absent: {text}");

        let back = load(&bytes).unwrap();
        assert_eq!(back.all_photos[0].gps_latitude, None);
        assert_eq!(back.all_photos[0].gps_longitude, None);
        // …and a real coordinate is untouched by the same rule.
        let mut located = PhotoFile::new("/lib/b.jpg", "b", 10);
        located.gps_latitude = Some(-0.0);
        located.gps_longitude = Some(2.2945);
        let bytes = save(&LibrarySnapshot {
            all_photos: vec![located],
            ..snapshot()
        })
        .unwrap();
        let back = load(&bytes).unwrap();
        assert_eq!(back.all_photos[0].gps_latitude, Some(-0.0));
        assert_eq!(back.all_photos[0].gps_longitude, Some(2.2945));
    }

    #[test]
    fn unknown_payload_keys_are_ignored() {
        let mut value = serde_json::to_value(Envelope {
            version: 20,
            value: snapshot(),
        })
        .unwrap();
        value["value"]["somethingFromTheFuture"] = serde_json::json!(42);
        let bytes = serde_json::to_vec(&value).unwrap();
        assert!(load(&bytes).is_ok());
    }

    #[test]
    fn the_sidecar_manifest_is_optional_in_both_directions() {
        // Absent on write when None: an older build must not see a new key.
        let bytes = save(&snapshot()).unwrap();
        assert!(!String::from_utf8(bytes.clone())
            .unwrap()
            .contains("sidecarManifest"));
        // …and a file without it decodes to None rather than failing.
        assert_eq!(load(&bytes).unwrap().sidecar_manifest, None);

        let mut with = snapshot();
        with.sidecar_manifest = Some(vec![SidecarCandidate {
            photo_id: StableId::for_photo("/lib/a.jpg"),
            sidecar_url: FileUrl::new("/lib/a.jpg.xmp"),
            current_version: ContentVersion {
                content_identifier: Some("42".into()),
                modification_date: Some(AppleDate(1.0)),
                size: Some(200),
            },
            download_status: DownloadStatus::Local,
        }]);
        let bytes = save(&with).unwrap();
        assert!(String::from_utf8(bytes.clone())
            .unwrap()
            .contains("\"downloadStatus\":\"local\""));
        assert_eq!(load(&bytes).unwrap(), with);
    }

    #[test]
    fn same_content_treats_mixed_identifier_presence_as_different() {
        let with_id = ContentVersion {
            content_identifier: Some("7".into()),
            modification_date: Some(AppleDate(1.0)),
            size: Some(10),
        };
        let without = ContentVersion {
            content_identifier: None,
            ..with_id.clone()
        };
        assert!(ContentVersion::same_content(&with_id, &with_id));
        assert!(ContentVersion::same_content(&without, &without));
        assert!(!ContentVersion::same_content(&with_id, &without));
        assert!(ContentVersion::default().is_empty());
    }
}
