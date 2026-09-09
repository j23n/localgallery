//! Typed photo-grid rows. Paths stay as [`PathBuf`] so a tab in a name is
//! not a field separator, and a non-UTF-8 name is reported rather than dropped.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use gallery_model::photo::PhotoFile;

/// One grid cell: index plus the fields the tile bind needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhotoRow {
    /// Position in the grid's photo list (viewer activate).
    pub index: usize,
    /// On-disk path. May contain tabs; may be non-UTF-8 if constructed by hand.
    pub path: PathBuf,
    /// Stable photo id, already a UTF-8 hex string.
    pub id: String,
    /// Video tiles skip the still thumbnail.
    pub is_video: bool,
}

/// A path that cannot cross a UTF-8 FFI (VFS, GTK labels, thumb decode).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsupportedPath {
    /// Lossy display form for diagnostics only.
    pub display: String,
}

impl std::fmt::Display for UnsupportedPath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "path is not valid UTF-8: {}", self.display)
    }
}

impl std::error::Error for UnsupportedPath {}

impl PhotoRow {
    /// Build from a scanned photo. `PhotoFile` paths are UTF-8 today; the
    /// [`PathBuf`] still keeps a tab as data rather than a delimiter.
    pub fn from_photo(index: usize, photo: &PhotoFile) -> Self {
        PhotoRow {
            index,
            path: PathBuf::from(photo.path()),
            id: photo.id.to_string(),
            is_video: photo.is_video,
        }
    }

    /// Path for UTF-8 FFI. [`Err`] is a diagnostic, never a silent skip.
    pub fn utf8_path(&self) -> Result<&str, UnsupportedPath> {
        utf8_path(&self.path)
    }
}

/// Require UTF-8. The VFS and GTK both need it; the caller surfaces the error.
pub fn utf8_path(path: &Path) -> Result<&str, UnsupportedPath> {
    path.to_str().ok_or_else(|| UnsupportedPath {
        display: path.display().to_string(),
    })
}

/// Diagnostic line for names `StdVfs` could not represent as UTF-8.
pub fn unsupported_names_message(names: &[OsString]) -> Option<String> {
    if names.is_empty() {
        return None;
    }
    let preview: Vec<String> = names
        .iter()
        .take(3)
        .map(|n| n.to_string_lossy().into_owned())
        .collect();
    let extra = names.len().saturating_sub(preview.len());
    let mut msg = format!(
        "Skipped {} item(s) whose names are not UTF-8 ({})",
        names.len(),
        preview.join(", ")
    );
    if extra > 0 {
        msg.push_str(&format!(", +{extra} more"));
    }
    Some(msg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_model::photo::PhotoFile;
    use std::ffi::OsString;
    #[cfg(unix)]
    use std::os::unix::ffi::OsStringExt;

    #[test]
    fn tab_in_the_path_is_not_a_field_break() {
        let photo = PhotoFile::new("/lib/foo\tbar.jpg", "foo\tbar", 12);
        let row = PhotoRow::from_photo(3, &photo);
        assert_eq!(row.index, 3);
        assert_eq!(row.path, PathBuf::from("/lib/foo\tbar.jpg"));
        assert_eq!(row.utf8_path().unwrap(), "/lib/foo\tbar.jpg");
        assert!(row.path.to_str().unwrap().contains('\t'));
        assert!(!row.is_video);
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_path_is_a_diagnostic_not_an_omission() {
        let path = PathBuf::from(OsString::from_vec(vec![0xff, 0xfe, b'.', b'j', b'p', b'g']));
        let row = PhotoRow {
            index: 0,
            path,
            id: "X".into(),
            is_video: false,
        };
        let err = row.utf8_path().unwrap_err();
        assert!(err.to_string().contains("not valid UTF-8"));
    }

    #[test]
    fn unsupported_names_message_lists_a_preview() {
        assert!(unsupported_names_message(&[]).is_none());
        let msg = unsupported_names_message(&[OsString::from("a"), OsString::from("b")]).unwrap();
        assert!(msg.contains("Skipped 2"));
        assert!(msg.contains("a"));
    }
}
