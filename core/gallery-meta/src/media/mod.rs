//! `MetadataReader`, ported.
//!
//! The scanner/enrichment read path: capture date, hierarchical tags, country
//! code, GPS and face regions for one photo, plus the creation date of one
//! video. Not the sidecar *cache* path — `SidecarSyncService` fetches bytes
//! its own way and hands them to [`swift_xmp::parse_xmp_bytes`] directly.
//!
//! Tags, country and face regions come from the sidecar only. ML and
//! geocoding write `.xmp` and never the image; a photo with no sidecar is
//! untagged until Scan writes one. Capture date and GPS still come from
//! EXIF in the image — those are camera facts, not our writes.

pub mod container;
pub mod embedded;
pub mod exif_read;
pub mod isobmff;
pub mod prefix;
pub mod swift_xmp;
pub mod video;

use gallery_model::date::CivilDateTime;
use gallery_model::photo::{FaceRegion, HierarchicalTag};
use gallery_vfs::Vfs;

pub use container::extract_xmp;
pub use embedded::{read_embedded_xmp, EmbeddedXmp};
pub use exif_read::{parse_exif_datetime, read_exif_facts, ExifFacts};
pub use prefix::read_metadata_prefix;
pub use swift_xmp::{decode_xmp_text, parse_mwg_regions, parse_xmp_bytes, SwiftXmpParse};
pub use video::{read_video_date, read_video_date_at};

/// Everything one photo contributes to a `PhotoFile`.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct ImageMetadata {
    /// EXIF capture date as a **zone-less wall clock**. The platform layer
    /// resolves it in the device zone, exactly as `exifDateFormatter` does.
    pub capture_wall_clock: Option<CivilDateTime>,
    /// Sidecar `digiKam:TagsList`, deduplicated.
    pub hierarchical_tags: Vec<HierarchicalTag>,
    /// Uppercase country code.
    pub country_code: Option<String>,
    /// Signed latitude.
    pub gps_latitude: Option<f64>,
    /// Signed longitude.
    pub gps_longitude: Option<f64>,
    /// Face regions from the sidecar.
    pub face_regions: Vec<FaceRegion>,
    /// TIFF orientation. Not part of the Swift reader's output; see
    /// [`ExifFacts::orientation`].
    pub orientation: Option<u16>,
}

/// Read `path` and its `.xmp` sidecar.
///
/// | field | source |
/// |---|---|
/// | tags, country, face regions | **sidecar only** |
/// | dates, GPS | **EXIF in the image** — a sidecar's `exif:DateTimeOriginal` and `exif:GPS*` are read by nobody |
///
/// The sidecar read is **unconditional**: it does not depend on the image
/// opening, which is why a zero-byte JPEG still comes back tagged
/// (`assets/containers/zero_byte.jpg`).
///
/// # The image itself is read in a bounded prefix, not whole
///
/// Enrichment runs this eight-wide, and a photo library contains 100 MB RAWs.
/// [`prefix::read_metadata_prefix`] reads only as far as the container's
/// metadata region can extend — the `SOS` marker for JPEG, the first `IDAT`
/// for PNG, a fixed cap otherwise — which is where both parsers below stopped
/// looking anyway. The narrow cases that changes are tabulated on that module.
pub fn read_image_metadata(vfs: &dyn Vfs, path: &str) -> ImageMetadata {
    let bytes = read_metadata_prefix(vfs, path);
    let exif = read_exif_facts(&bytes);
    let sidecar = read_sidecar(vfs, path);
    merge(exif, sidecar)
}

/// The `.xmp` next to `path`, parsed. Missing or unreadable ⇒ nothing.
fn read_sidecar(vfs: &dyn Vfs, path: &str) -> SwiftXmpParse {
    match crate::sidecar::read_sidecar_bytes(vfs, path) {
        Some(bytes) => parse_xmp_bytes(&bytes),
        None => SwiftXmpParse::default(),
    }
}

/// Sidecar tags / country / regions plus image EXIF date and GPS.
fn merge(exif: ExifFacts, sidecar: SwiftXmpParse) -> ImageMetadata {
    let mut seen: Vec<String> = Vec::new();
    let mut hierarchical_tags = Vec::new();
    for raw in sidecar.raw_tags {
        let key = raw.to_lowercase();
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        hierarchical_tags.push(HierarchicalTag::new(&raw));
    }

    ImageMetadata {
        capture_wall_clock: exif.capture_wall_clock,
        hierarchical_tags,
        country_code: sidecar.country_code,
        gps_latitude: exif.gps_latitude,
        gps_longitude: exif.gps_longitude,
        face_regions: sidecar
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
        orientation: exif.orientation,
    }
}

#[cfg(test)]
mod tests {
    use super::swift_xmp::SwiftFaceRegion;
    use super::*;

    fn region(name: &str, x: f64) -> SwiftFaceRegion {
        SwiftFaceRegion {
            name: Some(name.to_string()),
            center_x: x,
            center_y: 0.5,
            width: 0.1,
            height: 0.1,
        }
    }

    fn merged(sidecar: SwiftXmpParse) -> ImageMetadata {
        merge(ExifFacts::default(), sidecar)
    }

    #[test]
    fn tags_and_country_come_from_the_sidecar_only() {
        let out = merged(SwiftXmpParse {
            raw_tags: vec![
                "people/alice".into(),
                "Scenes/Beach".into(),
                "people/alice".into(),
            ],
            country_code: Some("FR".into()),
            ..Default::default()
        });
        assert_eq!(
            out.hierarchical_tags
                .iter()
                .map(|t| t.full_path.as_str())
                .collect::<Vec<_>>(),
            vec!["people/alice", "Scenes/Beach"]
        );
        assert_eq!(out.country_code.as_deref(), Some("FR"));
    }

    #[test]
    fn an_empty_sidecar_means_no_tags_or_regions() {
        let out = merged(SwiftXmpParse::default());
        assert!(out.hierarchical_tags.is_empty());
        assert!(out.face_regions.is_empty());
        assert_eq!(out.country_code, None);
    }

    #[test]
    fn sidecar_regions_are_kept() {
        let out = merged(SwiftXmpParse {
            face_regions: vec![region("SidecarFace", 0.51)],
            ..Default::default()
        });
        assert_eq!(out.face_regions.len(), 1);
        assert_eq!(out.face_regions[0].name.as_deref(), Some("SidecarFace"));
    }

    #[test]
    fn a_sidecars_dates_and_gps_are_read_by_nobody() {
        let out = merge(
            ExifFacts::default(),
            parse_xmp_bytes(
                b"<x><exif:DateTimeOriginal>1999:09:09 09:09:09</exif:DateTimeOriginal>\
                  <exif:GPSLatitude>48,51.29N</exif:GPSLatitude></x>",
            ),
        );
        assert_eq!(out.capture_wall_clock, None);
        assert_eq!(out.gps_latitude, None);
    }

    #[test]
    fn the_sidecar_is_read_even_when_the_image_does_not_open() {
        let vfs = gallery_vfs::MemVfs::new();
        vfs.insert("/lib/zero_byte.jpg", Vec::new());
        vfs.insert(
            "/lib/zero_byte.jpg.xmp",
            b"<digiKam:TagsList><rdf:Seq><rdf:li>Scenes/Void</rdf:li></rdf:Seq>\
              </digiKam:TagsList>"
                .to_vec(),
        );
        let out = read_image_metadata(&vfs, "/lib/zero_byte.jpg");
        assert_eq!(out.hierarchical_tags.len(), 1);
        assert_eq!(out.hierarchical_tags[0].display_name, "Void");
    }

    /// The enrichment pass runs this eight-wide over the library. Reading the
    /// whole file made that eight concurrent copies of whatever the largest
    /// files are — a 16 MB JPEG here, a 100 MB DNG in a real library.
    #[test]
    fn a_large_image_is_read_in_a_bounded_prefix_not_slurped() {
        use super::prefix::tests::{fat_jpeg, CountingVfs};

        let vfs = CountingVfs::new();
        let packet = br#"<digiKam:TagsList><rdf:Seq><rdf:li>Scenes/Beach</rdf:li></rdf:Seq></digiKam:TagsList>"#;
        vfs.insert("/lib/huge.jpg", fat_jpeg(packet, 16 << 20));
        vfs.insert("/lib/huge.jpg.xmp", packet.to_vec());

        let out = read_image_metadata(&vfs, "/lib/huge.jpg");
        assert_eq!(
            out.hierarchical_tags
                .iter()
                .map(|t| t.full_path.as_str())
                .collect::<Vec<_>>(),
            vec!["Scenes/Beach"],
            "tags come from the sidecar, not the JPEG packet"
        );
        assert!(
            vfs.bytes_read() < (1 << 20),
            "read {} bytes off a 16 MB image",
            vfs.bytes_read()
        );
    }

    #[test]
    fn embedded_xmp_in_the_image_is_not_read() {
        use super::prefix::tests::fat_jpeg;

        let vfs = gallery_vfs::MemVfs::new();
        let packet = br#"<digiKam:TagsList><rdf:Seq><rdf:li>Scenes/Beach</rdf:li></rdf:Seq></digiKam:TagsList>"#;
        vfs.insert("/lib/embedded.jpg", fat_jpeg(packet, 4096));
        let out = read_image_metadata(&vfs, "/lib/embedded.jpg");
        assert!(
            out.hierarchical_tags.is_empty(),
            "a JPEG packet is not a sidecar"
        );
        assert_eq!(out.country_code, None);
        assert!(out.face_regions.is_empty());
    }

    #[test]
    fn a_photo_with_no_metadata_and_no_sidecar_is_all_empty() {
        let vfs = gallery_vfs::MemVfs::new();
        vfs.insert("/lib/plain.jpg", b"not really a jpeg".to_vec());
        assert_eq!(
            read_image_metadata(&vfs, "/lib/plain.jpg"),
            ImageMetadata::default()
        );
    }
}
