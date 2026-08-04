//! What counts as a photo, what counts as a video, and what a live-photo pair
//! looks like.
//!
//! `FolderScanner` asks `UTType(filenameExtension:)` whether an extension
//! conforms to `.image` or `.movie`. There is no equivalent registry off
//! Apple's platforms, so this is a table — curated to agree with `UTType` on
//! everything a photo library realistically contains, and *deliberately*
//! conservative about the rest.
//!
//! Two consequences carried over verbatim:
//!
//! - **Classification is by extension only.** A PNG named `.jpg` is scanned as
//!   an image and a JPEG named `.txt` is never seen at all — while
//!   `MetadataReader` sniffs content and reads both (fixture landmine 16).
//! - **An extension-less file is skipped**, because `UTType(filenameExtension: "")`
//!   is nil, not because anything looked at its bytes.

use gallery_model::file_url::{extension_lowercased, stem};

/// Extensions `UTType` reports as conforming to `public.image`.
///
/// Ordered by how often they turn up, not alphabetically — this is a linear
/// scan on a hot path.
const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "heic", "png", "heif", "dng", "tiff", "tif", "webp", "gif", "bmp", "jpe",
    "jfif", "avif", "heics", "heifs", "avci", "avcs", "jp2", "j2k", "psd", "ico", "icns", "exr",
    "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw", "pef", "sr2", "erf", "3fr", "fff",
    "mos", "iiq", "rwl", "dcr", "kdc", "mrw", "x3f", "svg",
];

/// Extensions `UTType` reports as conforming to `public.movie`.
const VIDEO_EXTENSIONS: &[&str] = &[
    "mov", "mp4", "m4v", "qt", "avi", "mpg", "mpeg", "mpe", "m2v", "3gp", "3gpp", "3g2", "3gp2",
    "mts", "m2ts", "ts", "dv", "vfw",
];

/// The `.xmp` sidecar extension.
pub const SIDECAR_EXTENSION: &str = "xmp";

/// Extensions the live-photo stem stripper treats as an image suffix.
///
/// A **different, smaller** set than [`IMAGE_EXTENSIONS`], copied from
/// `FolderScanner`'s local `imageExtensions`. It exists so `IMG_0002.heic.mov`
/// pairs with `IMG_0002.heic`; widening it would change which files pair.
const LIVE_PAIR_IMAGE_EXTENSIONS: &[&str] = &[
    "heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "dng", "webp",
];

/// How the scanner classifies a filename.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    /// Conforms to `public.image`.
    Image,
    /// Conforms to `public.movie`.
    Video,
    /// A `.xmp` — an input to the sidecar manifest, never a photo row.
    Sidecar,
    /// Everything else: junk, dotfiles, extension-less files.
    Skipped,
}

/// Classify by extension, as `FolderScanner` does.
pub fn classify(name: &str) -> MediaKind {
    let ext = extension_lowercased(name);
    if ext.is_empty() {
        return MediaKind::Skipped;
    }
    if ext == SIDECAR_EXTENSION {
        return MediaKind::Sidecar;
    }
    if IMAGE_EXTENSIONS.contains(&ext.as_str()) {
        MediaKind::Image
    } else if VIDEO_EXTENSIONS.contains(&ext.as_str()) {
        MediaKind::Video
    } else {
        MediaKind::Skipped
    }
}

/// `.skipsHiddenFiles`: a leading dot hides the file.
///
/// Filtered here rather than in the VFS so the seam stays a plain directory
/// listing — the *policy* about dotfiles is the scanner's.
pub fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

/// The key a live-photo movie pairs on.
///
/// Lowercased basename with the last extension dropped, and then a *second*
/// extension dropped when it is an image one — which is what makes
/// `IMG_0002.heic.mov` find `IMG_0002.heic`.
///
/// This is also what a standalone video's `filename` becomes, and it is
/// **lowercased**: `Clip.MOV` shows up in the UI as `clip` while `B.JPG` keeps
/// its `B`, because the image branch uses the raw stem and the video branch
/// reuses this key (fixture landmine 22). Not a typo, and not fixed here.
pub fn video_stem(name: &str) -> String {
    let base = stem(name).to_lowercase();
    let inner_ext = extension_lowercased(&base);
    if LIVE_PAIR_IMAGE_EXTENSIONS.contains(&inner_ext.as_str()) {
        stem(&base).to_string()
    } else {
        base
    }
}

/// The key an image pairs on: its own lowercased stem.
pub fn image_stem_key(name: &str) -> String {
    stem(name).to_lowercase()
}

/// `<basename>.xmp` keys on the **lowercased full basename**, extension
/// included: `IMG_1234.heic` → `img_1234.heic`, `dotted.name.v2.jpg` →
/// `dotted.name.v2.jpg`.
pub fn sidecar_key(photo_name: &str) -> String {
    photo_name.to_lowercase()
}

/// The photo basename a `<photo>.xmp` claims, lowercased.
pub fn sidecar_owner_key(sidecar_name: &str) -> String {
    stem(sidecar_name).to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fixture_trees_extensions_classify_as_expected() {
        assert_eq!(classify("a.jpg"), MediaKind::Image);
        assert_eq!(classify("B.JPG"), MediaKind::Image);
        assert_eq!(classify("IMG_0002.heic"), MediaKind::Image);
        assert_eq!(classify("deep2.png"), MediaKind::Image);
        assert_eq!(classify("Clip.MOV"), MediaKind::Video);
        assert_eq!(classify("IMG_0001.mov"), MediaKind::Video);
        assert_eq!(classify("B.JPG.xmp"), MediaKind::Sidecar);
        assert_eq!(classify("readme.txt"), MediaKind::Skipped);
        assert_eq!(classify("data.xyz"), MediaKind::Skipped);
        assert_eq!(classify("noext"), MediaKind::Skipped);
    }

    #[test]
    fn a_leading_dot_is_a_hidden_file_not_an_extension() {
        assert!(is_hidden(".hidden.jpg"));
        assert!(!is_hidden("visible.jpg"));
        // `.hidden` has no extension at all, so it would be skipped anyway.
        assert_eq!(classify(".hidden"), MediaKind::Skipped);
    }

    #[test]
    fn double_extension_videos_pair_with_their_image() {
        assert_eq!(video_stem("IMG_0002.heic.mov"), "img_0002");
        assert_eq!(image_stem_key("IMG_0002.heic"), "img_0002");
        assert_eq!(video_stem("IMG_0001.mov"), "img_0001");
        assert_eq!(image_stem_key("IMG_0001.jpg"), "img_0001");
    }

    #[test]
    fn a_standalone_videos_stem_is_lowercased_and_an_images_is_not() {
        assert_eq!(video_stem("Clip.MOV"), "clip");
        assert_eq!(stem("B.JPG"), "B", "the image branch keeps its case");
    }

    #[test]
    fn a_video_stem_only_strips_a_second_extension_when_it_is_an_image_one() {
        // ".v2" is not an image extension, so it stays in the stem.
        assert_eq!(video_stem("clip.v2.mov"), "clip.v2");
        assert_eq!(video_stem("clip.tif.mov"), "clip");
    }

    #[test]
    fn sidecars_key_on_the_whole_lowercased_basename() {
        assert_eq!(sidecar_key("IMG_1234.heic"), "img_1234.heic");
        assert_eq!(sidecar_owner_key("IMG_1234.heic.xmp"), "img_1234.heic");
        assert_eq!(sidecar_key("dotted.name.v2.jpg"), "dotted.name.v2.jpg");
        assert_eq!(
            sidecar_owner_key("dotted.name.v2.jpg.xmp"),
            "dotted.name.v2.jpg"
        );
        assert_eq!(sidecar_key("B.JPG"), "b.jpg");
        assert_eq!(sidecar_owner_key("B.JPG.xmp"), "b.jpg");
    }
}
