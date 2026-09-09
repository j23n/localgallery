//! Persistent haversine cache. A burst of photos from one street is one query.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use gallery_meta::places::PlaceWriteRequest;
use serde::{Deserialize, Serialize};

use crate::haversine_km;

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Matches photo-tools' `gps.geocode_cache_radius_km`.
pub const CACHE_RADIUS_KM: f64 = 0.5;

/// Bumped when the on-disk shape changes. v1/v2 were the Swift CLGeocoder
/// cache; those rows are dropped so the next pass re-queries Nominatim.
pub const DISK_CACHE_VERSION: u32 = 3;

/// Why [`GeoCache::try_load`] could not return a usable cache.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeoCacheError {
    /// No file at the path.
    Missing,
    /// JSON that is not a cache object.
    Corrupt(String),
    /// An older on-disk version. Safe to start empty and re-query.
    StaleVersion {
        /// Version the file claimed.
        found: u32,
    },
    /// The file existed but could not be read.
    Io(String),
}

impl std::fmt::Display for GeoCacheError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GeoCacheError::Missing => write!(f, "geocode cache is missing"),
            GeoCacheError::Corrupt(d) => write!(f, "corrupt geocode cache: {d}"),
            GeoCacheError::StaleVersion { found } => {
                write!(
                    f,
                    "geocode cache version {found}, expected {DISK_CACHE_VERSION}"
                )
            }
            GeoCacheError::Io(d) => write!(f, "geocode cache io: {d}"),
        }
    }
}

impl std::error::Error for GeoCacheError {}

/// One cached reverse-geocode.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeoCacheEntry {
    /// Latitude the lookup was made at.
    pub latitude: f64,
    /// Longitude the lookup was made at.
    pub longitude: f64,
    /// `Places/…` path.
    pub path: String,
    /// `photoshop:Country`.
    pub country: Option<String>,
    /// `photoshop:State`.
    pub state: Option<String>,
    /// `photoshop:City`.
    pub city: Option<String>,
    /// Neighbourhood.
    pub sublocation: Option<String>,
    /// ISO 3166-1 alpha-2.
    pub country_code: Option<String>,
}

impl GeoCacheEntry {
    /// From a live lookup.
    pub fn from_request(latitude: f64, longitude: f64, request: PlaceWriteRequest) -> Self {
        GeoCacheEntry {
            latitude,
            longitude,
            path: request.path,
            country: request.country,
            state: request.state,
            city: request.city,
            sublocation: request.sublocation,
            country_code: request.country_code,
        }
    }

    /// Fields the sidecar writer wants.
    pub fn request(&self) -> PlaceWriteRequest {
        PlaceWriteRequest {
            path: self.path.clone(),
            country: self.country.clone(),
            state: self.state.clone(),
            city: self.city.clone(),
            sublocation: self.sublocation.clone(),
            country_code: self.country_code.clone(),
        }
    }
}

/// In-memory cache, optionally backed by a JSON file.
#[derive(Debug, Clone, PartialEq)]
pub struct GeoCache {
    entries: Vec<GeoCacheEntry>,
    radius_km: f64,
}

impl Default for GeoCache {
    fn default() -> Self {
        Self::new()
    }
}

impl GeoCache {
    /// Empty cache, 0.5 km radius.
    pub fn new() -> Self {
        GeoCache {
            entries: Vec::new(),
            radius_km: CACHE_RADIUS_KM,
        }
    }

    /// Load from disk. Missing, stale, or corrupt files yield an empty cache.
    pub fn load(path: impl AsRef<Path>) -> Self {
        Self::try_load(path).unwrap_or_else(|_| Self::new())
    }

    /// Load from disk, distinguishing missing / stale / corrupt.
    pub fn try_load(path: impl AsRef<Path>) -> Result<Self, GeoCacheError> {
        let bytes = match std::fs::read(path.as_ref()) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(GeoCacheError::Missing),
            Err(e) => return Err(GeoCacheError::Io(e.to_string())),
        };
        Self::decode(&bytes)
    }

    /// JSON envelope for an atomic writer.
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec_pretty(&DiskCache {
            version: DISK_CACHE_VERSION,
            entries: self.entries.clone(),
        })
        .expect("cache is serialisable")
    }

    /// Inverse of [`Self::encode`].
    pub fn decode(bytes: &[u8]) -> Result<Self, GeoCacheError> {
        let disk: DiskCache =
            serde_json::from_slice(bytes).map_err(|e| GeoCacheError::Corrupt(e.to_string()))?;
        if disk.version != DISK_CACHE_VERSION {
            return Err(GeoCacheError::StaleVersion {
                found: disk.version,
            });
        }
        Ok(GeoCache {
            entries: disk.entries,
            radius_km: CACHE_RADIUS_KM,
        })
    }

    /// Same-directory temp + fsync + rename. File mode `0600`, parent `0700`.
    pub fn save(&self, path: impl AsRef<Path>) -> std::io::Result<()> {
        write_atomic_private(path.as_ref(), &self.encode())
    }

    /// Closest entry inside [`CACHE_RADIUS_KM`], if any.
    pub fn nearest(&self, lat: f64, lon: f64) -> Option<&GeoCacheEntry> {
        let mut best: Option<(&GeoCacheEntry, f64)> = None;
        for entry in &self.entries {
            let d = haversine_km(lat, lon, entry.latitude, entry.longitude);
            if d < self.radius_km && best.map(|(_, bd)| d < bd).unwrap_or(true) {
                best = Some((entry, d));
            }
        }
        best.map(|(e, _)| e)
    }

    /// Remember a live hit.
    pub fn insert(&mut self, entry: GeoCacheEntry) {
        self.entries.push(entry);
    }

    /// How many rows are stored.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// No rows.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct DiskCache {
    version: u32,
    entries: Vec<GeoCacheEntry>,
}

fn write_atomic_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    if !parent.exists() {
        #[cfg(unix)]
        {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)?;
        }
        #[cfg(not(unix))]
        {
            fs::create_dir_all(parent)?;
        }
    }
    #[cfg(unix)]
    {
        let mut perms = fs::metadata(parent)?.permissions();
        if perms.mode() & 0o777 != 0o700 {
            perms.set_mode(0o700);
            fs::set_permissions(parent, perms)?;
        }
    }
    let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let tmp = parent.join(format!(
        ".gallery-tmp-{}-{}-{}",
        std::process::id(),
        n,
        nanos
    ));
    let write_result = (|| -> io::Result<()> {
        let mut opts = OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(bytes)?;
        #[cfg(unix)]
        {
            f.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        f.sync_all()?;
        Ok(())
    })();
    if let Err(e) = write_result {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    #[cfg(unix)]
    {
        let mut perms = fs::metadata(path)?.permissions();
        if perms.mode() & 0o777 != 0o600 {
            perms.set_mode(0o600);
            fs::set_permissions(path, perms)?;
        }
    }
    if let Ok(dir) = File::open(parent) {
        let _ = dir.sync_all();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_meta::place_from_parts;

    fn paris() -> GeoCacheEntry {
        GeoCacheEntry::from_request(
            48.8566,
            2.3522,
            place_from_parts(Some("France"), None, Some("Paris"), None, Some("fr")).unwrap(),
        )
    }

    #[test]
    fn nearest_hits_within_radius() {
        let mut c = GeoCache::new();
        c.insert(paris());
        assert!(c.nearest(48.8570, 2.3525).is_some());
        assert!(c.nearest(51.5, -0.12).is_none());
    }

    #[test]
    fn stale_disk_version_is_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.json");
        std::fs::write(&path, r#"{"version":2,"entries":[]}"#).unwrap();
        assert!(GeoCache::load(&path).is_empty());
        assert_eq!(
            GeoCache::try_load(&path),
            Err(GeoCacheError::StaleVersion { found: 2 })
        );
    }

    #[test]
    fn corrupt_disk_is_distinct_from_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.json");
        assert_eq!(GeoCache::try_load(&path), Err(GeoCacheError::Missing));
        std::fs::write(&path, b"not-json").unwrap();
        assert!(matches!(
            GeoCache::try_load(&path),
            Err(GeoCacheError::Corrupt(_))
        ));
        assert!(GeoCache::load(&path).is_empty());
    }

    #[test]
    fn round_trip_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.json");
        let mut c = GeoCache::new();
        c.insert(paris());
        c.save(&path).unwrap();
        let loaded = GeoCache::load(&path);
        assert_eq!(loaded.len(), 1);
        assert_eq!(
            loaded.nearest(48.8566, 2.3522).unwrap().path,
            "Places/France/Paris"
        );
        let leftovers: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .filter(|n| n.to_string_lossy().starts_with(".gallery-tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[cfg(unix)]
    #[test]
    fn save_uses_private_file_mode() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.json");
        let mut c = GeoCache::new();
        c.insert(paris());
        c.save(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
