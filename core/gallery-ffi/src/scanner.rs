//! The UniFFI surface over [`gallery_scan`] and the `gallery-meta` read side.
//!
//! # Why this is a session and not three free functions
//!
//! A scan is request/response: the app asks, waits, and uses the answer, so
//! none of the [`crate::support`] run-thread machinery applies — there is no
//! listener to notify, no summary to publish, no "already running" to report.
//! The Store already owns the concurrency policy (dedupe, two-phase ordering,
//! the 48-hour promotion) and Phase 3 explicitly does not move it.
//!
//! Two things still need somewhere to live, and both are per-*app* rather than
//! per-call:
//!
//! * the [`ProviderProbe`] the core calls back into, and
//! * the cancel flag, which by definition has to be reachable from a thread
//!   that is not the one blocked inside `scan`.
//!
//! [`ScannerSession`] is that home. It holds no scan state between calls: the
//! cache goes in with each request and the outcome comes straight back out.
//!
//! # Why the probe is the *only* thing Swift implements
//!
//! The Phase-3 sketch had Swift implement a whole `Vfs` — list, stat, read —
//! so the listing could carry `is_placeholder` and `content_version`. Measured,
//! that is the wrong split. Everything except those provider attributes is
//! plain POSIX, and `std::fs` does it under the app's already-active security
//! scope; routing 20k listings through UniFFI *and* Foundation's URL
//! resource-value machinery costs about 7 s of `resourceValues` calls that
//! `read_dir` does in 40 ms.
//!
//! So the boundary carries exactly what only Swift can answer:
//! `URLResourceKey`-derived provider attributes, batched per directory, for the
//! minority of files a pass actually rebuilds. A light scan over an unchanged
//! library crosses the boundary **zero** times. The seam for a future
//! handle-based backend (Android SAF) is still [`gallery_vfs::Vfs`], which is
//! where it belongs.
//!
//! # Why the tree comes back flat
//!
//! [`PhotoFolder`] owns its photos by value, so shipping the recursive tree and
//! the flat list would put every photo on the wire twice — 40k records for a
//! 20k library. [`ScanFolderNode`] instead carries a parent index and a
//! `(photo_start, photo_count)` slice into `flat_photos`; each folder's photos
//! are contiguous there because the walk appends them a directory at a time.
//! Swift rebuilds the tree from the slices in one linear pass.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use gallery_model::date::AppleDate;
use gallery_model::photo::{
    FaceRegion, FileUrl, HierarchicalTag, PhotoFile, PhotoFolder, PhotoLocality, SidecarStatus,
    StableId,
};
use gallery_model::snapshot::{
    self, ContentVersion, DownloadStatus, LibrarySnapshot, SidecarCandidate, SnapshotError,
};
use gallery_scan::{scan_with_hooks, ScanInput};
use gallery_vfs::{ProviderAttrs, StdVfs, Vfs};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Why a scanner call failed.
///
/// A scan itself is close to infallible — an unreadable directory is *data*
/// (`failed_directory_paths`), not an error, because treating it as one is how
/// a transient provider hiccup wipes a subtree. What is left is the two things
/// that genuinely cannot produce an answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum ScanError {
    /// [`ScannerSession::cancel`] was called before the walk finished. No
    /// partial outcome is returned: half a tree looks exactly like a library
    /// whose second half was deleted.
    Cancelled,
    /// A snapshot file could not be read or written.
    Io {
        /// The path involved.
        path: String,
        /// Platform message; for logs only.
        detail: String,
    },
    /// The snapshot is not JSON, or carries no `version`.
    SnapshotCorrupt {
        /// Parser message; for logs only.
        detail: String,
    },
    /// The snapshot's `version` is not the one this build writes. The caller
    /// evicts, exactly as `JSONDiskCache` does.
    SnapshotVersionMismatch {
        /// What the file claims.
        found: i64,
        /// What this build writes.
        expected: i64,
    },
    /// The version matched and the payload still did not decode.
    SnapshotPayload {
        /// Parser message; for logs only.
        detail: String,
    },
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScanError::Cancelled => write!(f, "cancelled"),
            ScanError::Io { path, detail } => write!(f, "io {path}: {detail}"),
            ScanError::SnapshotCorrupt { detail } => write!(f, "corrupt snapshot: {detail}"),
            ScanError::SnapshotVersionMismatch { found, expected } => {
                write!(f, "snapshot version {found}, expected {expected}")
            }
            ScanError::SnapshotPayload { detail } => write!(f, "snapshot payload: {detail}"),
        }
    }
}

impl std::error::Error for ScanError {}

impl From<SnapshotError> for ScanError {
    fn from(e: SnapshotError) -> Self {
        match e {
            SnapshotError::Corrupt(detail) => ScanError::SnapshotCorrupt { detail },
            SnapshotError::VersionMismatch { found, expected } => {
                ScanError::SnapshotVersionMismatch { found, expected }
            }
            SnapshotError::Payload(detail) => ScanError::SnapshotPayload { detail },
        }
    }
}

// ---------------------------------------------------------------------------
// The one thing Swift implements
// ---------------------------------------------------------------------------

/// `URLResourceKey`-derived facts about a file that POSIX cannot report.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct VfsProviderAttrs {
    /// The file belongs to a file provider (iCloud Drive, OneDrive, …) rather
    /// than to plain local storage.
    pub is_file_provider: bool,
    /// The bytes have not been materialised.
    pub is_placeholder: bool,
    /// `fileContentIdentifierKey`, stringified. `None` when the provider
    /// vends none and callers fall back to `(mtime, size)`.
    pub content_version: Option<String>,
}

/// The platform's provider-attribute reader.
///
/// # Contract
///
/// Called on the core's scan thread, **never** on the main actor, once per
/// directory that needs it. Implementations must:
///
/// * return exactly one row per input path, in order — the core matches
///   positionally, and a short reply degrades the tail to "plain local file";
/// * never call back into the core, which is what would deadlock the
///   synchronous bridge;
/// * treat a failed read as [`VfsProviderAttrs::default`] rather than throwing
///   the batch away, mirroring the `try?` the Swift baseline used.
///
/// Implementations are expected to *fan the batch out*. Each of these is a
/// blocking XPC round trip to `fileproviderd`; run serially they were 99.4% of
/// a cold scan (`_plans/06` Finding 1). Emission order is the core's problem,
/// not the implementation's — the answers are re-keyed by path here.
#[uniffi::export(with_foreign)]
pub trait ProviderProbe: Send + Sync {
    /// Provider attributes for `paths`, positionally.
    fn probe(&self, paths: Vec<String>) -> Vec<VfsProviderAttrs>;
}

/// Progress during a walk.
///
/// Fires on the scan thread every 500 photos and once at the end with the true
/// total. Same rule as the probe: do not call back into the core.
#[uniffi::export(with_foreign)]
pub trait ScanProgressListener: Send + Sync {
    /// Photos discovered so far.
    fn on_progress(&self, discovered: u32);
}

/// [`StdVfs`] with the provider attributes the platform layer supplies.
///
/// Everything byte- or directory-shaped goes to `std::fs`; only
/// [`Vfs::probe_provider`] crosses back into Swift.
struct ProbingVfs {
    inner: StdVfs,
    probe: Arc<dyn ProviderProbe>,
}

impl Vfs for ProbingVfs {
    fn open(&self, path: &str) -> gallery_vfs::VfsResult<Box<dyn gallery_vfs::ReadSeek + Send>> {
        self.inner.open(path)
    }
    fn stat(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Stat> {
        self.inner.stat(path)
    }
    fn list(&self, dir: &str) -> gallery_vfs::VfsResult<Vec<gallery_vfs::Entry>> {
        self.inner.list(dir)
    }
    fn stat_entry(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Entry> {
        self.inner.stat_entry(path)
    }
    fn write_atomic(&self, path: &str, bytes: &[u8]) -> gallery_vfs::VfsResult<()> {
        self.inner.write_atomic(path, bytes)
    }
    fn exists(&self, path: &str) -> bool {
        self.inner.exists(path)
    }
    fn probe_provider(&self, paths: &[String]) -> Vec<ProviderAttrs> {
        self.probe
            .probe(paths.to_vec())
            .into_iter()
            .map(|a| ProviderAttrs {
                is_file_provider: a.is_file_provider,
                is_placeholder: a.is_placeholder,
                content_version: a.content_version,
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Wire records
// ---------------------------------------------------------------------------

/// One `digiKam:TagsList` entry.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScanTag {
    /// Raw `/`-separated path.
    pub full_path: String,
    /// First segment, or `None` for a flat tag.
    pub namespace: Option<String>,
    /// Leaf segment.
    pub display_name: String,
}

/// One MWG region, normalised 0…1.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScanRegion {
    /// `mwg-rs:Name`, absent for unnamed rectangles.
    pub name: Option<String>,
    /// Centre x.
    pub center_x: f64,
    /// Centre y.
    pub center_y: f64,
    /// Full width.
    pub width: f64,
    /// Full height.
    pub height: f64,
}

/// Where a photo's bytes live.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScanLocality {
    /// Readable from disk right now.
    Local,
    /// Provider-backed; `downloaded: false` is the placeholder state.
    Remote {
        /// Whether the bytes have been materialised.
        downloaded: bool,
    },
}

/// One photo or video, crossing the boundary.
///
/// Dates are **seconds since 2001-01-01T00:00:00Z**, i.e. Swift's
/// `Date.timeIntervalSinceReferenceDate` — the same origin the persisted
/// snapshot uses, so no epoch arithmetic happens at the bridge.
///
/// `sidecarStatus` is deliberately absent. It is runtime state the scanner
/// never sets and the Store re-derives from `SidecarCacheStore` in
/// `mergeCachedSidecars`, on the same pass, before anything is published.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScanPhoto {
    /// `StableUUID.derive(path)`, uppercase hyphenated.
    pub id: String,
    /// Absolute filesystem path — *not* a `file://` URL. The URL spelling is
    /// the snapshot's wire format, not this one's.
    pub path: String,
    /// Basename without the last extension.
    pub filename: String,
    /// Size in bytes.
    pub file_size: i64,
    /// Capture date, or the filesystem fallback.
    pub date_taken: Option<f64>,
    /// Whether `date_taken` came from embedded metadata.
    pub date_from_metadata: bool,
    /// Whether this row is a video.
    pub is_video: bool,
    /// The paired live-photo movie beside it.
    pub live_photo_video_path: Option<String>,
    /// Tags from `digiKam:TagsList`.
    pub hierarchical_tags: Vec<ScanTag>,
    /// Uppercase ISO 3166-1 alpha-2.
    pub country_code: Option<String>,
    /// The file's mtime as of the last successful enrichment.
    pub enriched_file_date: Option<f64>,
    /// The file's mtime as of this scan.
    pub file_modification_date: Option<f64>,
    /// Latitude, sign already applied.
    pub gps_latitude: Option<f64>,
    /// Longitude, sign already applied.
    pub gps_longitude: Option<f64>,
    /// MWG regions.
    pub face_regions: Vec<ScanRegion>,
    /// Where the bytes live.
    pub locality: ScanLocality,
}

/// One folder, flattened. See the module docs for why the tree is not
/// recursive on the wire.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScanFolderNode {
    /// `StableUUID.derive("folder:" + path)`, uppercase hyphenated.
    pub id: String,
    /// Absolute path.
    pub path: String,
    /// Last path component.
    pub name: String,
    /// Index of this node's parent in the same array; `None` for the root.
    /// Children appear after their parent and in the order the tree wants
    /// them, so one linear pass rebuilds it.
    pub parent_index: Option<u32>,
    /// Offset of this folder's own photos in `flat_photos`.
    pub photo_start: u32,
    /// How many of them there are.
    pub photo_count: u32,
    /// `photos.first`, else the first subfolder that has one.
    pub cover_photo_path: Option<String>,
    /// Recursive photo count.
    pub total_photo_count: i64,
    /// Directory mtime, reference-date seconds.
    pub date_modified: Option<f64>,
    /// Directory birth time, reference-date seconds.
    pub date_created: Option<f64>,
}

/// A file's identity without reading it.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ScanContentVersion {
    /// `fileContentIdentifierKey`, stringified.
    pub content_identifier: Option<String>,
    /// Modification date, reference-date seconds.
    pub modification_date: Option<f64>,
    /// Size in bytes.
    pub size: Option<i64>,
}

/// One sidecar manifest row.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScanSidecarRow {
    /// The photo the `.xmp` belongs to.
    pub photo_id: String,
    /// Absolute path of the `.xmp`.
    pub sidecar_path: String,
    /// Its identity at scan time.
    pub current_version: ScanContentVersion,
    /// Whether its own bytes are present — `local` or `placeholder`.
    pub download_status: String,
}

/// Where a pass spent its time. Feeds the `Scan totals:` log line the
/// performance gates are measured from.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct ScanTimings {
    /// Whole pass, inside the core.
    pub total_millis: u64,
    /// Directory listings.
    pub list_millis: u64,
    /// Provider probes — the whole of Finding 1.
    pub probe_millis: u64,
    /// Paths probed.
    pub probed_paths: u32,
    /// Batched probe calls — i.e. boundary crossings.
    pub probe_batches: u32,
    /// Photos reused verbatim from the cache.
    pub cache_hits: u32,
    /// Photos rebuilt.
    pub slow_path: u32,
    /// Directories visited.
    pub folders: u32,
}

/// Everything one pass produces.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ScanOutcomeRecord {
    /// Every photo, in traversal order. Folder membership is expressed as
    /// slices of this array.
    pub flat_photos: Vec<ScanPhoto>,
    /// The tree, flattened; empty when the root itself could not be visited.
    pub folders: Vec<ScanFolderNode>,
    /// Whether anything needs an enrichment pass.
    pub needs_enrichment: bool,
    /// One row per image that has a `<basename>.xmp` beside it.
    pub sidecar_manifest: Vec<ScanSidecarRow>,
    /// Paths seen now and absent from the cache.
    pub added_paths: Vec<String>,
    /// Paths in the cache and not seen now, excluding anything under a failed
    /// directory.
    pub removed_paths: Vec<String>,
    /// Paths whose size or mtime changed.
    pub modified_paths: Vec<String>,
    /// Decomposed paths of directories whose listing failed.
    pub failed_directory_paths: Vec<String>,
    /// Timings and counters.
    pub timings: ScanTimings,
}

/// The cache a pass is allowed to reuse.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ScanRequest {
    /// Reuse cached photos for unchanged paths — the light scan.
    pub reuse_cached: bool,
    /// Last pass's photos. Carries EXIF, tags, GPS and locality forward.
    pub cached_photos: Vec<ScanPhoto>,
    /// Last pass's sidecar rows. A hit here is what lets a light scan skip
    /// re-probing an `.xmp`.
    pub cached_sidecar_manifest: Vec<ScanSidecarRow>,
}

/// A persisted library, as the core sees it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SnapshotRecord {
    /// Every photo, flat.
    pub all_photos: Vec<ScanPhoto>,
    /// The tree, flattened the same way [`ScanOutcomeRecord`] flattens it.
    pub folders: Vec<ScanFolderNode>,
    /// The sidecar manifest from the same scan, when the file carries one.
    pub sidecar_manifest: Option<Vec<ScanSidecarRow>>,
}

// ---------------------------------------------------------------------------
// The session
// ---------------------------------------------------------------------------

/// The app's handle on the core scanner.
#[derive(uniffi::Object)]
pub struct ScannerSession {
    probe: Arc<dyn ProviderProbe>,
    cancel: AtomicBool,
}

#[uniffi::export]
impl ScannerSession {
    /// Build a session over the platform's provider probe.
    ///
    /// Cheap: the session holds no cache and opens no files, so making one per
    /// Store is fine and making one per scan would be too.
    #[uniffi::constructor]
    pub fn new(probe: Arc<dyn ProviderProbe>) -> Arc<Self> {
        Arc::new(ScannerSession {
            probe,
            cancel: AtomicBool::new(false),
        })
    }

    /// Walk `root` and produce the tree, the flat list, and the diff.
    ///
    /// **Blocking, and single-threaded by design.** The caller runs it off the
    /// main actor; the core does not spawn for it, because the whole point of
    /// the call is the answer. Progress and provider probes fire on this
    /// thread.
    pub fn scan(
        &self,
        root: String,
        request: ScanRequest,
        progress: Option<Arc<dyn ScanProgressListener>>,
    ) -> Result<ScanOutcomeRecord, ScanError> {
        self.cancel.store(false, Ordering::Release);
        let started = std::time::Instant::now();

        let vfs = ProbingVfs {
            inner: StdVfs::new(),
            probe: Arc::clone(&self.probe),
        };
        let input = ScanInput {
            reuse_cached: request.reuse_cached,
            cached_photos: request
                .cached_photos
                .into_iter()
                .map(|p| (p.path.clone(), photo_from_record(p)))
                .collect(),
            cached_sidecar_manifest: request
                .cached_sidecar_manifest
                .into_iter()
                .map(|row| {
                    let row = sidecar_from_record(row);
                    (row.photo_id, row)
                })
                .collect(),
        };

        let report = progress.map(|listener| {
            move |discovered: usize| listener.on_progress(discovered.min(u32::MAX as usize) as u32)
        });
        let outcome = scan_with_hooks(
            &vfs,
            &root,
            &input,
            report.as_ref().map(|f| f as &dyn Fn(usize)),
            Some(&|| self.cancel.load(Ordering::Acquire)),
        )
        .ok_or(ScanError::Cancelled)?;

        Ok(outcome_to_record(outcome, started.elapsed()))
    }

    /// Ask the in-flight walk to stop. Returns immediately; the blocked
    /// `scan` call answers [`ScanError::Cancelled`] at its next directory
    /// boundary.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
    }
}

// ---------------------------------------------------------------------------
// Snapshot IO
// ---------------------------------------------------------------------------

/// The `LibrarySnapshot.version` this build reads and writes.
#[uniffi::export]
pub fn snapshot_version() -> i64 {
    snapshot::LIBRARY_SNAPSHOT_VERSION
}

/// Read the envelope's `version` without touching the payload.
///
/// Mirrors `JSONDiskCache`'s load order exactly: a payload this build cannot
/// decode must still report as a version mismatch rather than as corruption,
/// because only one of those two is a bug.
#[uniffi::export]
pub fn probe_snapshot_version(path: String) -> Result<i64, ScanError> {
    let bytes = read_file(&path)?;
    Ok(snapshot::probe_version(&bytes)?)
}

/// Decode a snapshot file written by `JSONDiskCache<LibrarySnapshot>`.
#[uniffi::export]
pub fn load_snapshot(path: String) -> Result<SnapshotRecord, ScanError> {
    let bytes = read_file(&path)?;
    let snapshot = snapshot::load(&bytes)?;
    let mut photos = Vec::new();
    let mut folders = Vec::new();
    flatten_folder(&snapshot.root_folder, None, &mut folders, &mut Vec::new());
    photos.extend(snapshot.all_photos.iter().map(photo_to_record));
    Ok(SnapshotRecord {
        all_photos: photos,
        folders,
        sidecar_manifest: snapshot
            .sidecar_manifest
            .map(|rows| rows.iter().map(sidecar_to_record).collect()),
    })
}

/// Encode a snapshot in the current version's envelope and write it.
///
/// The app persists through `JSONDiskCache` — this exists so a test can prove
/// the two encoders agree at runtime, not only against a committed fixture.
#[uniffi::export]
pub fn save_snapshot(path: String, snapshot: SnapshotRecord) -> Result<(), ScanError> {
    let (root, photos) = rebuild_tree(&snapshot.folders, &snapshot.all_photos);
    let Some(root_folder) = root else {
        return Err(ScanError::SnapshotPayload {
            detail: "a snapshot needs a root folder".into(),
        });
    };
    let bytes = snapshot::save(&LibrarySnapshot {
        root_folder,
        all_photos: photos,
        sidecar_manifest: snapshot
            .sidecar_manifest
            .map(|rows| rows.into_iter().map(sidecar_from_record).collect()),
    })?;
    StdVfs::new()
        .write_atomic(&path, &bytes)
        .map_err(|e| ScanError::Io {
            path,
            detail: e.to_string(),
        })
}

fn read_file(path: &str) -> Result<Vec<u8>, ScanError> {
    StdVfs::new().read(path).map_err(|e| ScanError::Io {
        path: path.to_string(),
        detail: e.to_string(),
    })
}

// ---------------------------------------------------------------------------
// Metadata read
// ---------------------------------------------------------------------------

/// A zone-less wall clock, as EXIF records it.
///
/// The bridge resolves it in the **device** time zone, which is what
/// `MetadataReader.exifDateFormatter` did by having no `timeZone` at all.
/// Handing back an instant here would bake this machine's zone into a value
/// the app is supposed to read in the user's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct WallClock {
    /// Year.
    pub year: i32,
    /// 1-12.
    pub month: u32,
    /// 1-31.
    pub day: u32,
    /// 0-23 — hour 24 has already been rolled into the next day.
    pub hour: u32,
    /// 0-59.
    pub minute: u32,
    /// 0-59.
    pub second: u32,
}

/// What one photo contributes to a `PhotoFile`.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ImageMetadataRecord {
    /// EXIF capture date, zone-less.
    pub capture_wall_clock: Option<WallClock>,
    /// Deduplicated tags, embedded first.
    pub hierarchical_tags: Vec<ScanTag>,
    /// Uppercase country code.
    pub country_code: Option<String>,
    /// Signed latitude.
    pub gps_latitude: Option<f64>,
    /// Signed longitude.
    pub gps_longitude: Option<f64>,
    /// Face regions, sidecar-preferred.
    pub face_regions: Vec<ScanRegion>,
}

/// The three things a `.xmp` contributes.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct SidecarParseRecord {
    /// Raw `digiKam:TagsList` entries, in packet order, undeduplicated.
    pub raw_tags: Vec<String>,
    /// Uppercase `photo-tools:CountryCode`.
    pub country_code: Option<String>,
    /// MWG regions.
    pub face_regions: Vec<ScanRegion>,
}

/// Read `path` and its `.xmp` sidecar: EXIF date, tags, country, GPS, regions.
///
/// The precedence table between the two sources lives at the merge site in
/// `gallery_meta::media`, which is now its only copy.
#[uniffi::export]
pub fn read_image_metadata(path: String) -> ImageMetadataRecord {
    let meta = gallery_meta::media::read_image_metadata(&StdVfs::new(), &path);
    ImageMetadataRecord {
        capture_wall_clock: meta.capture_wall_clock.map(|c| WallClock {
            year: c.year,
            month: c.month,
            day: c.day,
            hour: c.hour,
            minute: c.minute,
            second: c.second,
        }),
        hierarchical_tags: meta.hierarchical_tags.iter().map(tag_to_record).collect(),
        country_code: meta.country_code,
        gps_latitude: meta.gps_latitude,
        gps_longitude: meta.gps_longitude,
        face_regions: meta.face_regions.iter().map(region_to_record).collect(),
    }
}

/// Creation date of a video, as **Unix** seconds UTC.
///
/// Unix rather than reference-date seconds because a `©day` is a true instant,
/// not a wall clock, and because the atom parser already speaks Unix. Only
/// `moov` and `ftyp` are read; a 4 GB `mdat` is never touched.
#[uniffi::export]
pub fn read_video_date(path: String) -> Option<i64> {
    gallery_meta::media::video::read_video_date_at(&StdVfs::new(), &path)
}

/// Parse XMP bytes the caller already holds — the sidecar-sync path, which
/// fetches `.xmp` contents from a file provider and never touches disk.
#[uniffi::export]
pub fn parse_xmp_bytes(bytes: Vec<u8>) -> SidecarParseRecord {
    let parsed = gallery_meta::media::parse_xmp_bytes(&bytes);
    SidecarParseRecord {
        raw_tags: parsed.raw_tags,
        country_code: parsed.country_code,
        face_regions: parsed
            .face_regions
            .iter()
            .map(|r| ScanRegion {
                name: r.name.clone(),
                center_x: r.center_x,
                center_y: r.center_y,
                width: r.width,
                height: r.height,
            })
            .collect(),
    }
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

fn tag_to_record(tag: &HierarchicalTag) -> ScanTag {
    ScanTag {
        full_path: tag.full_path.clone(),
        namespace: tag.namespace.clone(),
        display_name: tag.display_name.clone(),
    }
}

fn region_to_record(region: &FaceRegion) -> ScanRegion {
    ScanRegion {
        name: region.name.clone(),
        center_x: region.center_x,
        center_y: region.center_y,
        width: region.width,
        height: region.height,
    }
}

fn photo_to_record(photo: &PhotoFile) -> ScanPhoto {
    ScanPhoto {
        id: photo.id.to_string(),
        path: photo.url.path().to_string(),
        filename: photo.filename.clone(),
        file_size: photo.file_size,
        date_taken: photo.date_taken.map(|d| d.0),
        date_from_metadata: photo.date_from_metadata,
        is_video: photo.is_video,
        live_photo_video_path: photo
            .live_photo_video_url
            .as_ref()
            .map(|u| u.path().to_string()),
        hierarchical_tags: photo.hierarchical_tags.iter().map(tag_to_record).collect(),
        country_code: photo.country_code.clone(),
        enriched_file_date: photo.enriched_file_date.map(|d| d.0),
        file_modification_date: photo.file_modification_date.map(|d| d.0),
        gps_latitude: photo.gps_latitude,
        gps_longitude: photo.gps_longitude,
        face_regions: photo.face_regions.iter().map(region_to_record).collect(),
        locality: match photo.locality {
            PhotoLocality::Local => ScanLocality::Local,
            PhotoLocality::Remote { downloaded } => ScanLocality::Remote { downloaded },
        },
    }
}

fn photo_from_record(record: ScanPhoto) -> PhotoFile {
    PhotoFile {
        // Re-derived rather than trusted: the id *is* a function of the path,
        // and a caller that let the two drift would silently split a photo's
        // history in two.
        id: StableId::for_photo(&record.path),
        url: FileUrl::new(record.path),
        filename: record.filename,
        file_size: record.file_size,
        date_taken: record.date_taken.map(AppleDate),
        date_from_metadata: record.date_from_metadata,
        is_video: record.is_video,
        live_photo_video_url: record.live_photo_video_path.map(FileUrl::new),
        hierarchical_tags: record
            .hierarchical_tags
            .into_iter()
            .map(|t| HierarchicalTag {
                full_path: t.full_path,
                namespace: t.namespace,
                display_name: t.display_name,
            })
            .collect(),
        country_code: record.country_code,
        enriched_file_date: record.enriched_file_date.map(AppleDate),
        file_modification_date: record.file_modification_date.map(AppleDate),
        gps_latitude: record.gps_latitude,
        gps_longitude: record.gps_longitude,
        face_regions: record
            .face_regions
            .into_iter()
            .map(|r| FaceRegion {
                name: r.name,
                center_x: r.center_x,
                center_y: r.center_y,
                width: r.width,
                height: r.height,
            })
            .collect(),
        locality: match record.locality {
            ScanLocality::Local => PhotoLocality::Local,
            ScanLocality::Remote { downloaded } => PhotoLocality::Remote { downloaded },
        },
        sidecar_status: SidecarStatus::Absent,
    }
}

fn sidecar_to_record(row: &SidecarCandidate) -> ScanSidecarRow {
    ScanSidecarRow {
        photo_id: row.photo_id.to_string(),
        sidecar_path: row.sidecar_url.path().to_string(),
        current_version: ScanContentVersion {
            content_identifier: row.current_version.content_identifier.clone(),
            modification_date: row.current_version.modification_date.map(|d| d.0),
            size: row.current_version.size,
        },
        download_status: row.download_status.describe().to_string(),
    }
}

fn sidecar_from_record(row: ScanSidecarRow) -> SidecarCandidate {
    SidecarCandidate {
        // The photo id is `StableUUID.derive` of the photo's path, and the
        // sidecar is that path plus `.xmp`, so it is derivable — but the
        // caller's copy is the one the manifest was keyed by, and re-deriving
        // it here would break the lookup for any spelling that does not
        // round-trip. Parse, and fall back to the derivation.
        photo_id: uuid::Uuid::parse_str(&row.photo_id)
            .map(StableId)
            .unwrap_or_else(|_| {
                StableId::for_photo(row.sidecar_path.trim_end_matches(".xmp"))
            }),
        sidecar_url: FileUrl::new(row.sidecar_path),
        current_version: ContentVersion {
            content_identifier: row.current_version.content_identifier,
            modification_date: row.current_version.modification_date.map(AppleDate),
            size: row.current_version.size,
        },
        download_status: match row.download_status.as_str() {
            "placeholder" => DownloadStatus::Placeholder,
            "downloading" => DownloadStatus::Downloading,
            "stale" => DownloadStatus::Stale,
            _ => DownloadStatus::Local,
        },
    }
}

/// Depth-first flatten, parent before children, photos appended in the same
/// order — which is what makes `(photo_start, photo_count)` a valid slice.
fn flatten_folder(
    folder: &PhotoFolder,
    parent_index: Option<u32>,
    out: &mut Vec<ScanFolderNode>,
    photos: &mut Vec<PhotoFile>,
) {
    let index = out.len() as u32;
    out.push(ScanFolderNode {
        id: folder.id.to_string(),
        path: folder.url.path().to_string(),
        name: folder.name.clone(),
        parent_index,
        photo_start: photos.len() as u32,
        photo_count: folder.photos.len() as u32,
        cover_photo_path: folder.cover_photo_url.as_ref().map(|u| u.path().to_string()),
        total_photo_count: folder.total_photo_count,
        date_modified: folder.date_modified.map(|d| d.0),
        date_created: folder.date_created.map(|d| d.0),
    });
    photos.extend(folder.photos.iter().cloned());
    for child in &folder.subfolders {
        flatten_folder(child, Some(index), out, photos);
    }
}

/// The inverse of [`flatten_folder`], for [`save_snapshot`].
///
/// Returns the root and the flat photo list unchanged; a node whose
/// `parent_index` does not point at an earlier node is dropped rather than
/// panicked over — a malformed request must not take the process with it.
fn rebuild_tree(
    nodes: &[ScanFolderNode],
    photos: &[ScanPhoto],
) -> (Option<PhotoFolder>, Vec<PhotoFile>) {
    let all: Vec<PhotoFile> = photos.iter().cloned().map(photo_from_record).collect();
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (i, node) in nodes.iter().enumerate() {
        if let Some(parent) = node.parent_index {
            if (parent as usize) < i {
                children.entry(parent).or_default().push(i as u32);
            }
        }
    }
    let root = (!nodes.is_empty()).then(|| build(0, nodes, &all, &children));
    (root, all)
}

fn build(
    index: u32,
    nodes: &[ScanFolderNode],
    photos: &[PhotoFile],
    children: &HashMap<u32, Vec<u32>>,
) -> PhotoFolder {
    let node = &nodes[index as usize];
    let start = node.photo_start as usize;
    let end = (start + node.photo_count as usize).min(photos.len());
    PhotoFolder {
        id: StableId::for_folder(&node.path),
        url: FileUrl::new(node.path.clone()),
        name: node.name.clone(),
        subfolders: children
            .get(&index)
            .map(|kids| {
                kids.iter()
                    .map(|&kid| build(kid, nodes, photos, children))
                    .collect()
            })
            .unwrap_or_default(),
        photos: photos.get(start..end).unwrap_or_default().to_vec(),
        cover_photo_url: node.cover_photo_path.clone().map(FileUrl::new),
        total_photo_count: node.total_photo_count,
        date_modified: node.date_modified.map(AppleDate),
        date_created: node.date_created.map(AppleDate),
    }
}

fn outcome_to_record(
    outcome: gallery_scan::ScanOutcome,
    elapsed: std::time::Duration,
) -> ScanOutcomeRecord {
    let stats = outcome.stats;
    let mut folders = Vec::new();
    if let Some(root) = &outcome.root_folder {
        // The tree's photos are the same values, in the same order, as
        // `flat_photos` — so the flatten's photo accumulator is thrown away
        // and only the offsets it computed are kept.
        flatten_folder(root, None, &mut folders, &mut Vec::new());
    }
    ScanOutcomeRecord {
        flat_photos: outcome.flat_photos.iter().map(photo_to_record).collect(),
        folders,
        needs_enrichment: outcome.needs_enrichment,
        sidecar_manifest: outcome
            .sidecar_manifest
            .iter()
            .map(sidecar_to_record)
            .collect(),
        added_paths: outcome.added_paths,
        removed_paths: outcome.removed_paths,
        modified_paths: outcome.modified_paths,
        failed_directory_paths: outcome.failed_directory_paths,
        timings: ScanTimings {
            total_millis: elapsed.as_millis() as u64,
            list_millis: stats.list_micros / 1000,
            probe_millis: stats.probe_micros / 1000,
            probed_paths: stats.probed_paths as u32,
            probe_batches: stats.probe_batches as u32,
            cache_hits: stats.cache_hits as u32,
            slow_path: stats.slow_path as u32,
            folders: stats.folders as u32,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct AllLocal;
    impl ProviderProbe for AllLocal {
        fn probe(&self, paths: Vec<String>) -> Vec<VfsProviderAttrs> {
            vec![VfsProviderAttrs::default(); paths.len()]
        }
    }

    struct AllRemote;
    impl ProviderProbe for AllRemote {
        fn probe(&self, paths: Vec<String>) -> Vec<VfsProviderAttrs> {
            paths
                .iter()
                .map(|p| VfsProviderAttrs {
                    is_file_provider: true,
                    is_placeholder: p.ends_with("b.jpg"),
                    content_version: Some(format!("v:{p}")),
                })
                .collect()
        }
    }

    fn library() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.jpg"), b"aaaa").unwrap();
        std::fs::write(dir.path().join("b.jpg"), b"bbbbb").unwrap();
        std::fs::write(dir.path().join("b.jpg.xmp"), b"<x/>").unwrap();
        std::fs::create_dir(dir.path().join("Sub")).unwrap();
        std::fs::write(dir.path().join("Sub/c.jpg"), b"cc").unwrap();
        dir
    }

    fn empty_request() -> ScanRequest {
        ScanRequest {
            reuse_cached: false,
            cached_photos: Vec::new(),
            cached_sidecar_manifest: Vec::new(),
        }
    }

    #[test]
    fn a_scan_reports_the_tree_as_slices_of_the_flat_list() {
        let dir = library();
        let session = ScannerSession::new(Arc::new(AllLocal));
        let out = session
            .scan(
                dir.path().to_str().unwrap().to_string(),
                empty_request(),
                None,
            )
            .unwrap();

        assert_eq!(out.flat_photos.len(), 3);
        assert_eq!(out.folders.len(), 2);
        let root = &out.folders[0];
        let sub = &out.folders[1];
        assert_eq!(root.parent_index, None);
        assert_eq!(sub.parent_index, Some(0));
        assert_eq!(root.total_photo_count, 3);
        // Every folder's photos are a contiguous run, and the runs tile the
        // flat list exactly — the invariant the wire format rests on.
        assert_eq!((root.photo_start, root.photo_count), (0, 2));
        assert_eq!((sub.photo_start, sub.photo_count), (2, 1));
        assert_eq!(out.sidecar_manifest.len(), 1);
        assert!(out.sidecar_manifest[0].sidecar_path.ends_with("b.jpg.xmp"));
        assert_eq!(out.timings.slow_path, 3);
        assert_eq!(out.timings.cache_hits, 0);
    }

    #[test]
    fn provider_attributes_come_from_the_foreign_probe() {
        let dir = library();
        let session = ScannerSession::new(Arc::new(AllRemote));
        let out = session
            .scan(
                dir.path().to_str().unwrap().to_string(),
                empty_request(),
                None,
            )
            .unwrap();

        let b = out
            .flat_photos
            .iter()
            .find(|p| p.path.ends_with("b.jpg"))
            .unwrap();
        assert_eq!(b.locality, ScanLocality::Remote { downloaded: false });
        let a = out
            .flat_photos
            .iter()
            .find(|p| p.path.ends_with("a.jpg"))
            .unwrap();
        assert_eq!(a.locality, ScanLocality::Remote { downloaded: true });
        assert!(out.sidecar_manifest[0]
            .current_version
            .content_identifier
            .as_deref()
            .unwrap()
            .starts_with("v:"));
    }

    /// The point of feeding the cache back in: a second pass reuses it and
    /// never crosses the boundary.
    #[test]
    fn a_light_pass_over_the_previous_outcome_is_all_cache_hits() {
        let dir = library();
        let root = dir.path().to_str().unwrap().to_string();
        let session = ScannerSession::new(Arc::new(AllLocal));
        let cold = session.scan(root.clone(), empty_request(), None).unwrap();

        let light = session
            .scan(
                root,
                ScanRequest {
                    reuse_cached: true,
                    cached_photos: cold.flat_photos.clone(),
                    cached_sidecar_manifest: cold.sidecar_manifest.clone(),
                },
                None,
            )
            .unwrap();

        assert_eq!(light.timings.cache_hits, 3);
        assert_eq!(light.timings.slow_path, 0);
        assert_eq!(light.timings.probe_batches, 0);
        assert!(light.added_paths.is_empty() && light.removed_paths.is_empty());
        assert_eq!(light.sidecar_manifest, cold.sidecar_manifest);
        assert_eq!(light.flat_photos, cold.flat_photos);
    }

    #[test]
    fn progress_ends_on_the_true_total() {
        struct Sink(std::sync::Mutex<Vec<u32>>);
        impl ScanProgressListener for Sink {
            fn on_progress(&self, discovered: u32) {
                self.0.lock().unwrap().push(discovered);
            }
        }
        let dir = library();
        let sink = Arc::new(Sink(std::sync::Mutex::new(Vec::new())));
        let session = ScannerSession::new(Arc::new(AllLocal));
        let out = session
            .scan(
                dir.path().to_str().unwrap().to_string(),
                empty_request(),
                Some(sink.clone()),
            )
            .unwrap();
        assert_eq!(
            sink.0.lock().unwrap().last().copied(),
            Some(out.flat_photos.len() as u32)
        );
    }

    /// Cancel means "stop the run that is happening", so it has to be
    /// observed from a thread that is not the one blocked inside `scan`.
    #[test]
    fn a_cancel_mid_walk_returns_the_typed_error_and_no_tree() {
        /// Signals when the walk has reached its first directory, then waits.
        struct Handshake {
            entered: std::sync::mpsc::SyncSender<()>,
            released: Arc<AtomicBool>,
        }
        impl ProviderProbe for Handshake {
            fn probe(&self, paths: Vec<String>) -> Vec<VfsProviderAttrs> {
                let _ = self.entered.try_send(());
                while !self.released.load(Ordering::Acquire) {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                vec![VfsProviderAttrs::default(); paths.len()]
            }
        }

        let dir = library();
        let root = dir.path().to_str().unwrap().to_string();
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let released = Arc::new(AtomicBool::new(false));
        let session = ScannerSession::new(Arc::new(Handshake {
            entered: tx,
            released: Arc::clone(&released),
        }));

        let worker = {
            let session = Arc::clone(&session);
            std::thread::spawn(move || session.scan(root, empty_request(), None))
        };
        rx.recv().expect("the walk never reached a directory");
        session.cancel();
        released.store(true, Ordering::Release);

        assert_eq!(worker.join().unwrap(), Err(ScanError::Cancelled));

        // …and the flag is cleared by the next `scan`, so one cancel does not
        // wedge the session.
        released.store(true, Ordering::Release);
        assert!(session
            .scan(
                dir.path().to_str().unwrap().to_string(),
                empty_request(),
                None
            )
            .is_ok());
    }

    #[test]
    fn a_snapshot_round_trips_through_the_flattened_tree() {
        let dir = library();
        let session = ScannerSession::new(Arc::new(AllLocal));
        let out = session
            .scan(
                dir.path().to_str().unwrap().to_string(),
                empty_request(),
                None,
            )
            .unwrap();

        let path = dir.path().join("snapshot.json");
        let record = SnapshotRecord {
            all_photos: out.flat_photos.clone(),
            folders: out.folders.clone(),
            sidecar_manifest: Some(out.sidecar_manifest.clone()),
        };
        save_snapshot(path.to_str().unwrap().to_string(), record.clone()).unwrap();

        assert_eq!(
            probe_snapshot_version(path.to_str().unwrap().to_string()).unwrap(),
            snapshot_version()
        );
        let loaded = load_snapshot(path.to_str().unwrap().to_string()).unwrap();
        assert_eq!(loaded.all_photos.len(), 3);
        assert_eq!(loaded.sidecar_manifest, record.sidecar_manifest);
        // Locality is runtime state and is not persisted — everything comes
        // back local, which is the documented, legal loss.
        assert!(loaded
            .all_photos
            .iter()
            .all(|p| p.locality == ScanLocality::Local));
        assert_eq!(
            loaded.folders.iter().map(|f| f.name.clone()).collect::<Vec<_>>(),
            record.folders.iter().map(|f| f.name.clone()).collect::<Vec<_>>()
        );
        assert_eq!(
            loaded.folders.iter().map(|f| f.photo_start).collect::<Vec<_>>(),
            record.folders.iter().map(|f| f.photo_start).collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_missing_snapshot_is_an_io_error_not_a_version_mismatch() {
        let err = load_snapshot("/definitely/not/here.json".to_string()).unwrap_err();
        assert!(matches!(err, ScanError::Io { .. }), "{err:?}");
    }

    #[test]
    fn an_older_version_is_reported_as_a_mismatch_not_as_corruption() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("old.json");
        std::fs::write(&path, br#"{"version":3,"value":{"nonsense":true}}"#).unwrap();
        let p = path.to_str().unwrap().to_string();
        assert_eq!(probe_snapshot_version(p.clone()).unwrap(), 3);
        assert_eq!(
            load_snapshot(p).unwrap_err(),
            ScanError::SnapshotVersionMismatch {
                found: 3,
                expected: snapshot_version()
            }
        );
    }

    #[test]
    fn xmp_bytes_parse_without_touching_disk() {
        let xmp = br#"<x><digiKam:TagsList><rdf:Seq><rdf:li>People/Alice</rdf:li></rdf:Seq></digiKam:TagsList><photo-tools:CountryCode>it</photo-tools:CountryCode></x>"#;
        let parsed = parse_xmp_bytes(xmp.to_vec());
        assert_eq!(parsed.raw_tags, vec!["People/Alice".to_string()]);
        assert_eq!(parsed.country_code.as_deref(), Some("IT"));
    }
}
