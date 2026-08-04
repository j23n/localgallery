//! Materialising `scanner_tree.json`, and the VFS the conformance runner uses.

use std::fs;
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gallery_vfs::{Entry, ProviderAttrs, ReadSeek, Stat, StdVfs, Vfs, VfsResult};
use serde::Deserialize;

/// The fixture directory, shared with `LocalGalleryTests` and `gallery-model`.
pub fn fixtures_dir() -> PathBuf {
    [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "fixtures",
        "scan-conformance",
    ]
    .iter()
    .collect()
}

// ---------------------------------------------------------------------------
// scanner_tree.json
// ---------------------------------------------------------------------------

/// The input tree, described in JSON so Swift and Rust build the same bytes.
#[derive(Deserialize)]
pub struct ScannerTree {
    /// Directory name the library is created under. Fixed, not random: it is
    /// the root `PhotoFolder`'s `name` and therefore part of the expectation.
    pub root: String,
    pub initial: Vec<TreeEntry>,
    pub mutations: Vec<Mutation>,
}

#[derive(Deserialize)]
pub struct TreeEntry {
    pub dir: Option<String>,
    pub file: Option<String>,
    pub size: Option<usize>,
    pub fill: Option<String>,
    pub mtime: Option<String>,
}

#[derive(Deserialize)]
pub struct Mutation {
    /// `create` · `delete` · `rewrite` · `lockDirectory`
    pub op: String,
    pub path: String,
    pub size: Option<usize>,
    pub fill: Option<String>,
    pub mtime: Option<String>,
}

impl ScannerTree {
    pub fn load() -> ScannerTree {
        let path = fixtures_dir().join("scanner_tree.json");
        let bytes = fs::read(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        serde_json::from_slice(&bytes).expect("scanner_tree.json does not match its shape")
    }

    /// Create the library under `base` and return its root path.
    pub fn materialize(&self, base: &Path) -> PathBuf {
        let root = base.join(&self.root);
        fs::create_dir_all(&root).unwrap();
        for entry in &self.initial {
            if let Some(dir) = &entry.dir {
                fs::create_dir_all(root.join(dir)).unwrap();
            } else if let Some(file) = &entry.file {
                write_file(
                    &root.join(file),
                    entry.size.unwrap_or(0),
                    entry.fill.as_deref().unwrap_or("0"),
                    entry.mtime.as_deref(),
                );
            }
        }
        root
    }

    /// Apply every mutation in order; returns the directories chmod-000'd so
    /// the caller can restore them (a leaked unreadable directory breaks the
    /// temp-dir cleanup, and then the *next* run's).
    pub fn mutate(&self, root: &Path) -> Vec<PathBuf> {
        let mut locked = Vec::new();
        for m in &self.mutations {
            let path = root.join(&m.path);
            match m.op.as_str() {
                "create" | "rewrite" => write_file(
                    &path,
                    m.size.unwrap_or(0),
                    m.fill.as_deref().unwrap_or("0"),
                    m.mtime.as_deref(),
                ),
                "delete" => fs::remove_file(&path).unwrap(),
                "lockDirectory" => {
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
                    locked.push(path);
                }
                other => panic!("unknown mutation op {other}"),
            }
        }
        locked
    }
}

/// Restore chmod-000'd directories. Idempotent.
pub fn unlock(paths: &[PathBuf]) {
    for path in paths {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o755));
    }
}

/// Write filler bytes with an explicit modification time.
///
/// Rust's path APIs hand the bytes to `open(2)` untouched, so an NFC name in
/// the JSON lands on disk as NFC. Foundation's would decompose it — which is
/// why the Swift harness has to go through `open(2)` by hand and why this one
/// does not.
fn write_file(path: &Path, size: usize, fill: &str, mtime: Option<&str>) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let byte = fill.as_bytes().first().copied().unwrap_or(b'0');
    let mut file = fs::File::create(path).unwrap();
    if size > 0 {
        file.write_all(&vec![byte; size]).unwrap();
    }
    // After the write, always: the mtime is the scanner's change-detection key
    // and, being older than the file's birth time, it is also what
    // `earliest(creation, modification)` picks — which is what makes
    // `dateTaken` reproducible.
    if let Some(mtime) = mtime {
        file.set_modified(parse_iso_utc(mtime)).unwrap();
    }
}

/// `yyyy-MM-ddTHH:mm:ssZ` → `SystemTime`.
fn parse_iso_utc(raw: &str) -> SystemTime {
    let n = |range: std::ops::Range<usize>| raw[range].parse::<i64>().unwrap();
    let secs = gallery_model::date::CivilDateTime {
        year: n(0..4) as i32,
        month: n(5..7) as u32,
        day: n(8..10) as u32,
        hour: n(11..13) as u32,
        minute: n(14..16) as u32,
        second: n(17..19) as u32,
    }
    .as_naive_unix_secs();
    UNIX_EPOCH + Duration::from_secs(secs as u64)
}

// ---------------------------------------------------------------------------
// The VFS
// ---------------------------------------------------------------------------

/// [`StdVfs`] plus the one thing APFS gives the Swift baseline and `std::fs`
/// does not: a per-file content identifier.
///
/// The fixture pins `versionHasContentIdentifier: true`, because
/// `NSURLFileContentIdentifierKey` is populated on APFS and
/// `ContentVersion.sameContent` then compares identifiers rather than
/// `(mtime, size)`. `StdVfs` reports `None` by design — provider awareness
/// belongs to the platform implementation — so the runner supplies the inode,
/// which is what that key is on a local volume. This is a stand-in for the
/// iOS `Vfs`, not a shortcut around the assertion: without it the manifest
/// rows would be compared with that field permanently false.
pub struct ApfsLikeVfs(pub StdVfs);

impl ApfsLikeVfs {
    pub fn new() -> Self {
        ApfsLikeVfs(StdVfs::new())
    }
}

fn content_identifier(path: &str) -> Option<String> {
    fs::metadata(path).ok().map(|md| md.ino().to_string())
}

impl Vfs for ApfsLikeVfs {
    fn open(&self, path: &str) -> VfsResult<Box<dyn ReadSeek + Send>> {
        self.0.open(path)
    }

    fn stat(&self, path: &str) -> VfsResult<Stat> {
        self.0.stat(path)
    }

    fn list(&self, dir: &str) -> VfsResult<Vec<Entry>> {
        self.0.list(dir)
    }

    fn stat_entry(&self, path: &str) -> VfsResult<Entry> {
        self.0.stat_entry(path)
    }

    fn probe_provider(&self, paths: &[String]) -> Vec<ProviderAttrs> {
        paths
            .iter()
            .map(|path| ProviderAttrs {
                is_file_provider: false,
                is_placeholder: false,
                content_version: content_identifier(path),
                // APFS populates `totalFileSizeKey`, and for a local file it
                // is the same number `stat` reports — so this vends it, and
                // the fixture values are unchanged by its existence.
                intended_size: fs::metadata(path).ok().map(|md| md.len() as i64),
            })
            .collect()
    }

    fn write_atomic(&self, path: &str, bytes: &[u8]) -> VfsResult<()> {
        self.0.write_atomic(path, bytes)
    }

    fn exists(&self, path: &str) -> bool {
        self.0.exists(path)
    }
}

/// Whether this process can be fooled by `chmod 000` at all.
///
/// Running as root defeats the unreadable-directory case entirely — the
/// listing succeeds and the carry-forward assertions would pass for the wrong
/// reason. Better to say so than to go green.
pub fn chmod_is_effective(dir: &Path) -> bool {
    fs::read_dir(dir).is_err()
}
