//! `MetadataReader`, ported.
//!
//! The scanner/enrichment read path: capture date, hierarchical tags, country
//! code, GPS and face regions for one photo, plus the creation date of one
//! video. Not the sidecar *cache* path — `SidecarSyncService` fetches bytes
//! its own way and hands them to [`swift_xmp::parse_xmp_bytes`] directly.
//!
//! The merge at the bottom of [`read_image_metadata`] is the only place the
//! sidecar-vs-embedded precedence table exists now. It used to live in a
//! comment in `MetadataReader.readImageMetadata`; the Swift copy goes away
//! with the swap, so this is the copy.

pub mod container;
pub mod embedded;
pub mod exif_read;
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
    /// Deduplicated tags, embedded first.
    pub hierarchical_tags: Vec<HierarchicalTag>,
    /// Uppercase country code.
    pub country_code: Option<String>,
    /// Signed latitude.
    pub gps_latitude: Option<f64>,
    /// Signed longitude.
    pub gps_longitude: Option<f64>,
    /// Face regions, sidecar-preferred.
    pub face_regions: Vec<FaceRegion>,
    /// TIFF orientation. Not part of the Swift reader's output; see
    /// [`ExifFacts::orientation`].
    pub orientation: Option<u16>,
}

/// Read `path` and its `.xmp` sidecar.
///
/// # Precedence, when both sources have something to say
///
/// | field | rule |
/// |---|---|
/// | tags | **union**, embedded first, case-insensitive first-wins dedup — so the *embedded* spelling of a conflicting path survives |
/// | `country_code` | **embedded wins**; the sidecar only fills a gap |
/// | `face_regions` | **sidecar wins outright** when it has any; embedded survive only when the sidecar has none |
/// | dates, GPS | **embedded only** — a sidecar's `exif:DateTimeOriginal` and `exif:GPS*` are read by nobody |
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
    let embedded = extract_xmp(&bytes)
        .map(|packet| read_embedded_xmp(&packet))
        .unwrap_or_default();
    let sidecar = read_sidecar(vfs, path);
    merge(exif, embedded, sidecar)
}

/// The `.xmp` next to `path`, parsed. Missing or unreadable ⇒ nothing.
fn read_sidecar(vfs: &dyn Vfs, path: &str) -> SwiftXmpParse {
    let sidecar_path = crate::sidecar::sidecar_path(path);
    match vfs.read(&sidecar_path) {
        Ok(bytes) => parse_xmp_bytes(&bytes),
        Err(_) => SwiftXmpParse::default(),
    }
}

/// Apply the precedence table. Split out so it can be tested without a VFS.
fn merge(exif: ExifFacts, embedded: EmbeddedXmp, sidecar: SwiftXmpParse) -> ImageMetadata {
    let mut raw_tags = embedded.raw_tags;
    raw_tags.extend(sidecar.raw_tags);

    let country_code = embedded.country_code.or(sidecar.country_code);

    let regions = if sidecar.face_regions.is_empty() {
        embedded.face_regions
    } else {
        sidecar.face_regions
    };

    // Dedup by lowercased path, first occurrence wins. Because the embedded
    // tags were appended first, an embedded "People/Alice" beats a sidecar
    // "people/alice" — the spelling that survives is the embedded one.
    let mut seen: Vec<String> = Vec::new();
    let mut hierarchical_tags = Vec::new();
    for raw in raw_tags {
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
        country_code,
        gps_latitude: exif.gps_latitude,
        gps_longitude: exif.gps_longitude,
        face_regions: regions
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

    fn merged(embedded: EmbeddedXmp, sidecar: SwiftXmpParse) -> ImageMetadata {
        merge(ExifFacts::default(), embedded, sidecar)
    }

    #[test]
    fn tags_union_with_the_embedded_spelling_surviving_a_case_conflict() {
        let out = merged(
            EmbeddedXmp {
                raw_tags: vec!["People/Alice".into(), "Objects/Car".into()],
                ..Default::default()
            },
            SwiftXmpParse {
                raw_tags: vec!["people/alice".into(), "Scenes/Beach".into()],
                ..Default::default()
            },
        );
        assert_eq!(
            out.hierarchical_tags
                .iter()
                .map(|t| t.full_path.as_str())
                .collect::<Vec<_>>(),
            vec!["People/Alice", "Objects/Car", "Scenes/Beach"]
        );
    }

    #[test]
    fn the_embedded_country_wins_and_the_sidecar_only_fills_a_gap() {
        let with_both = merged(
            EmbeddedXmp {
                country_code: Some("IT".into()),
                ..Default::default()
            },
            SwiftXmpParse {
                country_code: Some("FR".into()),
                ..Default::default()
            },
        );
        assert_eq!(with_both.country_code.as_deref(), Some("IT"));

        let gap = merged(
            EmbeddedXmp::default(),
            SwiftXmpParse {
                country_code: Some("NO".into()),
                ..Default::default()
            },
        );
        assert_eq!(gap.country_code.as_deref(), Some("NO"));
    }

    #[test]
    fn sidecar_regions_replace_embedded_ones_outright() {
        let replaced = merged(
            EmbeddedXmp {
                face_regions: vec![region("EmbeddedFace", 0.11)],
                ..Default::default()
            },
            SwiftXmpParse {
                face_regions: vec![region("SidecarFace", 0.51)],
                ..Default::default()
            },
        );
        assert_eq!(replaced.face_regions.len(), 1, "merged, not replaced");
        assert_eq!(
            replaced.face_regions[0].name.as_deref(),
            Some("SidecarFace")
        );

        // …but an empty sidecar region list leaves the embedded ones alone.
        let kept = merged(
            EmbeddedXmp {
                face_regions: vec![region("EmbeddedOnly", 0.21)],
                ..Default::default()
            },
            SwiftXmpParse::default(),
        );
        assert_eq!(kept.face_regions[0].name.as_deref(), Some("EmbeddedOnly"));
    }

    #[test]
    fn a_sidecars_dates_and_gps_are_read_by_nobody() {
        let out = merge(
            ExifFacts::default(),
            EmbeddedXmp::default(),
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

        let out = read_image_metadata(&vfs, "/lib/huge.jpg");
        assert_eq!(
            out.hierarchical_tags
                .iter()
                .map(|t| t.full_path.as_str())
                .collect::<Vec<_>>(),
            vec!["Scenes/Beach"],
            "the bounded read still finds the packet"
        );
        assert!(
            vfs.bytes_read() < (1 << 20),
            "read {} bytes off a 16 MB image",
            vfs.bytes_read()
        );
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
