//! Filesystem abstraction for the gallery core.
//!
//! The core never touches `std::fs` directly; it goes through [`Vfs`] so the
//! same code runs against a real directory ([`StdVfs`]), an in-memory tree
//! ([`MemVfs`], tests), and — later — Android SAF handles.
//!
//! v1 is path-based on purpose: on iOS/simulator Swift resolves the
//! security-scoped root and starts access before calling in, so the core only
//! ever sees plain paths under an active scope. Handle-based `list()` lands in
//! Phase 3 with the scanner port.
//!
//! # Atomic writes
//!
//! [`Vfs::write_atomic`] is the only write primitive. It must never leave a
//! partially written file visible: sidecars are read concurrently by
//! `SidecarSyncService` and by cloud daemons, and a half-written `.xmp` is
//! indistinguishable from a corrupt one.

#![forbid(unsafe_code)]

mod error;
mod mem;
mod std_vfs;

use std::io::{Read, Seek};

pub use error::{VfsError, VfsResult};
pub use mem::MemVfs;
pub use std_vfs::StdVfs;

/// A readable, seekable byte stream. Blanket-implemented, so `File`,
/// `Cursor<Vec<u8>>`, … all qualify.
pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// Metadata about one filesystem entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stat {
    /// Size in bytes (0 for directories).
    pub size: u64,
    /// Last-modified time as whole seconds since the Unix epoch, when the
    /// platform reports one. Sub-second precision is deliberately dropped —
    /// it is not portable and the scanner only ever compares at 1s.
    pub modified_unix: Option<i64>,
    /// Whether the entry is a directory.
    pub is_dir: bool,
}

/// The filesystem seam.
///
/// Implementations must be `Send + Sync`: the core runs file IO on its own
/// thread pool and shares one `Vfs` across all workers.
pub trait Vfs: Send + Sync {
    /// Open `path` for reading.
    fn open(&self, path: &str) -> VfsResult<Box<dyn ReadSeek + Send>>;

    /// Metadata for `path`. Symlinks are followed.
    fn stat(&self, path: &str) -> VfsResult<Stat>;

    /// Write `bytes` to `path` such that readers see either the old contents
    /// or the complete new contents — never anything in between.
    ///
    /// Implementations write to a temporary file **in the same directory** as
    /// `path` and rename it into place; a rename across filesystems is not
    /// atomic, and `/tmp` is frequently a different volume.
    ///
    /// # Guarantees when the file already exists
    ///
    /// - **Permissions are preserved.** A fresh temp file would otherwise pick
    ///   up the process umask, so replacing a 0600 sidecar would widen it.
    /// - **Symlinks are followed, not replaced.** If `path` is a symlink the
    ///   bytes go to the file it points at; the link survives as a link.
    ///   Replacing it would leave the real file holding stale metadata while a
    ///   second, divergent copy appears where nothing looks for it.
    /// - **The rename is fsync'd**, contents first and then the containing
    ///   directory, so a crash cannot leave the name pointing at unwritten
    ///   blocks.
    ///
    /// # Known limitations (deliberately not fixed)
    ///
    /// - **Extended attributes are lost.** macOS quarantine flags, Finder tags
    ///   and cloud-provider xattrs live on the *inode*, and the replacement is
    ///   a new inode. Copying them across needs platform-specific calls
    ///   (`listxattr`/`getxattr`/`setxattr`) that this crate does not yet make.
    ///   Nothing in the app reads sidecar xattrs today; a Finder tag on an
    ///   `.xmp` is the realistic casualty.
    /// - **A crash mid-write orphans the temp file.** It is named
    ///   `.gallery-tmp-<pid>-<n>-<nanos>`, so it is hidden and skipped by the
    ///   scanner like any other dotfile, but nothing sweeps it afterwards.
    ///   TODO: a startup sweep of `.gallery-tmp-*` older than an hour, once
    ///   the core owns directory enumeration (Phase 3's `list()`).
    fn write_atomic(&self, path: &str, bytes: &[u8]) -> VfsResult<()>;

    /// Whether `path` exists. Never fails — a path that cannot be stat'd for
    /// any reason reads as absent.
    fn exists(&self, path: &str) -> bool;

    /// Read all of `path` into memory.
    ///
    /// Provided so callers that only need the bytes (the sidecar reader) do
    /// not each reimplement the `open` + `read_to_end` dance. Implementations
    /// backed by a whole-file store may override it.
    fn read(&self, path: &str) -> VfsResult<Vec<u8>> {
        let mut reader = self.open(path)?;
        let mut buf = Vec::new();
        reader
            .read_to_end(&mut buf)
            .map_err(|e| VfsError::from_io(path, &e))?;
        Ok(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every `Vfs` impl must satisfy this. Called from each impl's test module.
    pub(crate) fn assert_vfs_contract(vfs: &dyn Vfs, dir: &str) {
        let file = format!("{dir}/contract.txt");

        assert!(!vfs.exists(&file));
        assert_eq!(
            vfs.stat(&file),
            Err(VfsError::NotFound { path: file.clone() })
        );

        vfs.write_atomic(&file, b"hello").unwrap();
        assert!(vfs.exists(&file));
        assert_eq!(vfs.read(&file).unwrap(), b"hello");
        assert_eq!(vfs.stat(&file).unwrap().size, 5);
        assert!(!vfs.stat(&file).unwrap().is_dir);

        // Overwrite replaces wholesale, not appends.
        vfs.write_atomic(&file, b"bye").unwrap();
        assert_eq!(vfs.read(&file).unwrap(), b"bye");
        assert_eq!(vfs.stat(&file).unwrap().size, 3);

        // Empty writes are legal.
        vfs.write_atomic(&file, b"").unwrap();
        assert_eq!(vfs.read(&file).unwrap(), b"");

        assert!(vfs.stat(dir).unwrap().is_dir);
    }

    #[test]
    fn error_carries_path() {
        let e = VfsError::NotFound {
            path: "/a/b".into(),
        };
        assert_eq!(e.path(), "/a/b");
        assert_eq!(e.to_string(), "not found: /a/b");
    }
}
