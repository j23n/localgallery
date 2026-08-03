//! Where a photo's `.xmp` sidecar lives (schema §1.4).

/// `IMG_1234.jpg` → `IMG_1234.jpg.xmp`.
///
/// The extension is *appended*, not replaced — the MWG / digiKam convention —
/// so `IMG_1234.jpg` and `IMG_1234.heic` get distinct sidecars. This is also
/// the only form `MetadataReader.readXMPSidecar` looks for, so anything else
/// would be invisible to the app.
pub fn sidecar_path(image_path: &str) -> String {
    format!("{image_path}.xmp")
}

/// `IMG_1234.jpg` → `IMG_1234.xmp`, the Lightroom / Capture One convention.
///
/// **Read-side only** (schema §1.4). `None` when the input has no extension to
/// replace, or already is a `.xmp`.
pub fn alt_sidecar_path(image_path: &str) -> Option<String> {
    let file_start = image_path.rfind('/').map(|i| i + 1).unwrap_or(0);
    let dot = image_path[file_start..].rfind('.')? + file_start;
    if image_path[dot..].eq_ignore_ascii_case(".xmp") {
        return None;
    }
    Some(format!("{}.xmp", &image_path[..dot]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_form_preserves_the_image_suffix() {
        assert_eq!(sidecar_path("/a/IMG_1234.jpg"), "/a/IMG_1234.jpg.xmp");
        assert_eq!(sidecar_path("/a/IMG_1234.heic"), "/a/IMG_1234.heic.xmp");
    }

    #[test]
    fn alt_form_replaces_the_suffix() {
        assert_eq!(
            alt_sidecar_path("/a/IMG_1234.jpg").as_deref(),
            Some("/a/IMG_1234.xmp")
        );
    }

    #[test]
    fn alt_form_is_none_when_there_is_nothing_to_replace() {
        assert_eq!(alt_sidecar_path("/a/IMG_1234"), None);
        assert_eq!(alt_sidecar_path("/a/IMG_1234.xmp"), None);
        assert_eq!(alt_sidecar_path("/a/IMG_1234.XMP"), None);
    }

    #[test]
    fn a_dot_in_a_parent_directory_is_not_an_extension() {
        assert_eq!(alt_sidecar_path("/a.b/IMG_1234"), None);
        assert_eq!(
            alt_sidecar_path("/a.b/IMG_1234.jpg").as_deref(),
            Some("/a.b/IMG_1234.xmp")
        );
    }
}
