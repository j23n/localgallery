//! In-memory [`Vfs`] for tests.
//!
//! Exists for two reasons: it keeps the sidecar-writer tests off the disk, and
//! it forces the trait to stay implementable by something that is not
//! `std::fs` — which is the whole point of the seam (Android SAF is next).

use std::collections::BTreeMap;
use std::io::Cursor;
use std::sync::{Mutex, PoisonError};

use crate::{ReadSeek, Stat, Vfs, VfsError, VfsResult};

/// A flat path → bytes map with directory semantics synthesised from the
/// path separators. `write_atomic` is trivially atomic here (one lock, one
/// map insert), which is exactly the behaviour callers may assume.
#[derive(Debug, Default)]
pub struct MemVfs {
    files: Mutex<BTreeMap<String, Vec<u8>>>,
}

impl MemVfs {
    /// An empty tree.
    pub fn new() -> Self {
        Self::default()
    }

    /// Seed a file, bypassing `write_atomic`.
    pub fn insert(&self, path: &str, bytes: impl Into<Vec<u8>>) {
        self.files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(path.to_string(), bytes.into());
    }

    /// Every path currently present, sorted.
    pub fn paths(&self) -> Vec<String> {
        self.files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .keys()
            .cloned()
            .collect()
    }

    /// True when some file lives under `path` as a directory prefix.
    fn is_dir(&self, path: &str) -> bool {
        let prefix = format!("{}/", path.trim_end_matches('/'));
        self.files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .keys()
            .any(|k| k.starts_with(&prefix))
    }
}

impl Vfs for MemVfs {
    fn open(&self, path: &str) -> VfsResult<Box<dyn ReadSeek + Send>> {
        let bytes = self.read(path)?;
        Ok(Box::new(Cursor::new(bytes)))
    }

    fn stat(&self, path: &str) -> VfsResult<Stat> {
        if let Some(bytes) = self
            .files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(path)
        {
            return Ok(Stat {
                size: bytes.len() as u64,
                modified_unix: Some(0),
                is_dir: false,
            });
        }
        if self.is_dir(path) {
            return Ok(Stat {
                size: 0,
                modified_unix: Some(0),
                is_dir: true,
            });
        }
        Err(VfsError::NotFound {
            path: path.to_string(),
        })
    }

    fn write_atomic(&self, path: &str, bytes: &[u8]) -> VfsResult<()> {
        if path.is_empty() {
            return Err(VfsError::InvalidPath {
                path: path.to_string(),
                reason: "empty path".into(),
            });
        }
        self.files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(path.to_string(), bytes.to_vec());
        Ok(())
    }

    fn exists(&self, path: &str) -> bool {
        self.stat(path).is_ok()
    }

    fn read(&self, path: &str) -> VfsResult<Vec<u8>> {
        self.files
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(path)
            .cloned()
            .ok_or_else(|| VfsError::NotFound {
                path: path.to_string(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::assert_vfs_contract;

    #[test]
    fn satisfies_the_vfs_contract() {
        let vfs = MemVfs::new();
        // A directory only exists once something is under it.
        vfs.insert("/lib/seed.txt", b"seed".to_vec());
        assert_vfs_contract(&vfs, "/lib");
    }

    #[test]
    fn insert_and_paths_round_trip() {
        let vfs = MemVfs::new();
        vfs.insert("/b.txt", b"2".to_vec());
        vfs.insert("/a.txt", b"1".to_vec());
        assert_eq!(
            vfs.paths(),
            vec!["/a.txt".to_string(), "/b.txt".to_string()]
        );
    }
}
