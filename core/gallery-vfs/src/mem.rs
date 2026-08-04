//! In-memory [`Vfs`] for tests.
//!
//! Exists for two reasons: it keeps the sidecar-writer tests off the disk, and
//! it forces the trait to stay implementable by something that is not
//! `std::fs` — which is the whole point of the seam (Android SAF is next).

use std::collections::{BTreeMap, BTreeSet};
use std::io::Cursor;
use std::sync::{Mutex, PoisonError};

use crate::{Entry, EntryKind, FileTime, ReadSeek, Stat, Vfs, VfsError, VfsResult};

/// A flat path → bytes map with directory semantics synthesised from the
/// path separators. `write_atomic` is trivially atomic here (one lock, one
/// map insert), which is exactly the behaviour callers may assume.
#[derive(Debug, Default)]
pub struct MemVfs {
    files: Mutex<BTreeMap<String, Vec<u8>>>,
    times: Mutex<BTreeMap<String, FileTime>>,
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

    /// Seed a file *and* its modification time, for scanner tests that need a
    /// change signal. `insert` leaves the mtime at the epoch.
    pub fn insert_at(&self, path: &str, bytes: impl Into<Vec<u8>>, modified: FileTime) {
        self.insert(path, bytes);
        self.times
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(path.to_string(), modified);
    }

    /// Modification time of `path`, defaulting to the epoch.
    fn time_of(&self, path: &str) -> FileTime {
        self.times
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(path)
            .copied()
            .unwrap_or_default()
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

    /// Children of `dir`, synthesised from the path separators.
    ///
    /// Directories exist only implicitly here, so a listing is "the distinct
    /// next segment of every key under `dir/`". Names are returned sorted,
    /// which the trait does not promise but makes the tests readable.
    fn list(&self, dir: &str) -> VfsResult<Vec<Entry>> {
        let stat = self.stat(dir)?;
        if !stat.is_dir {
            return Err(VfsError::NotADirectory {
                path: dir.to_string(),
            });
        }
        let prefix = format!("{}/", dir.trim_end_matches('/'));
        let mut names: BTreeSet<(String, bool)> = BTreeSet::new();
        {
            let files = self.files.lock().unwrap_or_else(PoisonError::into_inner);
            for key in files.keys() {
                let Some(rest) = key.strip_prefix(&prefix) else {
                    continue;
                };
                match rest.split_once('/') {
                    Some((head, _)) => names.insert((head.to_string(), true)),
                    None => names.insert((rest.to_string(), false)),
                };
            }
        }
        Ok(names
            .into_iter()
            .map(|(name, is_dir)| {
                let path = format!("{prefix}{name}");
                let modified = self.time_of(&path);
                Entry {
                    kind: if is_dir {
                        EntryKind::Dir
                    } else {
                        EntryKind::File
                    },
                    size: if is_dir {
                        0
                    } else {
                        self.read(&path).map(|b| b.len() as u64).unwrap_or(0)
                    },
                    modified: Some(modified),
                    created: Some(modified),
                    name,
                }
            })
            .collect())
    }

    fn stat_entry(&self, path: &str) -> VfsResult<Entry> {
        let stat = self.stat(path)?;
        let modified = self.time_of(path);
        Ok(Entry {
            name: path
                .trim_end_matches('/')
                .rsplit('/')
                .next()
                .unwrap_or("")
                .to_string(),
            kind: if stat.is_dir {
                EntryKind::Dir
            } else {
                EntryKind::File
            },
            size: stat.size,
            modified: Some(modified),
            created: Some(modified),
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
