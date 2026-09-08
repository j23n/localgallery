//! Reverse geocoding for `Places/*` sidecars.
//!
//! One source: Nominatim, English names, so iOS and Linux write the same
//! tree photo-tools does. [`gallery_meta`] still owns the XMP write;
//! this crate only turns a coordinate into a [`PlaceWriteRequest`].
//!
//! Live HTTP is optional — tests inject [`ReverseGeocoder`] and never
//! touch the network. The public OSM endpoint is not a product backend;
//! hosts inject the URL.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

mod cache;
mod nominatim;

pub use cache::{GeoCache, GeoCacheEntry, CACHE_RADIUS_KM, DISK_CACHE_VERSION};
pub use nominatim::{
    request_from_nominatim, Nominatim, NominatimAddress, DEFAULT_ENDPOINT, DEFAULT_USER_AGENT,
    MIN_LOOKUP_INTERVAL,
};

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use gallery_meta::places::PlaceWriteRequest;

/// Why a lookup failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeoError {
    /// Transient (timeout, 429, 5xx). The places loop may retry.
    Retryable(String),
    /// The server answered but we cannot use it.
    Fatal(String),
}

impl std::fmt::Display for GeoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GeoError::Retryable(d) | GeoError::Fatal(d) => write!(f, "{d}"),
        }
    }
}

impl std::error::Error for GeoError {}

/// One reverse-geocode. Tests inject a fake; the app uses [`Nominatim`].
pub trait ReverseGeocoder {
    /// Country / region / city for this coordinate. `Ok(None)` is a miss.
    fn lookup(&self, lat: f64, lon: f64) -> Result<Option<PlaceWriteRequest>, GeoError>;

    /// Floor between live calls. Fakes return zero.
    fn min_interval(&self) -> Duration {
        MIN_LOOKUP_INTERVAL
    }
}

/// Cache hit or a live lookup that is then stored.
pub fn resolve(
    cache: &mut GeoCache,
    geo: &dyn ReverseGeocoder,
    lat: f64,
    lon: f64,
) -> Result<Option<PlaceWriteRequest>, GeoError> {
    if let Some(hit) = cache.nearest(lat, lon) {
        return Ok(Some(hit.request()));
    }
    let request = geo.lookup(lat, lon)?;
    if let Some(ref req) = request {
        cache.insert(GeoCacheEntry::from_request(lat, lon, req.clone()));
    }
    Ok(request)
}

/// Haversine distance in kilometres. Same formula as the former Swift cache.
pub fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6371.0;
    let p1 = lat1.to_radians();
    let p2 = lat2.to_radians();
    let dp = (lat2 - lat1).to_radians();
    let dl = (lon2 - lon1).to_radians();
    let a = (dp / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().atan2((1.0 - a).sqrt())
}

/// Pace live lookups. `last` is updated when this returns `true`.
pub fn wait_until_allowed(
    last: &mut Option<Instant>,
    min_interval: Duration,
    cancel: &AtomicBool,
) -> bool {
    if let Some(prev) = *last {
        let mut remaining = min_interval.saturating_sub(prev.elapsed());
        while remaining > Duration::from_millis(1) {
            if cancel.load(Ordering::Relaxed) {
                return false;
            }
            let slice = remaining.min(Duration::from_millis(250));
            std::thread::sleep(slice);
            remaining = remaining.saturating_sub(slice);
        }
    }
    *last = Some(Instant::now());
    !cancel.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn haversine_is_small_for_the_same_street() {
        let d = haversine_km(48.8566, 2.3522, 48.8567, 2.3523);
        assert!(d < 0.05, "{d}");
        assert!(d > 0.0);
    }

    #[test]
    fn resolve_stores_a_live_hit() {
        struct Once;
        impl ReverseGeocoder for Once {
            fn lookup(&self, _lat: f64, _lon: f64) -> Result<Option<PlaceWriteRequest>, GeoError> {
                Ok(gallery_meta::place_from_parts(
                    Some("France"),
                    None,
                    Some("Paris"),
                    None,
                    Some("fr"),
                ))
            }
            fn min_interval(&self) -> Duration {
                Duration::ZERO
            }
        }
        let mut cache = GeoCache::default();
        let a = resolve(&mut cache, &Once, 48.85, 2.35).unwrap().unwrap();
        let b = resolve(&mut cache, &Once, 48.85, 2.35).unwrap().unwrap();
        assert_eq!(a.path, b.path);
        assert_eq!(cache.len(), 1);
    }
}
