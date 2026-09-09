//! Same-directory temp write + flush/sync + rename for app JSON.
//!
//! Config, the library snapshot, and the geocode cache all go through here so
//! a crash cannot leave a half-written file under the real name. New
//! directories are created `0700` and files land `0600`. An existing app-owned
//! directory is tightened; existing parent XDG directories are not.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};

/// Application directory mode (`drwx------`).
pub const DIR_MODE: u32 = 0o700;
/// Sensitive file mode (`rw-------`).
pub const FILE_MODE: u32 = 0o600;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Create `dir` (and missing parents) at [`DIR_MODE`].
///
/// An already-present `dir` is tightened to [`DIR_MODE`] (the app-owned
/// cache/config folder). Existing ancestors — `~/.cache`, `~/.config`,
/// `/tmp`, or whatever XDG parent already existed — are left untouched.
pub fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    if dir.as_os_str().is_empty() {
        return Ok(());
    }
    if dir.exists() {
        return tighten_dir_mode(dir);
    }
    if let Some(parent) = dir.parent().filter(|p| !p.as_os_str().is_empty()) {
        create_missing_private_ancestors(parent)?;
    }
    create_private_dir(dir, true)
}

/// Create missing ancestors at [`DIR_MODE`] without chmod of a directory
/// that already exists.
fn create_missing_private_ancestors(dir: &Path) -> io::Result<()> {
    if dir.as_os_str().is_empty() || dir.exists() {
        return Ok(());
    }
    if let Some(parent) = dir.parent().filter(|p| !p.as_os_str().is_empty()) {
        create_missing_private_ancestors(parent)?;
    }
    create_private_dir(dir, false)
}

/// Create `dir` at [`DIR_MODE`]. `AlreadyExists` is ignored; the target
/// (`tighten_if_exists`) is the only existing directory we will chmod.
fn create_private_dir(dir: &Path, tighten_if_exists: bool) -> io::Result<()> {
    #[cfg(unix)]
    {
        match fs::DirBuilder::new().mode(DIR_MODE).create(dir) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                if tighten_if_exists {
                    tighten_dir_mode(dir)
                } else {
                    Ok(())
                }
            }
            Err(e) => Err(e),
        }
    }
    #[cfg(not(unix))]
    {
        match fs::create_dir(dir) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                if tighten_if_exists {
                    tighten_dir_mode(dir)
                } else {
                    Ok(())
                }
            }
            Err(e) => Err(e),
        }
    }
}

/// Force an existing directory to [`DIR_MODE`]. Missing paths are ignored.
pub fn tighten_dir_mode(dir: &Path) -> io::Result<()> {
    if dir.as_os_str().is_empty() || !dir.is_dir() {
        return Ok(());
    }
    #[cfg(unix)]
    {
        let mut perms = fs::metadata(dir)?.permissions();
        if perms.mode() & 0o777 != DIR_MODE {
            perms.set_mode(DIR_MODE);
            fs::set_permissions(dir, perms)?;
        }
    }
    let _ = dir;
    Ok(())
}

/// Force an existing file to [`FILE_MODE`]. Missing paths are ignored.
pub fn tighten_file_mode(path: &Path) -> io::Result<()> {
    if !path.is_file() {
        return Ok(());
    }
    #[cfg(unix)]
    {
        let mut perms = fs::metadata(path)?.permissions();
        if perms.mode() & 0o777 != FILE_MODE {
            perms.set_mode(FILE_MODE);
            fs::set_permissions(path, perms)?;
        }
    }
    let _ = path;
    Ok(())
}

/// Read a file and tighten its mode if it is still present.
pub fn read_private(path: &Path) -> io::Result<Vec<u8>> {
    let bytes = fs::read(path)?;
    let _ = tighten_file_mode(path);
    Ok(bytes)
}

/// Write `bytes` via a sibling temp file, `fsync`, then `rename`.
///
/// The temp name lives in the same directory as `path` so the rename cannot
/// cross filesystems. On any write or rename failure the temp file is removed.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "path has no parent directory")
        })?;
    ensure_private_dir(parent)?;
    let temp = temp_sibling(path)?;

    let write_result = (|| -> io::Result<()> {
        let mut opts = OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            opts.mode(FILE_MODE);
        }
        let mut f = opts.open(&temp)?;
        f.write_all(bytes)?;
        #[cfg(unix)]
        {
            f.set_permissions(fs::Permissions::from_mode(FILE_MODE))?;
        }
        f.sync_all()?;
        Ok(())
    })();

    if let Err(e) = write_result {
        let _ = fs::remove_file(&temp);
        return Err(e);
    }

    if let Err(e) = fs::rename(&temp, path) {
        let _ = fs::remove_file(&temp);
        return Err(e);
    }

    let _ = tighten_file_mode(path);
    if let Ok(dir) = File::open(parent) {
        let _ = dir.sync_all();
    }
    Ok(())
}

fn temp_sibling(path: &Path) -> io::Result<std::path::PathBuf> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "path has no parent directory")
        })?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[cfg(unix)]
    fn mode_full(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o7777
    }

    #[test]
    fn write_atomic_replaces_and_leaves_no_temp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        write_atomic(&path, b"first").unwrap();
        write_atomic(&path, b"second").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"second");
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .filter(|n| n.to_string_lossy().starts_with(".gallery-tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_creates_private_dir_and_file() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("localgallery");
        let path = nested.join("config.json");
        write_atomic(&path, b"{}").unwrap();
        assert_eq!(mode(&nested), DIR_MODE);
        assert_eq!(mode(&path), FILE_MODE);
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_tightens_an_existing_wide_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.json");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        write_atomic(&path, b"new").unwrap();
        assert_eq!(mode(&path), FILE_MODE);
        assert_eq!(fs::read(&path).unwrap(), b"new");
    }

    #[cfg(unix)]
    #[test]
    fn ensure_private_dir_tightens_an_existing_wide_directory() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("localgallery");
        fs::create_dir(&nested).unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o755)).unwrap();
        ensure_private_dir(&nested).unwrap();
        assert_eq!(mode(&nested), DIR_MODE);
    }

    #[cfg(unix)]
    #[test]
    fn ensure_private_dir_does_not_chmod_an_existing_parent() {
        let dir = tempfile::tempdir().unwrap();
        let xdg = dir.path().join("cache");
        fs::create_dir(&xdg).unwrap();
        fs::set_permissions(&xdg, fs::Permissions::from_mode(0o755)).unwrap();
        let app = xdg.join("localgallery");
        ensure_private_dir(&app).unwrap();
        assert_eq!(mode(&app), DIR_MODE);
        assert_eq!(mode(&xdg), 0o755, "existing XDG parent must stay 0755");
    }

    #[cfg(unix)]
    #[test]
    fn ensure_private_dir_creates_a_private_chain_without_touching_an_ancestor() {
        let dir = tempfile::tempdir().unwrap();
        let ancestor = dir.path().join("tmp-like");
        fs::create_dir(&ancestor).unwrap();
        fs::set_permissions(&ancestor, fs::Permissions::from_mode(0o1777)).unwrap();
        let nested = ancestor.join("xdg").join("localgallery");
        ensure_private_dir(&nested).unwrap();
        assert_eq!(mode(&nested), DIR_MODE);
        assert_eq!(mode(&ancestor.join("xdg")), DIR_MODE);
        assert_eq!(
            mode_full(&ancestor),
            0o1777,
            "existing /tmp-like ancestor must stay world-writable"
        );
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_does_not_chmod_an_existing_parent() {
        let dir = tempfile::tempdir().unwrap();
        let xdg = dir.path().join("config");
        fs::create_dir(&xdg).unwrap();
        fs::set_permissions(&xdg, fs::Permissions::from_mode(0o755)).unwrap();
        let path = xdg.join("localgallery").join("config.json");
        write_atomic(&path, b"{}").unwrap();
        assert_eq!(mode(&xdg), 0o755);
        assert_eq!(mode(path.parent().unwrap()), DIR_MODE);
        assert_eq!(mode(&path), FILE_MODE);
    }

    #[cfg(unix)]
    #[test]
    fn read_private_tightens_an_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("snap.json");
        fs::write(&path, b"abc").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(read_private(&path).unwrap(), b"abc");
        assert_eq!(mode(&path), FILE_MODE);
    }
}
