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

/// Name of the temp file [`Vfs::write_atomic`] uses, so listings can skip it.
pub const TEMP_PREFIX: &str = ".gallery-tmp-";

/// A readable, seekable byte stream. Blanket-implemented, so `File`,
/// `Cursor<Vec<u8>>`, … all qualify.
pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// A wall-clock instant with sub-second precision, as the platform reports it.
///
/// Whole seconds plus nanoseconds rather than a single float because the two
/// consumers want different things: the snapshot encodes Apple's
/// seconds-since-2001 `Double`, and a `stat` is naturally integral.
///
/// # Why sub-seconds are carried
///
/// [`Stat::modified_unix`] drops them — it predates the scanner and only ever
/// fed 1-second comparisons. [`Entry`] must not: the light-scan cache-hit rule
/// is Swift's `cached.fileModificationDate == entry.modified`, and a Swift
/// `Date` is a `Double` of seconds, so two mtimes 500 ms apart are **not**
/// equal there. Truncating to whole seconds would make the Rust scanner
/// silently treat a modified file as unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct FileTime {
    /// Whole seconds since the Unix epoch. Negative before 1970.
    pub secs: i64,
    /// Sub-second remainder in nanoseconds, `0..1_000_000_000`.
    pub subsec_nanos: u32,
}

impl FileTime {
    /// Split a `SystemTime`-derived `(secs, nanos)` pair.
    pub fn new(secs: i64, subsec_nanos: u32) -> Self {
        FileTime { secs, subsec_nanos }
    }

    /// Seconds since the Unix epoch as a float, sub-seconds included.
    ///
    /// This is the form the scanner compares in, because it is the form
    /// Foundation's `Date` compares in: `Date` is a `Double`, so anything
    /// finer than its ~microsecond resolution at present-day magnitudes is
    /// invisible to Swift too.
    pub fn as_secs_f64(self) -> f64 {
        self.secs as f64 + f64::from(self.subsec_nanos) / 1e9
    }
}

/// Metadata about one filesystem entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stat {
    /// Size in bytes (0 for directories).
    pub size: u64,
    /// Last-modified time as whole seconds since the Unix epoch, when the
    /// platform reports one. Sub-second precision is deliberately dropped —
    /// it is not portable and the sidecar writer only ever compares at 1s.
    /// Directory enumeration goes through [`Entry`], which keeps them.
    pub modified_unix: Option<i64>,
    /// Whether the entry is a directory.
    pub is_dir: bool,
}

/// What a directory entry *is*.
///
/// Symlinks are reported as [`EntryKind::Symlink`] rather than resolved: the
/// scanner classifies by extension and never follows a link into a second
/// subtree, and a resolved-then-followed link is how a traversal ends up in a
/// cycle.
///
/// The *kind* is the only thing that stays unresolved. An entry's size and
/// timestamps come from the link's target — see [`Entry::size`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EntryKind {
    /// A regular file.
    File,
    /// A directory.
    Dir,
    /// A symbolic link (target not resolved).
    Symlink,
}

/// One row of a directory listing.
///
/// Everything the scanner needs about a file arrives here, in **one** call per
/// directory. That granularity is the whole point (`_plans/06` Finding 1): the
/// Swift baseline pays a per-file `resourceValues` round-trip to `fileproviderd`
/// — ~20 ms each, fully serial, 99.4% of a cold scan. The trait stays
/// per-directory so an implementation is free to batch or parallelise the
/// provider attribute reads behind it; the core never asks for one file at a
/// time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Final path component, byte-exact as the platform reports it.
    ///
    /// **Not normalized.** APFS hands back the spelling the file was created
    /// with, and `stable_uuid` hashes UTF-8 bytes, so normalizing here would
    /// change every id for NFC-named files arriving from outside.
    pub name: String,
    /// File, directory, or symlink.
    pub kind: EntryKind,
    /// Size in bytes. 0 for directories.
    ///
    /// For a [`EntryKind::Symlink`] this is the **target's** size, not the
    /// link's — `lstat` would report the length of the target path string, so
    /// a symlinked photo would arrive claiming to be a dozen bytes and its
    /// `(size, mtime)` change signal could never fire. The Swift baseline read
    /// these through `resourceValues(forKeys:)`, which follows. A dangling
    /// link falls back to the link's own values.
    pub size: u64,
    /// Last-modified time, when the platform reports one. Followed through a
    /// symlink, like [`Entry::size`].
    pub modified: Option<FileTime>,
    /// Creation ("birth") time, when the platform reports one.
    ///
    /// Not in the original Phase-3 sketch, and load-bearing anyway: the
    /// scanner's fallback capture date is `min(creation, modification)`
    /// (`MetadataReader.earliestFilesystemDate`), which cannot be computed
    /// without it.
    pub created: Option<FileTime>,
}

/// What the platform knows about a file that a `stat` cannot say.
///
/// Deliberately *not* part of [`Entry`]. On iOS every field here costs one
/// blocking XPC round trip to `fileproviderd` (~20 ms), and the scanner needs
/// them for a small minority of the files it walks: a light scan that hits the
/// cache for every photo asks for **none**. Folding them into the listing
/// would make the cheap path pay the expensive path's bill — which is exactly
/// `_plans/06` Finding 1, restated one layer down.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProviderAttrs {
    /// Whether the entry belongs to a file provider (iCloud Drive, OneDrive,
    /// Dropbox, …) rather than to plain local storage.
    ///
    /// Separate from `is_placeholder` because the app distinguishes
    /// `.remote(downloaded: true)` from `.local` — "downloaded from the cloud"
    /// is what the Settings download counters and `clearAllDownloads` operate
    /// on. Collapsing the two would make every materialised cloud photo look
    /// like a local one and quietly empty those screens.
    pub is_file_provider: bool,
    /// Whether the bytes are absent — a provider placeholder that appears in
    /// the listing but has not been materialised.
    ///
    /// Coarser than `FileProviderDetector.DownloadStatus`, which also has
    /// `downloading` and `stale`. Nothing in the app reads those two today
    /// (`SidecarCandidate.downloadStatus` is written and never inspected), so
    /// they collapse into "not local" here rather than adding a state the core
    /// cannot act on.
    pub is_placeholder: bool,
    /// An opaque token that changes when the file's *content* changes.
    ///
    /// Mirrors `NSURLFileContentIdentifierKey`, which APFS populates and most
    /// providers do not. `None` means "no identifier available" — callers fall
    /// back to comparing `(modified, size)`, exactly like
    /// `FileProviderDetector.ContentVersion.sameContent`.
    pub content_version: Option<String>,
    /// The size the file will have **once its bytes are here**
    /// (`totalFileSizeKey`), where a `stat` reports how much of it is here now.
    ///
    /// The two differ for exactly one kind of file and it is the kind that
    /// matters: a provider placeholder, whose `st_size` is a few hundred bytes
    /// of stub and whose intended size is the real one. The sidecar manifest's
    /// `ContentVersion.size` is compared against the sidecar cache to decide
    /// whether an `.xmp` needs re-fetching, and the Swift baseline wrote
    /// `totalFileSize ?? fileSize` there — so recording the stub size instead
    /// makes every placeholder sidecar in the library look changed on the first
    /// scan after an upgrade, and re-fetch.
    ///
    /// `None` when the platform does not vend one; callers fall back to the
    /// listing's size, which is what the two agree on for a local file.
    pub intended_size: Option<i64>,
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

    /// Everything directly inside `dir`, one round trip.
    ///
    /// # Ordering
    ///
    /// **Unspecified**, and deliberately so. `FolderScanner` consumes
    /// `contentsOfDirectory` in whatever order the filesystem hands it back
    /// and sorts only the *subdirectories* (ascending
    /// `localizedStandardCompare`, applied by the caller, not here). The
    /// conformance fixtures pin folder order and explicitly leave
    /// within-folder photo order free; an implementation that sorts is legal
    /// but buys nothing.
    ///
    /// # Errors
    ///
    /// A directory that cannot be listed must fail rather than return an
    /// empty listing. The scanner's carry-forward depends on telling the two
    /// apart: an empty directory means "these photos are gone", a failed
    /// listing means "ask again later" (fixture landmine 20 — a transient I/O
    /// error must not look like a deletion).
    ///
    /// A single *entry* that cannot be read is the opposite case and must be
    /// **skipped**, not propagated: a file unlinked between the `readdir` and
    /// its `stat` is one row missing, and failing the directory over it would
    /// report every photo beside it as removed. `contentsOfDirectory` had no
    /// per-entry failure mode at all, and the baseline's per-file
    /// `resourceValues` was wrapped in `try?`.
    fn list(&self, dir: &str) -> VfsResult<Vec<Entry>>;

    /// The same record [`Vfs::list`] returns, for a single path.
    ///
    /// Deliberately *not* the bulk read path — calling it per file is the
    /// mistake `_plans/06` Finding 1 is about. The scanner calls it once per
    /// **directory**, to pick up the folder node's own timestamps, exactly
    /// where the Swift baseline calls `dirURL.resourceValues(forKeys:)`.
    /// [`Stat`] cannot serve: it has no creation time and no sub-seconds.
    fn stat_entry(&self, path: &str) -> VfsResult<Entry>;

    /// Provider attributes for a *batch* of paths, in one round trip.
    ///
    /// The batch is the whole point. On iOS each of these is a blocking XPC
    /// call to `fileproviderd` that takes ~20 ms; run serially over a 20k
    /// library that is 99.4% of a cold scan (`_plans/06` Finding 1). Given the
    /// batch, the platform implementation is free to fan the calls out and
    /// still emit the answers in order — which is what makes the scan both
    /// fast and deterministic.
    ///
    /// # Contract
    ///
    /// Returns **exactly** `paths.len()` values, positionally matched. A path
    /// that cannot be probed reports [`ProviderAttrs::default`] — "plain local
    /// file" — rather than failing the batch, because that is what the Swift
    /// baseline's `try?` did.
    ///
    /// The default implementation answers "everything is local, no content
    /// identifier", which is correct for [`StdVfs`] and [`MemVfs`]: knowing
    /// otherwise needs `URLResourceKey`s that only the platform layer has.
    fn probe_provider(&self, paths: &[String]) -> Vec<ProviderAttrs> {
        vec![ProviderAttrs::default(); paths.len()]
    }

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

        // `list` sees what was written, with the size the stat reports.
        let listing = vfs.list(dir).unwrap();
        let entry = listing
            .iter()
            .find(|e| e.name == "contract.txt")
            .expect("the file just written is missing from the listing");
        assert_eq!(entry.kind, EntryKind::File);
        assert_eq!(entry.size, 0);

        // …and the default provider probe answers "plain local file", one row
        // per path, whatever the paths are.
        let probed = vfs.probe_provider(&[file.clone(), dir.to_string()]);
        assert_eq!(probed.len(), 2);
        assert!(probed.iter().all(|a| *a == ProviderAttrs::default()));

        // Listing a file, or something absent, is an error — never an empty
        // listing. The scanner tells "gone" from "unreadable" by that.
        assert!(vfs.list(&file).is_err());
        assert!(vfs.list(&format!("{dir}/nope")).is_err());

        // `stat_entry` agrees with the listing, and knows about directories.
        let single = vfs.stat_entry(&file).unwrap();
        assert_eq!(single.name, "contract.txt");
        assert_eq!(single.kind, EntryKind::File);
        assert_eq!(single.size, 0);
        assert_eq!(vfs.stat_entry(dir).unwrap().kind, EntryKind::Dir);
        assert!(vfs.stat_entry(&format!("{dir}/nope")).is_err());
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
