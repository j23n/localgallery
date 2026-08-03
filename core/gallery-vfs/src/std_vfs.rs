//! `std::fs`-backed [`Vfs`]. The only implementation the shipping app uses.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{ReadSeek, Stat, Vfs, VfsError, VfsResult};

/// Monotonic suffix so two writers in one process never pick the same temp
/// name. Combined with the pid this is enough — the temp file lives for
/// microseconds and is unlinked on every failure path.
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// A [`Vfs`] over the real filesystem.
///
/// Paths are used verbatim: no root, no sandboxing, no normalization. On iOS
/// the caller has already started the security scope for the enclosing folder.
#[derive(Debug, Default, Clone, Copy)]
pub struct StdVfs;

impl StdVfs {
    /// Construct one. Stateless; cloning is free.
    pub fn new() -> Self {
        StdVfs
    }
}

/// `foo/bar.xmp` → `foo/.gallery-tmp-<pid>-<n>.xmp`.
///
/// The temp file is a sibling so the rename stays within one filesystem, and
/// its name is dot-prefixed so a concurrent scan skips it the way it skips
/// every other dotfile.
fn temp_sibling(path: &Path) -> VfsResult<PathBuf> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let parent = match parent {
        Some(p) => p.to_path_buf(),
        None => {
            return Err(VfsError::InvalidPath {
                path: path.display().to_string(),
                reason: "no parent directory to write the temp file into".into(),
            })
        }
    };
    let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    Ok(parent.join(format!(
        ".gallery-tmp-{}-{}-{}",
        std::process::id(),
        n,
        nanos
    )))
}

impl Vfs for StdVfs {
    fn open(&self, path: &str) -> VfsResult<Box<dyn ReadSeek + Send>> {
        let file = fs::File::open(path).map_err(|e| VfsError::from_io(path, &e))?;
        Ok(Box::new(file))
    }

    fn stat(&self, path: &str) -> VfsResult<Stat> {
        let md = fs::metadata(path).map_err(|e| VfsError::from_io(path, &e))?;
        let modified_unix = md
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64);
        Ok(Stat {
            size: if md.is_dir() { 0 } else { md.len() },
            modified_unix,
            is_dir: md.is_dir(),
        })
    }

    fn write_atomic(&self, path: &str, bytes: &[u8]) -> VfsResult<()> {
        let target = Path::new(path);
        let temp = temp_sibling(target)?;
        let temp_str = temp.display().to_string();

        // Scoped so the handle is closed (and flushed) before the rename.
        let write_result = (|| -> std::io::Result<()> {
            let mut f = fs::File::create(&temp)?;
            f.write_all(bytes)?;
            // fsync: a rename is atomic w.r.t. other readers, but without the
            // sync a crash can leave the renamed entry pointing at unwritten
            // blocks. Sidecars are the portable truth (overview §4); pay it.
            f.sync_all()?;
            Ok(())
        })();

        if let Err(e) = write_result {
            let _ = fs::remove_file(&temp);
            return Err(VfsError::from_io(&temp_str, &e));
        }

        if let Err(e) = fs::rename(&temp, target) {
            let _ = fs::remove_file(&temp);
            return Err(VfsError::from_io(path, &e));
        }
        Ok(())
    }

    fn exists(&self, path: &str) -> bool {
        fs::metadata(path).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::assert_vfs_contract;

    #[test]
    fn satisfies_the_vfs_contract() {
        let dir = tempfile::tempdir().unwrap();
        assert_vfs_contract(&StdVfs, dir.path().to_str().unwrap());
    }

    #[test]
    fn write_atomic_leaves_no_temp_files_behind() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.xmp");
        StdVfs.write_atomic(p.to_str().unwrap(), b"x").unwrap();
        let entries: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(entries, vec!["a.xmp".to_string()]);
    }

    #[test]
    fn write_atomic_replaces_an_existing_file_in_one_step() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.xmp");
        fs::write(&p, b"old contents, longer").unwrap();
        StdVfs.write_atomic(p.to_str().unwrap(), b"new").unwrap();
        assert_eq!(fs::read(&p).unwrap(), b"new");
    }

    #[test]
    fn write_atomic_into_a_missing_directory_reports_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("nope").join("a.xmp");
        let err = StdVfs.write_atomic(p.to_str().unwrap(), b"x").unwrap_err();
        assert!(matches!(err, VfsError::NotFound { .. }), "{err:?}");
    }

    #[test]
    fn write_atomic_rejects_a_path_without_a_parent() {
        let err = StdVfs.write_atomic("", b"x").unwrap_err();
        assert!(matches!(err, VfsError::InvalidPath { .. }), "{err:?}");
    }

    #[test]
    fn open_reports_not_found_for_a_missing_file() {
        let Err(err) = StdVfs.open("/definitely/not/here.xmp") else {
            panic!("expected an error opening a missing file");
        };
        assert!(matches!(err, VfsError::NotFound { .. }), "{err:?}");
    }

    #[test]
    fn temp_siblings_are_unique_and_adjacent() {
        let a = temp_sibling(Path::new("/x/y/IMG.jpg.xmp")).unwrap();
        let b = temp_sibling(Path::new("/x/y/IMG.jpg.xmp")).unwrap();
        assert_ne!(a, b);
        assert_eq!(a.parent(), Some(Path::new("/x/y")));
        assert!(a
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with(".gallery-tmp-"));
    }
}
