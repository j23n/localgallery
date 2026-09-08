//! Persistent haversine cache. A burst of photos from one street is one query.

use std::path::Path;

use gallery_meta::places::PlaceWriteRequest;
use serde::{Deserialize, Serialize};

use crate::haversine_km;

/// Matches photo-tools' `gps.geocode_cache_radius_km`.
pub const CACHE_RADIUS_KM: f64 = 0.5;

/// Bumped when the on-disk shape changes. v1/v2 were the Swift CLGeocoder
/// cache; those rows are dropped so the next pass re-queries Nominatim.
pub const DISK_CACHE_VERSION: u32 = 3;

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

    /// Load from disk. Missing or stale versions yield an empty cache.
    pub fn load(path: impl AsRef<Path>) -> Self {
        let Ok(bytes) = std::fs::read(path.as_ref()) else {
            return Self::new();
        };
        let Ok(disk) = serde_json::from_slice::<DiskCache>(&bytes) else {
            return Self::new();
        };
        if disk.version != DISK_CACHE_VERSION {
            return Self::new();
        }
        GeoCache {
            entries: disk.entries,
            radius_km: CACHE_RADIUS_KM,
        }
    }

    /// Atomic-ish replace of the cache file.
    pub fn save(&self, path: impl AsRef<Path>) -> std::io::Result<()> {
        let path = path.as_ref();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let bytes = serde_json::to_vec_pretty(&DiskCache {
            version: DISK_CACHE_VERSION,
            entries: self.entries.clone(),
        })
        .expect("cache is serialisable");
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(tmp, path)
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
    }
}
