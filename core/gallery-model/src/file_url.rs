//! `file://` URL strings, the way `Foundation.URL` writes and reads them.
//!
//! `PhotoFile.url` is persisted as `URL.absoluteString`, so the snapshot's
//! identity keys are percent-encoded URL strings and nothing else. Getting the
//! escaping wrong does not corrupt anything visibly — it produces a snapshot
//! Swift decodes into a *different* path, which reads as "every photo is new"
//! on the next launch.

/// Characters `Foundation` leaves unescaped in a file URL's path.
///
/// `CharacterSet.urlPathAllowed` = unreserved + sub-delims + `:@` + `/`.
/// Notably **absent**: space, `?`, `#`, `[`, `]`, `%`, and everything
/// non-ASCII — all of which appear in real photo libraries.
fn is_path_allowed(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@/".contains(&b)
}

/// Absolute filesystem path → `file:///…` absolute string.
///
/// The path bytes are taken verbatim; no normalization happens here. On APFS
/// the on-disk spelling *is* the identity (see the fixture README's Unicode
/// section), and `stable_uuid` hashes those same bytes.
pub fn file_url_string(path: &str) -> String {
    let mut out = String::with_capacity(path.len() + 8);
    out.push_str("file://");
    if !path.starts_with('/') {
        out.push('/');
    }
    for &b in path.as_bytes() {
        if is_path_allowed(b) {
            out.push(b as char);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

/// Inverse of [`file_url_string`]. `None` for anything that is not a
/// `file://` URL or whose escapes do not decode to UTF-8.
pub fn path_from_file_url(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("file://localhost")
        .or_else(|| url.strip_prefix("file://"))?;
    // An authority component other than `localhost` (a UNC-style host) has no
    // filesystem path this app could open.
    if !rest.starts_with('/') {
        return None;
    }
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16)?;
            let lo = (bytes[i + 2] as char).to_digit(16)?;
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Last path component of a `/`-separated path. `""` for the root.
pub fn last_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(i) => &trimmed[i + 1..],
        None => trimmed,
    }
}

/// The component with its final `.ext` removed, or the whole thing when there
/// is no extension.
///
/// Mirrors `URL.deletingPathExtension().lastPathComponent`: only the **last**
/// dot counts, so `dotted.name.v2.jpg` → `dotted.name.v2`, and a leading dot
/// is not an extension (`.hidden` stays `.hidden`).
pub fn stem(name: &str) -> &str {
    match name.rfind('.') {
        Some(0) | None => name,
        Some(i) => &name[..i],
    }
}

/// Lowercased extension without the dot; empty when there is none.
pub fn extension_lowercased(name: &str) -> String {
    match name.rfind('.') {
        Some(0) | None => String::new(),
        Some(i) => name[i + 1..].to_lowercase(),
    }
}

/// Join a directory path and a child name with a single separator.
pub fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spaces_and_non_ascii_are_percent_encoded() {
        // Byte-for-byte the fixture's decomposed-U-umlaut entry.
        assert_eq!(
            file_url_string("/fixtures/PhotoLibrary/2021/Trip/U\u{308}nicode cafe\u{301}.jpg"),
            "file:///fixtures/PhotoLibrary/2021/Trip/U%CC%88nicode%20cafe%CC%81.jpg"
        );
    }

    #[test]
    fn sub_delims_stay_literal_but_fragment_markers_do_not() {
        assert_eq!(
            file_url_string("/a/spaces and (parens).jpg"),
            "file:///a/spaces%20and%20(parens).jpg"
        );
        assert_eq!(file_url_string("/a/b#c?d.jpg"), "file:///a/b%23c%3Fd.jpg");
    }

    #[test]
    fn round_trips_through_a_url_string() {
        for path in [
            "/a/b.jpg",
            "/a/emoji \u{1F335} cactus.jpg",
            "/a/caf\u{65}\u{301}.jpg",
            "/a/100% real.jpg",
        ] {
            let url = file_url_string(path);
            assert_eq!(path_from_file_url(&url).as_deref(), Some(path), "{url}");
        }
    }

    #[test]
    fn rejects_urls_that_are_not_local_files() {
        assert_eq!(path_from_file_url("https://example.com/a.jpg"), None);
        assert_eq!(path_from_file_url("file://server/share/a.jpg"), None);
        assert_eq!(
            path_from_file_url("file://localhost/a/b.jpg").as_deref(),
            Some("/a/b.jpg")
        );
    }

    #[test]
    fn stems_drop_only_the_last_extension() {
        assert_eq!(stem("dotted.name.v2.jpg"), "dotted.name.v2");
        assert_eq!(stem("B.JPG"), "B");
        assert_eq!(stem("noext"), "noext");
        assert_eq!(stem(".hidden"), ".hidden");
        assert_eq!(extension_lowercased("B.JPG"), "jpg");
        assert_eq!(extension_lowercased("noext"), "");
        assert_eq!(extension_lowercased(".hidden"), "");
    }

    #[test]
    fn last_component_handles_trailing_slashes_and_the_root() {
        assert_eq!(last_component("/a/b/c.jpg"), "c.jpg");
        assert_eq!(last_component("/a/b/"), "b");
        assert_eq!(last_component("/"), "");
        assert_eq!(join("/a", "b.jpg"), "/a/b.jpg");
        assert_eq!(join("/a/", "b.jpg"), "/a/b.jpg");
    }
}
