//! Who is up for tagging / faces / places.

use gallery_meta::places::places_still_needed;
use gallery_model::photo::{PhotoFile, PhotoLocality};

/// Still, bytes on disk. Remote placeholders are not tagged or geocoded.
pub fn is_ml_eligible(photo: &PhotoFile) -> bool {
    if photo.is_video {
        return false;
    }
    !matches!(photo.locality, PhotoLocality::Remote { downloaded: false })
}

/// Downloaded still with GPS.
pub fn is_places_candidate(photo: &PhotoFile) -> bool {
    is_ml_eligible(photo) && photo.gps_latitude.is_some() && photo.gps_longitude.is_some()
}

/// Queue + write skip: finished city-depth `Places/*` is left alone unless
/// `force`. Uses the tags the caller already has (library row or sidecar).
pub fn places_needed(tags: impl IntoIterator<Item = impl AsRef<str>>, force: bool) -> bool {
    if force {
        return true;
    }
    places_still_needed(tags)
}

/// In-memory tags on the library row.
pub fn photo_place_needed(photo: &PhotoFile, force: bool) -> bool {
    is_places_candidate(photo)
        && places_needed(
            photo.hierarchical_tags.iter().map(|t| t.full_path.as_str()),
            force,
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_model::photo::HierarchicalTag;

    #[test]
    fn videos_and_placeholders_are_out() {
        let mut p = PhotoFile::new("/a.jpg", "a", 1);
        p.gps_latitude = Some(1.0);
        p.gps_longitude = Some(2.0);
        assert!(is_ml_eligible(&p));
        p.is_video = true;
        assert!(!is_ml_eligible(&p));
        p.is_video = false;
        p.locality = PhotoLocality::Remote { downloaded: false };
        assert!(!is_ml_eligible(&p));
        assert!(!is_places_candidate(&p));
    }

    #[test]
    fn finished_places_path_skips_unless_forced() {
        let mut p = PhotoFile::new("/a.jpg", "a", 1);
        p.gps_latitude = Some(48.8);
        p.gps_longitude = Some(2.3);
        p.hierarchical_tags = vec![HierarchicalTag::new("Places/France/Île-de-France/Paris")];
        assert!(!photo_place_needed(&p, false));
        assert!(photo_place_needed(&p, true));
        p.hierarchical_tags = vec![HierarchicalTag::new("Places/France")];
        assert!(photo_place_needed(&p, false));
    }
}
