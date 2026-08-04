//! `std::fs`-backed [`Vfs`]. The only implementation the shipping app uses.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{Entry, EntryKind, FileTime, ReadSeek, Stat, Vfs, VfsError, VfsResult, TEMP_PREFIX};

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

/// How many symlink hops [`resolve_symlink`] will follow before giving up.
/// Generous: real sidecars are symlinked at most once, into a synced folder.
const MAX_SYMLINK_HOPS: usize = 32;

/// Follow a symlinked target to the real file, so a write goes *through* the
/// link instead of replacing it.
///
/// Without this, replacing `IMG.jpg.xmp` (a symlink into a synced folder) with
/// the temp file turns the link into an ordinary file: the new metadata lands
/// somewhere the user's other tools do not look, and the real file keeps its
/// stale contents forever. Both copies then read as plausible.
///
/// A path that does not exist — the common case, a sidecar being created — is
/// returned unchanged. A dangling symlink resolves to what it points at, which
/// is where the user asked for the bytes to go.
fn resolve_symlink(path: &Path) -> VfsResult<PathBuf> {
    let mut current = path.to_path_buf();
    for _ in 0..MAX_SYMLINK_HOPS {
        let Ok(md) = fs::symlink_metadata(&current) else {
            return Ok(current);
        };
        if !md.file_type().is_symlink() {
            return Ok(current);
        }
        let link = fs::read_link(&current)
            .map_err(|e| VfsError::from_io(&current.display().to_string(), &e))?;
        current = match (link.is_absolute(), current.parent()) {
            (false, Some(dir)) => dir.join(link),
            _ => link,
        };
    }
    Err(VfsError::InvalidPath {
        path: path.display().to_string(),
        reason: format!("symlink chain longer than {MAX_SYMLINK_HOPS} hops"),
    })
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
        "{TEMP_PREFIX}{}-{}-{}",
        std::process::id(),
        n,
        nanos
    )))
}

/// `SystemTime` → [`FileTime`], for times before *and* after the epoch.
fn file_time(t: SystemTime) -> FileTime {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => FileTime::new(d.as_secs() as i64, d.subsec_nanos()),
        Err(e) => {
            // Pre-1970. `duration_since` reports the magnitude of the gap, so
            // the seconds are negated and the sub-second remainder borrows.
            let d = e.duration();
            match d.subsec_nanos() {
                0 => FileTime::new(-(d.as_secs() as i64), 0),
                n => FileTime::new(-(d.as_secs() as i64) - 1, 1_000_000_000 - n),
            }
        }
    }
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

    fn list(&self, dir: &str) -> VfsResult<Vec<Entry>> {
        let reader = fs::read_dir(dir).map_err(|e| VfsError::from_io(dir, &e))?;
        let mut out = Vec::new();
        for item in reader {
            let item = item.map_err(|e| VfsError::from_io(dir, &e))?;
            // Non-UTF-8 names are dropped rather than lossily converted: a
            // replacement character would derive a stable id for a path that
            // cannot be reopened. Vanishingly rare on APFS, which stores UTF-8.
            let Ok(name) = item.file_name().into_string() else {
                continue;
            };
            if name.starts_with(TEMP_PREFIX) {
                continue;
            }
            // `DirEntry::metadata` does not traverse symlinks, so a link is
            // reported as a link and carries the link's own size and times.
            // Following it here would let a link into a scanned subtree
            // duplicate every photo under it.
            let link_md = item
                .metadata()
                .map_err(|e| VfsError::from_io(&format!("{dir}/{name}"), &e))?;
            let kind = if link_md.file_type().is_symlink() {
                EntryKind::Symlink
            } else if link_md.is_dir() {
                EntryKind::Dir
            } else {
                EntryKind::File
            };
            out.push(Entry {
                name,
                kind,
                size: if link_md.is_dir() { 0 } else { link_md.len() },
                modified: link_md.modified().ok().map(file_time),
                created: link_md.created().ok().map(file_time),
                is_file_provider: false,
                is_placeholder: false,
                content_version: None,
            });
        }
        Ok(out)
    }

    fn stat_entry(&self, path: &str) -> VfsResult<Entry> {
        let link_md = fs::symlink_metadata(path).map_err(|e| VfsError::from_io(path, &e))?;
        // Unlike `list`, this **follows**: the caller named one path and wants
        // to know about the thing at the end of it, which is what
        // `resourceValues(forKeys:)` reports. A user who picks a symlinked
        // folder should see that folder's dates, not the link's. A dangling
        // link falls back to the link itself rather than failing.
        let md = fs::metadata(path).unwrap_or_else(|_| link_md.clone());
        let name = Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let kind = if link_md.file_type().is_symlink() {
            EntryKind::Symlink
        } else if md.is_dir() {
            EntryKind::Dir
        } else {
            EntryKind::File
        };
        Ok(Entry {
            name,
            kind,
            size: if md.is_dir() { 0 } else { md.len() },
            modified: md.modified().ok().map(file_time),
            created: md.created().ok().map(file_time),
            is_file_provider: false,
            is_placeholder: false,
            content_version: None,
        })
    }

    fn write_atomic(&self, path: &str, bytes: &[u8]) -> VfsResult<()> {
        let target = resolve_symlink(Path::new(path))?;
        let temp = temp_sibling(&target)?;
        let temp_str = temp.display().to_string();

        // Permissions of the file we are about to replace. A fresh temp file
        // gets 0666 & !umask — usually 0644 — so replacing a deliberately
        // private 0600 sidecar would quietly publish it to every other user on
        // the machine. Copy the mode across instead.
        let existing_perms = fs::metadata(&target).ok().map(|md| md.permissions());

        // Scoped so the handle is closed (and flushed) before the rename.
        let write_result = (|| -> std::io::Result<()> {
            let mut f = fs::File::create(&temp)?;
            f.write_all(bytes)?;
            if let Some(perms) = existing_perms {
                f.set_permissions(perms)?;
            }
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

        if let Err(e) = fs::rename(&temp, &target) {
            let _ = fs::remove_file(&temp);
            return Err(VfsError::from_io(path, &e));
        }

        // fsync the directory too. `f.sync_all()` made the *contents* durable;
        // the directory entry the rename created is a separate write, and a
        // crash between the two can leave the old name pointing at nothing.
        // Best-effort: opening a directory for this is not portable, and a
        // failure here does not make the write any less correct than it was
        // before this line existed.
        if let Some(parent) = target.parent().filter(|p| !p.as_os_str().is_empty()) {
            if let Ok(dir) = fs::File::open(parent) {
                let _ = dir.sync_all();
            }
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

    #[cfg(unix)]
    #[test]
    fn write_atomic_preserves_the_mode_of_the_file_it_replaces() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.xmp");
        fs::write(&p, b"old").unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o600)).unwrap();

        StdVfs.write_atomic(p.to_str().unwrap(), b"new").unwrap();

        let mode = fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the replacement widened the file's mode");
        assert_eq!(fs::read(&p).unwrap(), b"new");
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_writes_through_a_symlink_instead_of_replacing_it() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real.xmp");
        let link = dir.path().join("link.xmp");
        fs::write(&real, b"old").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        StdVfs.write_atomic(link.to_str().unwrap(), b"new").unwrap();

        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink(),
            "the symlink was replaced by a regular file"
        );
        assert_eq!(
            fs::read(&real).unwrap(),
            b"new",
            "the real file kept stale contents"
        );
    }

    #[cfg(unix)]
    #[test]
    fn write_atomic_refuses_a_symlink_loop_rather_than_spinning() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.xmp");
        let b = dir.path().join("b.xmp");
        std::os::unix::fs::symlink(&b, &a).unwrap();
        std::os::unix::fs::symlink(&a, &b).unwrap();

        let err = StdVfs.write_atomic(a.to_str().unwrap(), b"x").unwrap_err();
        assert!(matches!(err, VfsError::InvalidPath { .. }), "{err:?}");
    }

    #[test]
    fn list_reports_kinds_and_keeps_dotfiles() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.jpg"), b"xx").unwrap();
        fs::write(dir.path().join(".hidden.jpg"), b"y").unwrap();
        fs::create_dir(dir.path().join("Sub")).unwrap();

        let mut listing = StdVfs.list(dir.path().to_str().unwrap()).unwrap();
        listing.sort_by(|a, b| a.name.cmp(&b.name));
        let named: Vec<(&str, EntryKind, u64)> = listing
            .iter()
            .map(|e| (e.name.as_str(), e.kind, e.size))
            .collect();
        assert_eq!(
            named,
            vec![
                (".hidden.jpg", EntryKind::File, 1),
                ("Sub", EntryKind::Dir, 0),
                ("a.jpg", EntryKind::File, 2),
            ],
            "hidden-file filtering belongs to the scanner, not the VFS"
        );
        assert!(listing.iter().all(|e| e.modified.is_some()));
    }

    #[cfg(unix)]
    #[test]
    fn list_reports_a_symlink_as_a_symlink() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("real")).unwrap();
        std::os::unix::fs::symlink(dir.path().join("real"), dir.path().join("link")).unwrap();

        let listing = StdVfs.list(dir.path().to_str().unwrap()).unwrap();
        let link = listing.iter().find(|e| e.name == "link").unwrap();
        assert_eq!(
            link.kind,
            EntryKind::Symlink,
            "resolving here is how a traversal walks into a cycle"
        );
    }

    #[cfg(unix)]
    #[test]
    fn stat_entry_follows_a_symlink_where_list_does_not() {
        // A user who picks a symlinked folder should see the folder's dates.
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        fs::create_dir(&real).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();

        let entry = StdVfs.stat_entry(link.to_str().unwrap()).unwrap();
        assert_eq!(entry.kind, EntryKind::Symlink, "the link is still a link");
        assert_eq!(
            entry.modified,
            StdVfs.stat_entry(real.to_str().unwrap()).unwrap().modified,
            "…but its times come from what it points at"
        );
    }

    #[test]
    fn list_keeps_sub_second_modification_times() {
        // The light-scan cache-hit rule is `cached.modDate == entry.modDate`
        // on Swift `Date`s, which are Doubles. Truncating to whole seconds
        // would make a file rewritten 400 ms later read as unchanged.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.jpg");
        fs::write(&path, b"x").unwrap();
        let stamp = UNIX_EPOCH + std::time::Duration::new(1_600_000_000, 400_000_000);
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(stamp)
            .unwrap();

        let listing = StdVfs.list(dir.path().to_str().unwrap()).unwrap();
        let entry = &listing[0];
        assert_eq!(entry.modified.unwrap().secs, 1_600_000_000);
        assert_eq!(entry.modified.unwrap().subsec_nanos, 400_000_000);
        assert!((entry.modified.unwrap().as_secs_f64() - 1_600_000_000.4).abs() < 1e-6);
    }

    #[test]
    fn file_time_handles_dates_before_the_epoch() {
        let t = UNIX_EPOCH - std::time::Duration::new(1, 250_000_000);
        assert_eq!(file_time(t), FileTime::new(-2, 750_000_000));
        assert_eq!(file_time(UNIX_EPOCH), FileTime::new(0, 0));
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
