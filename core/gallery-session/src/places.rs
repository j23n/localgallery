//! Places pass: eligibility, cache, Nominatim, sidecar write.

use std::sync::atomic::{AtomicBool, Ordering};

use gallery_geo::{resolve, wait_until_allowed, GeoCache, GeoError, ReverseGeocoder};
use gallery_meta::places::write_places;
use gallery_meta::read_view;
use gallery_meta::sidecar::{alt_sidecar_path, sidecar_path};
use gallery_model::photo::PhotoFile;
use gallery_vfs::Vfs;

use crate::eligibility::{is_places_candidate, places_needed};

/// What one Places pass did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PlacesSummary {
    /// Photos considered (eligible at the start of the pass).
    pub considered: usize,
    /// Sidecars actually written.
    pub written: usize,
    /// Lookups that returned nothing or already-placed writes.
    pub skipped: usize,
    /// Hard failures (after retries).
    pub failed: usize,
    /// Paths whose sidecar changed.
    pub written_paths: Vec<String>,
    /// The run stopped early.
    pub cancelled: bool,
    /// First hard error, if any.
    pub error: Option<String>,
}

/// Walk `photos`, look up each eligible still, write sidecars.
///
/// Queue uses in-memory tags. The write skip re-reads the sidecar so a
/// finished city on disk is not overwritten when the row is stale.
pub fn run_places(
    vfs: &dyn Vfs,
    photos: &[PhotoFile],
    geo: &dyn ReverseGeocoder,
    cache: &mut GeoCache,
    force: bool,
    cancel: &AtomicBool,
    on_progress: Option<&dyn Fn(usize, usize)>,
) -> PlacesSummary {
    let queue: Vec<&PhotoFile> = photos
        .iter()
        .filter(|p| is_places_candidate(p) && (force || places_needed(row_tags(p), false)))
        .collect();
    let total = queue.len();
    let mut summary = PlacesSummary {
        considered: total,
        ..PlacesSummary::default()
    };
    if let Some(cb) = on_progress {
        cb(0, total);
    }
    let mut last_lookup = None;
    for (i, photo) in queue.into_iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            summary.cancelled = true;
            break;
        }
        if !force && !sidecar_places_needed(vfs, photo.path()) {
            summary.skipped += 1;
            if let Some(cb) = on_progress {
                cb(i + 1, total);
            }
            continue;
        }
        let (Some(lat), Some(lon)) = (photo.gps_latitude, photo.gps_longitude) else {
            summary.skipped += 1;
            continue;
        };
        if cache.nearest(lat, lon).is_none()
            && !wait_until_allowed(&mut last_lookup, geo.min_interval(), cancel)
        {
            summary.cancelled = true;
            break;
        }
        let request = match resolve(cache, geo, lat, lon) {
            Ok(Some(req)) => req,
            Ok(None) => {
                summary.skipped += 1;
                continue;
            }
            Err(GeoError::Retryable(e)) | Err(GeoError::Fatal(e)) => {
                summary.failed += 1;
                if summary.error.is_none() {
                    summary.error = Some(e);
                }
                continue;
            }
        };
        match write_places(vfs, photo.path(), &request) {
            Ok(outcome) if outcome.written => {
                summary.written += 1;
                summary.written_paths.push(photo.path().to_string());
            }
            Ok(_) => summary.skipped += 1,
            Err(e) => {
                summary.failed += 1;
                if summary.error.is_none() {
                    summary.error = Some(e.to_string());
                }
            }
        }
        if let Some(cb) = on_progress {
            cb(i + 1, total);
        }
    }
    summary
}

fn row_tags(photo: &PhotoFile) -> impl Iterator<Item = &str> {
    photo.hierarchical_tags.iter().map(|t| t.full_path.as_str())
}

fn sidecar_places_needed(vfs: &dyn Vfs, image_path: &str) -> bool {
    let tags = sidecar_tag_paths(vfs, image_path);
    places_needed(tags, false)
}

fn sidecar_tag_paths(vfs: &dyn Vfs, image_path: &str) -> Vec<String> {
    let target = sidecar_path(image_path);
    let bytes = if vfs.exists(&target) {
        vfs.read(&target).ok()
    } else {
        alt_sidecar_path(image_path).and_then(|alt| {
            if vfs.exists(&alt) {
                vfs.read(&alt).ok()
            } else {
                None
            }
        })
    };
    let Some(bytes) = bytes else {
        return Vec::new();
    };
    let Ok(view) = read_view(&bytes) else {
        return Vec::new();
    };
    view.tags_list
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_geo::ReverseGeocoder;
    use gallery_meta::place_from_parts;
    use gallery_model::photo::HierarchicalTag;
    use gallery_vfs::MemVfs;
    use std::time::Duration;

    struct FakeGeo;

    impl ReverseGeocoder for FakeGeo {
        fn lookup(
            &self,
            _lat: f64,
            _lon: f64,
        ) -> Result<Option<gallery_meta::PlaceWriteRequest>, GeoError> {
            Ok(place_from_parts(
                Some("France"),
                Some("Île-de-France"),
                Some("Paris"),
                None,
                Some("fr"),
            ))
        }
        fn min_interval(&self) -> Duration {
            Duration::ZERO
        }
    }

    fn still_with_gps() -> PhotoFile {
        let mut p = PhotoFile::new("/lib/a.jpg", "a", 12);
        p.gps_latitude = Some(48.8566);
        p.gps_longitude = Some(2.3522);
        p
    }

    #[test]
    fn run_writes_sidecar_through_vfs() {
        let vfs = MemVfs::new();
        vfs.write_atomic("/lib/a.jpg", b"not-a-jpeg").unwrap();
        let mut cache = GeoCache::new();
        let summary = run_places(
            &vfs,
            &[still_with_gps()],
            &FakeGeo,
            &mut cache,
            false,
            &AtomicBool::new(false),
            None,
        );
        assert_eq!(summary.written, 1);
        assert!(vfs.exists("/lib/a.jpg.xmp"));
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn finished_sidecar_is_skipped_even_if_row_is_empty() {
        let vfs = MemVfs::new();
        vfs.write_atomic("/lib/a.jpg", b"x").unwrap();
        let req = place_from_parts(
            Some("France"),
            Some("Île-de-France"),
            Some("Paris"),
            None,
            Some("fr"),
        )
        .unwrap();
        write_places(&vfs, "/lib/a.jpg", &req).unwrap();
        let mut cache = GeoCache::new();
        let summary = run_places(
            &vfs,
            &[still_with_gps()],
            &FakeGeo,
            &mut cache,
            false,
            &AtomicBool::new(false),
            None,
        );
        assert_eq!(summary.written, 0);
        assert!(summary.skipped >= 1);
    }

    #[test]
    fn shallow_row_tag_stays_eligible() {
        let mut p = still_with_gps();
        p.hierarchical_tags = vec![HierarchicalTag::new("Places/France")];
        let vfs = MemVfs::new();
        vfs.write_atomic("/lib/a.jpg", b"x").unwrap();
        let mut cache = GeoCache::new();
        let summary = run_places(
            &vfs,
            &[p],
            &FakeGeo,
            &mut cache,
            false,
            &AtomicBool::new(false),
            None,
        );
        assert_eq!(summary.written, 1);
    }
}
