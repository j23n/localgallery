//! Library session: walk, enrich, index. No GTK.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use gallery_index::{LibraryIndex, TagSuggestion};
use gallery_meta::media::{read_image_metadata, read_video_date_at};
use gallery_model::date::AppleDate;
use gallery_model::photo::{PhotoFile, PhotoFolder, StableId};
use gallery_model::snapshot::{self, LibrarySnapshot, SidecarCandidate};
use gallery_scan::{scan_with_progress, ScanInput, ScanOutcome};
use gallery_vfs::{take_unsupported_names, StdVfs, Vfs};

use crate::config::{self, Config};
use crate::persist;
use crate::row;
use crate::time;

/// Why a library is not showing photos.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryAvailability {
    /// No folder has been chosen.
    NoneSelected,
    /// The saved folder is gone.
    Unavailable,
    /// The folder exists but the walk found no photos.
    Empty,
    /// Photos are ready to show.
    Ready,
}

/// In-memory library after a scan (or a snapshot load).
#[derive(Debug, Clone)]
pub struct LibraryState {
    /// Folder the user picked.
    pub root: PathBuf,
    /// Walked tree, if the root existed.
    pub root_folder: Option<PhotoFolder>,
    /// Search / tag / date indexes over every photo.
    pub index: LibraryIndex,
    /// Sidecar rows from the last walk.
    pub sidecar_manifest: Vec<SidecarCandidate>,
    /// How the on-disk snapshot was treated for this open.
    pub snapshot_reuse: SnapshotReuse,
    /// Directory entries `StdVfs` could not represent as UTF-8.
    pub unsupported_names: Vec<OsString>,
}

/// How [`open_library`] treated the derived snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnapshotReuse {
    /// Snapshot matched this root and was reused.
    Hit,
    /// No snapshot file.
    Missing,
    /// Snapshot belongs to a different library folder.
    RootMismatch,
    /// Version is not this build's. Safe to ignore and rescan.
    VersionMismatch {
        /// Version the file claimed.
        found: i64,
        /// Version this build writes.
        expected: i64,
    },
    /// File is not JSON / has no version.
    Corrupt {
        /// Parser detail.
        detail: String,
    },
    /// Version matched but the payload did not decode.
    Payload {
        /// Parser detail.
        detail: String,
    },
    /// File existed but could not be read.
    Unreadable {
        /// IO detail.
        detail: String,
    },
}

impl SnapshotReuse {
    /// User-facing line when a snapshot was discarded and the tree was rebuilt.
    pub fn recovery_message(&self) -> Option<String> {
        match self {
            SnapshotReuse::Corrupt { detail } => {
                Some(format!("Library snapshot is corrupt; rescanned ({detail})"))
            }
            SnapshotReuse::Payload { detail } => Some(format!(
                "Library snapshot payload is unreadable; rescanned ({detail})"
            )),
            SnapshotReuse::Unreadable { detail } => Some(format!(
                "Library snapshot could not be read; rescanned ({detail})"
            )),
            SnapshotReuse::VersionMismatch { found, expected } => Some(format!(
                "Library snapshot version {found} (expected {expected}); rescanned"
            )),
            SnapshotReuse::Hit | SnapshotReuse::Missing | SnapshotReuse::RootMismatch => None,
        }
    }
}

impl LibraryState {
    /// Date-sorted photos (the All Photos grid).
    pub fn sorted_photos(&self) -> Vec<&PhotoFile> {
        self.index.sorted_photos().collect()
    }

    /// Tag buckets plus the People subset.
    pub fn suggestions(&self) -> (Vec<TagSuggestion>, Vec<TagSuggestion>) {
        self.index.tag_suggestions()
    }
}

/// Something the host could not complete.
#[derive(Debug)]
pub enum HostError {
    /// Root path is not valid Unicode (the VFS is path-string based).
    InvalidPath {
        /// Lossy path plus the reason.
        detail: String,
    },
    /// The walk was cancelled.
    Cancelled,
    /// Snapshot encode failed (load failures recover via a rescan).
    Snapshot(snapshot::SnapshotError),
    /// Config or cache write failed.
    Io(std::io::Error),
}

impl std::fmt::Display for HostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HostError::InvalidPath { detail } => write!(f, "{detail}"),
            HostError::Cancelled => write!(f, "scan cancelled"),
            HostError::Snapshot(e) => write!(f, "{e}"),
            HostError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for HostError {}

impl From<std::io::Error> for HostError {
    fn from(e: std::io::Error) -> Self {
        HostError::Io(e)
    }
}

/// What the empty states should show for this root.
pub fn library_availability(
    root: Option<&Path>,
    state: Option<&LibraryState>,
) -> LibraryAvailability {
    match root {
        None => LibraryAvailability::NoneSelected,
        Some(path) if !config::root_is_available(path) => LibraryAvailability::Unavailable,
        Some(_) => match state {
            Some(s) if s.index.photos().is_empty() => LibraryAvailability::Empty,
            Some(_) => LibraryAvailability::Ready,
            None => LibraryAvailability::Empty,
        },
    }
}

/// Walk `root`, enrich stale photos, rebuild the index, persist the snapshot.
pub fn open_library(
    root: &Path,
    cancel: &AtomicBool,
    on_progress: Option<&dyn Fn(&str, usize, usize)>,
) -> Result<LibraryState, HostError> {
    let root_str = row::utf8_path(root).map_err(|e| HostError::InvalidPath {
        detail: e.to_string(),
    })?;
    if cancel.load(Ordering::Relaxed) {
        return Err(HostError::Cancelled);
    }

    let _ = take_unsupported_names();
    let vfs = StdVfs;
    let (cached, snapshot_reuse) = load_snapshot_for(root);
    let cached_photos = cached
        .as_ref()
        .map(|s| {
            s.all_photos
                .iter()
                .map(|p| (p.path().to_string(), p.clone()))
                .collect()
        })
        .unwrap_or_default();
    let cached_sidecar_manifest = cached
        .as_ref()
        .and_then(|s| s.sidecar_manifest.clone())
        .unwrap_or_default()
        .into_iter()
        .map(|row| (row.photo_id, row))
        .collect();

    let input = scan_input_for_open(cached_photos, cached_sidecar_manifest);

    if let Some(cb) = on_progress {
        cb("Scanning…", 0, 0);
    }
    let outcome: ScanOutcome = match on_progress {
        Some(cb) => scan_with_progress(&vfs, root_str, &input, Some(&|n| cb("Scanning…", n, 0))),
        None => scan_with_progress(&vfs, root_str, &input, None),
    };

    if cancel.load(Ordering::Relaxed) {
        return Err(HostError::Cancelled);
    }

    let stale: Vec<usize> = outcome
        .flat_photos
        .iter()
        .enumerate()
        .filter(|(_, p)| p.enriched_file_date.is_none())
        .map(|(i, _)| i)
        .collect();
    let stale_total = stale.len();
    if let Some(cb) = on_progress {
        cb("Reading metadata…", 0, stale_total);
    }

    let mut photos = outcome.flat_photos;
    for (done, idx) in stale.into_iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            return Err(HostError::Cancelled);
        }
        photos[idx] = enrich_photo(&vfs, photos[idx].clone());
        if let Some(cb) = on_progress {
            cb("Reading metadata…", done + 1, stale_total);
        }
    }

    let root_folder = outcome.root_folder.map(|f| patch_tree(f, &photos));
    let sidecar_manifest = outcome.sidecar_manifest;
    persist_snapshot(root, root_folder.as_ref(), &photos, &sidecar_manifest)?;

    let mut cfg = Config::load();
    cfg.library_root = Some(root.to_path_buf());
    cfg.save()?;

    Ok(LibraryState {
        root: root.to_path_buf(),
        root_folder,
        index: LibraryIndex::build(photos),
        sidecar_manifest,
        snapshot_reuse,
        unsupported_names: take_unsupported_names(),
    })
}

/// Scanner input for an open / reload.
///
/// Always a **full** pass (`reuse_cached: false`) so every `PhotoFile` is
/// rebuilt from the listing (cached tags and dates still carry forward).
/// Light scans now see size/mtime changes too; open stays on the full path
/// so a listing match cannot reuse a stale row verbatim.
pub fn scan_input_for_open(
    cached_photos: HashMap<String, PhotoFile>,
    cached_sidecar_manifest: HashMap<StableId, SidecarCandidate>,
) -> ScanInput {
    ScanInput {
        reuse_cached: false,
        cached_photos,
        cached_sidecar_manifest,
    }
}

/// Re-read sidecar fields for photos whose `.xmp` changed. The image file
/// itself did not, so [`open_library`] would skip them as already enriched.
pub fn reapply_sidecars(
    state: LibraryState,
    only_paths: Option<&[String]>,
) -> Result<LibraryState, HostError> {
    let vfs = StdVfs;
    let filter: Option<HashMap<&str, ()>> =
        only_paths.map(|paths| paths.iter().map(|p| (p.as_str(), ())).collect());
    let mut photos = state.index.photos().to_vec();
    for photo in &mut photos {
        if let Some(filter) = &filter {
            if !filter.contains_key(photo.path()) {
                continue;
            }
        }
        if photo.is_video {
            continue;
        }
        *photo = refresh_sidecar_fields(&vfs, photo.clone());
    }
    let root_folder = state.root_folder.map(|f| patch_tree(f, &photos));
    persist_snapshot(
        &state.root,
        root_folder.as_ref(),
        &photos,
        &state.sidecar_manifest,
    )?;
    Ok(LibraryState {
        root: state.root,
        root_folder,
        index: LibraryIndex::build(photos),
        sidecar_manifest: state.sidecar_manifest,
        snapshot_reuse: state.snapshot_reuse,
        unsupported_names: state.unsupported_names,
    })
}

/// Overlay the current sidecar onto an already-enriched row.
fn refresh_sidecar_fields(vfs: &dyn Vfs, mut photo: PhotoFile) -> PhotoFile {
    let path = photo.path().to_string();
    let meta = read_image_metadata(vfs, &path);
    photo.hierarchical_tags = meta.hierarchical_tags;
    photo.country_code = meta.country_code;
    if meta.gps_latitude.is_some() {
        photo.gps_latitude = meta.gps_latitude;
    }
    if meta.gps_longitude.is_some() {
        photo.gps_longitude = meta.gps_longitude;
    }
    photo.face_regions = meta.face_regions;
    photo
}

/// Apply enrichment fields the scanner leaves empty (sidecar tags, EXIF date).
pub fn enrich_photo(vfs: &dyn Vfs, mut photo: PhotoFile) -> PhotoFile {
    if photo.enriched_file_date.is_some() {
        return photo;
    }

    let path = photo.path().to_string();
    if photo.is_video {
        if let Some(unix) = read_video_date_at(vfs, &path) {
            photo.date_taken = Some(AppleDate::from_unix_secs_f64(unix as f64));
            photo.date_from_metadata = true;
        }
        photo.enriched_file_date = photo.file_modification_date.or_else(|| {
            Some(AppleDate::from_unix_secs_f64(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs_f64())
                    .unwrap_or(0.0),
            ))
        });
        return photo;
    }

    let meta = read_image_metadata(vfs, &path);
    if !meta.hierarchical_tags.is_empty() {
        photo.hierarchical_tags = meta.hierarchical_tags;
    }
    if meta.country_code.is_some() {
        photo.country_code = meta.country_code;
    }
    if meta.gps_latitude.is_some() {
        photo.gps_latitude = meta.gps_latitude;
    }
    if meta.gps_longitude.is_some() {
        photo.gps_longitude = meta.gps_longitude;
    }
    if !meta.face_regions.is_empty() {
        photo.face_regions = meta.face_regions;
    }
    if let Some(wall) = meta.capture_wall_clock {
        photo.date_taken = Some(time::instant_from_local_wall(wall));
        photo.date_from_metadata = true;
    }
    photo.enriched_file_date = photo.file_modification_date.or_else(|| {
        Some(AppleDate::from_unix_secs_f64(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0),
        ))
    });
    photo
}

/// Replace each tree photo with the enriched copy of the same path.
pub fn patch_tree(folder: PhotoFolder, photos: &[PhotoFile]) -> PhotoFolder {
    let by_path: HashMap<&str, &PhotoFile> = photos.iter().map(|p| (p.path(), p)).collect();
    patch_folder(folder, &by_path)
}

fn patch_folder(mut folder: PhotoFolder, by_path: &HashMap<&str, &PhotoFile>) -> PhotoFolder {
    folder.photos = folder
        .photos
        .into_iter()
        .map(|p| by_path.get(p.path()).copied().cloned().unwrap_or(p))
        .collect();
    folder.subfolders = folder
        .subfolders
        .into_iter()
        .map(|s| patch_folder(s, by_path))
        .collect();
    folder
}

/// Depth-first lookup by folder id.
pub fn find_folder<'a>(folder: &'a PhotoFolder, id: StableId) -> Option<&'a PhotoFolder> {
    if folder.id == id {
        return Some(folder);
    }
    folder.subfolders.iter().find_map(|c| find_folder(c, id))
}

/// A Collections hub section (Objects, Scenes, Places, …).
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionGroup {
    /// First path segment, or `"Other"` for flat tags.
    pub name: String,
    /// Photo count credited to the group (max of its buckets, not a unique union).
    pub count: usize,
    /// Buckets in this namespace, already sorted by the index.
    pub tags: Vec<TagSuggestion>,
}

/// Group aggregated tags for the Collections hub. People are excluded — they
/// have their own row.
pub fn collection_groups(tags: &[TagSuggestion]) -> Vec<CollectionGroup> {
    let mut order: Vec<String> = Vec::new();
    let mut buckets: HashMap<String, Vec<TagSuggestion>> = HashMap::new();
    for tag in tags {
        let ns = tag
            .namespace
            .as_deref()
            .filter(|n| !n.is_empty())
            .unwrap_or("Other");
        if ns.eq_ignore_ascii_case("people") {
            continue;
        }
        if !buckets.contains_key(ns) {
            order.push(ns.to_string());
        }
        buckets.entry(ns.to_string()).or_default().push(tag.clone());
    }
    order
        .into_iter()
        .filter_map(|name| {
            let tags = buckets.remove(&name)?;
            let count = tags.iter().map(|t| t.count).max().unwrap_or(0);
            Some(CollectionGroup { name, count, tags })
        })
        .collect()
}

/// Tags that are not a prefix of another tag in `tags`.
///
/// `Places/Italy` drops out when `Places/Italy/Lazio/Rome` exists, so a rail
/// shows cities rather than every ancestor.
pub fn leaf_tags(tags: &[TagSuggestion]) -> Vec<TagSuggestion> {
    tags.iter()
        .filter(|tag| {
            let prefix = format!("{}/", tag.full_path);
            !tags
                .iter()
                .any(|other| other.full_path.starts_with(&prefix))
        })
        .cloned()
        .collect()
}

/// Leaf folders that contain photos, newest capture first — iOS `eventFolders`.
pub fn event_folders(root: &PhotoFolder) -> Vec<PhotoFolder> {
    let mut leaves = Vec::new();
    collect_leaf_folders(root, &mut leaves);
    leaves.sort_by(|a, b| {
        let da = latest_taken(a);
        let db = latest_taken(b);
        db.partial_cmp(&da).unwrap_or(std::cmp::Ordering::Equal)
    });
    leaves
}

fn collect_leaf_folders(folder: &PhotoFolder, out: &mut Vec<PhotoFolder>) {
    if folder.subfolders.is_empty() {
        if !folder.photos.is_empty() {
            out.push(folder.clone());
        }
        return;
    }
    for child in &folder.subfolders {
        collect_leaf_folders(child, out);
    }
}

fn latest_taken(folder: &PhotoFolder) -> f64 {
    folder
        .photos
        .iter()
        .filter_map(|p| p.date_taken)
        .map(|d| d.0)
        .fold(f64::NEG_INFINITY, f64::max)
}

fn load_snapshot_for(root: &Path) -> (Option<LibrarySnapshot>, SnapshotReuse) {
    let path = config::snapshot_path();
    let bytes = match persist::read_private(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return (None, SnapshotReuse::Missing);
        }
        Err(e) => {
            return (
                None,
                SnapshotReuse::Unreadable {
                    detail: e.to_string(),
                },
            );
        }
    };
    match snapshot::load(&bytes) {
        Ok(snap) => {
            if Path::new(snap.root_folder.url.path()) == root {
                (Some(snap), SnapshotReuse::Hit)
            } else {
                (None, SnapshotReuse::RootMismatch)
            }
        }
        Err(snapshot::SnapshotError::VersionMismatch { found, expected }) => {
            (None, SnapshotReuse::VersionMismatch { found, expected })
        }
        Err(snapshot::SnapshotError::Corrupt(detail)) => (None, SnapshotReuse::Corrupt { detail }),
        Err(snapshot::SnapshotError::Payload(detail)) => (None, SnapshotReuse::Payload { detail }),
    }
}

fn persist_snapshot(
    root: &Path,
    tree: Option<&PhotoFolder>,
    photos: &[PhotoFile],
    manifest: &[SidecarCandidate],
) -> Result<(), HostError> {
    let Some(root_folder) = tree.cloned() else {
        return Ok(());
    };
    let _ = root;
    let bytes = snapshot::save(&LibrarySnapshot {
        root_folder,
        all_photos: photos.to_vec(),
        sidecar_manifest: Some(manifest.to_vec()),
    })
    .map_err(HostError::Snapshot)?;
    persist::write_atomic(&config::snapshot_path(), &bytes)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::persist;
    use gallery_model::photo::{FileUrl, HierarchicalTag, PhotoFile, PhotoFolder, StableId};
    use gallery_vfs::MemVfs;

    fn folder(
        path: &str,
        name: &str,
        subs: Vec<PhotoFolder>,
        photos: Vec<PhotoFile>,
    ) -> PhotoFolder {
        PhotoFolder {
            id: StableId::for_folder(path),
            url: FileUrl::new(path),
            name: name.into(),
            subfolders: subs,
            photos,
            cover_photo_url: None,
            total_photo_count: 0,
            date_modified: None,
            date_created: None,
        }
    }

    #[test]
    fn find_folder_walks_children() {
        let leaf = folder("/lib/a/b", "b", vec![], vec![]);
        let mid = folder("/lib/a", "a", vec![leaf.clone()], vec![]);
        let root = folder("/lib", "lib", vec![mid], vec![]);
        assert_eq!(
            find_folder(&root, leaf.id).map(|f| f.name.as_str()),
            Some("b")
        );
        assert!(find_folder(&root, StableId::for_folder("/nope")).is_none());
    }

    #[test]
    fn patch_tree_replaces_matching_photos() {
        let old = PhotoFile::new("/lib/a.jpg", "a", 1);
        let mut new = old.clone();
        new.hierarchical_tags = vec![HierarchicalTag::new("Places/Paris")];
        let tree = folder("/lib", "lib", vec![], vec![old]);
        let patched = patch_tree(tree, std::slice::from_ref(&new));
        assert_eq!(
            patched.photos[0].hierarchical_tags[0].full_path,
            "Places/Paris"
        );
    }

    #[test]
    fn collection_groups_skip_people_and_keep_namespace_order() {
        let tags = vec![
            TagSuggestion {
                id: "objects/cat".into(),
                display_name: "Cat".into(),
                full_path: "Objects/Cat".into(),
                namespace: Some("Objects".into()),
                count: 4,
                latest_photo_date: None,
            },
            TagSuggestion {
                id: "people/ada".into(),
                display_name: "Ada".into(),
                full_path: "People/Ada".into(),
                namespace: Some("People".into()),
                count: 2,
                latest_photo_date: None,
            },
            TagSuggestion {
                id: "scenes/beach".into(),
                display_name: "Beach".into(),
                full_path: "Scenes/Beach".into(),
                namespace: Some("Scenes".into()),
                count: 9,
                latest_photo_date: None,
            },
        ];
        let groups = collection_groups(&tags);
        assert_eq!(
            groups
                .iter()
                .map(|g| (g.name.as_str(), g.count))
                .collect::<Vec<_>>(),
            vec![("Objects", 4), ("Scenes", 9)]
        );
    }

    fn tag(path: &str, count: usize) -> TagSuggestion {
        let tag = gallery_model::photo::HierarchicalTag::new(path);
        TagSuggestion {
            id: path.to_ascii_lowercase(),
            display_name: tag.display_name,
            full_path: tag.full_path,
            namespace: tag.namespace,
            count,
            latest_photo_date: None,
        }
    }

    #[test]
    fn leaf_tags_drop_prefix_ancestors() {
        let tags = vec![
            tag("Places/Italy", 10),
            tag("Places/Italy/Lazio", 8),
            tag("Places/Italy/Lazio/Rome", 5),
            tag("Places/France/Paris", 3),
        ];
        let leaves = leaf_tags(&tags);
        assert_eq!(
            leaves
                .iter()
                .map(|t| t.full_path.as_str())
                .collect::<Vec<_>>(),
            vec!["Places/Italy/Lazio/Rome", "Places/France/Paris"]
        );
    }

    #[test]
    fn event_folders_are_photo_leaves_newest_first() {
        let mut old = PhotoFile::new("/lib/2018/rome/a.jpg", "a", 1);
        old.date_taken = Some(AppleDate(1.0));
        let mut new = PhotoFile::new("/lib/2024/paris/b.jpg", "b", 2);
        new.date_taken = Some(AppleDate(99.0));
        let rome = folder("/lib/2018/rome", "Rome", vec![], vec![old]);
        let paris = folder("/lib/2024/paris", "Paris", vec![], vec![new]);
        let y2018 = folder("/lib/2018", "2018", vec![rome.clone()], vec![]);
        let y2024 = folder("/lib/2024", "2024", vec![paris.clone()], vec![]);
        let root = folder("/lib", "lib", vec![y2018, y2024], vec![]);
        let events = event_folders(&root);
        assert_eq!(
            events.iter().map(|f| f.name.as_str()).collect::<Vec<_>>(),
            vec!["Paris", "Rome"]
        );
    }

    #[test]
    fn enrich_reads_sidecar_tags_through_memvfs() {
        let vfs = MemVfs::new();
        vfs.write_atomic("/p.jpg", b"not-a-real-jpeg").unwrap();
        vfs.write_atomic(
            "/p.jpg.xmp",
            br#"<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description xmlns:digiKam="http://www.digikam.org/ns/1.0/">
      <digiKam:TagsList>
        <rdf:Seq><rdf:li>Objects/Cat</rdf:li></rdf:Seq>
      </digiKam:TagsList>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>"#,
        )
        .unwrap();
        let photo = PhotoFile::new("/p.jpg", "p", 12);
        let enriched = enrich_photo(&vfs, photo);
        assert_eq!(enriched.hierarchical_tags[0].full_path, "Objects/Cat");
        assert!(enriched.enriched_file_date.is_some());
    }

    #[test]
    fn availability_covers_the_three_empty_states() {
        assert_eq!(
            library_availability(None, None),
            LibraryAvailability::NoneSelected
        );
        assert_eq!(
            library_availability(Some(Path::new("/definitely-not-a-gallery-root")), None),
            LibraryAvailability::Unavailable
        );
    }

    #[test]
    fn reapply_sidecars_rereads_a_written_xmp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("p.jpg");
        std::fs::write(&path, b"not-a-jpeg").unwrap();
        let path_str = path.to_str().unwrap();
        let photo = PhotoFile::new(path_str, "p", 12);
        let state = LibraryState {
            root: dir.path().to_path_buf(),
            root_folder: None,
            index: LibraryIndex::build(vec![photo]),
            sidecar_manifest: vec![],
            snapshot_reuse: SnapshotReuse::Missing,
            unsupported_names: vec![],
        };
        std::fs::write(
            path.with_extension("jpg.xmp"),
            br#"<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description xmlns:digiKam="http://www.digikam.org/ns/1.0/">
      <digiKam:TagsList>
        <rdf:Seq><rdf:li>Places/France/Paris</rdf:li></rdf:Seq>
      </digiKam:TagsList>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>"#,
        )
        .unwrap();
        let next = reapply_sidecars(state, Some(&[path_str.to_string()])).unwrap();
        assert_eq!(
            next.index.photos()[0].hierarchical_tags[0].full_path,
            "Places/France/Paris"
        );
    }

    #[test]
    fn scan_input_for_open_never_enables_light_reuse() {
        let mut photos = HashMap::new();
        photos.insert("/a.jpg".into(), PhotoFile::new("/a.jpg", "a", 1));
        let input = scan_input_for_open(photos, HashMap::new());
        assert!(!input.reuse_cached);
        assert!(input.cached_photos.contains_key("/a.jpg"));
    }

    #[test]
    fn full_pass_with_cache_sees_an_in_place_edit() {
        use gallery_scan::scan;
        use gallery_vfs::StdVfs;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.jpg");
        std::fs::write(&path, crate::decode::tests_jpeg()).unwrap();
        let root = dir.path().to_str().unwrap();
        let vfs = StdVfs;
        let cold = scan(&vfs, root, &ScanInput::default());
        assert_eq!(cold.flat_photos.len(), 1);
        let mut cached = HashMap::new();
        cached.insert(
            cold.flat_photos[0].path().to_string(),
            cold.flat_photos[0].clone(),
        );

        let mut bigger = crate::decode::tests_jpeg().to_vec();
        bigger.extend_from_slice(&[0xFFu8; 128]);
        std::fs::write(&path, bigger).unwrap();

        let light = scan(
            &vfs,
            root,
            &ScanInput {
                reuse_cached: true,
                cached_photos: cached.clone(),
                cached_sidecar_manifest: HashMap::new(),
            },
        );
        let full = scan(&vfs, root, &scan_input_for_open(cached, HashMap::new()));
        assert!(
            !light.modified_paths.is_empty(),
            "light compares listing size/mtime, so a rewrite is visible"
        );
        assert!(
            !full.modified_paths.is_empty(),
            "full pass must observe the rewrite"
        );
    }

    struct PathGuard;
    impl Drop for PathGuard {
        fn drop(&mut self) {
            crate::config::override_paths(None, None);
        }
    }

    fn isolate_xdg() -> (tempfile::TempDir, PathGuard) {
        let dir = tempfile::tempdir().unwrap();
        crate::config::override_paths(
            Some(dir.path().join("config.json")),
            Some(dir.path().join("cache")),
        );
        (dir, PathGuard)
    }

    #[test]
    fn corrupt_snapshot_is_reported_and_the_scan_recovers() {
        let (_xdg, _guard) = isolate_xdg();
        let lib = tempfile::tempdir().unwrap();
        std::fs::write(lib.path().join("a.jpg"), b"not-a-jpeg").unwrap();
        let snap = config::snapshot_path();
        std::fs::create_dir_all(snap.parent().unwrap()).unwrap();
        std::fs::write(&snap, b"not-json").unwrap();

        let cancel = AtomicBool::new(false);
        let state = open_library(lib.path(), &cancel, None).unwrap();
        assert!(
            matches!(state.snapshot_reuse, SnapshotReuse::Corrupt { .. }),
            "{:?}",
            state.snapshot_reuse
        );
        assert!(state
            .snapshot_reuse
            .recovery_message()
            .unwrap()
            .contains("corrupt"));
        assert_eq!(state.index.photos().len(), 1);
        assert_eq!(Config::load().library_root.as_deref(), Some(lib.path()));
    }

    #[test]
    fn version_mismatch_is_not_reported_as_corruption() {
        let (_xdg, _guard) = isolate_xdg();
        let lib = tempfile::tempdir().unwrap();
        std::fs::write(lib.path().join("a.jpg"), b"not-a-jpeg").unwrap();
        let snap = config::snapshot_path();
        std::fs::create_dir_all(snap.parent().unwrap()).unwrap();
        std::fs::write(&snap, r#"{"version":19,"value":{}}"#).unwrap();

        let cancel = AtomicBool::new(false);
        let state = open_library(lib.path(), &cancel, None).unwrap();
        assert!(
            matches!(
                state.snapshot_reuse,
                SnapshotReuse::VersionMismatch { found: 19, .. }
            ),
            "{:?}",
            state.snapshot_reuse
        );
        assert_eq!(state.index.photos().len(), 1);
    }

    #[test]
    fn matching_snapshot_is_reused_and_written_privately() {
        let (_xdg, _guard) = isolate_xdg();
        let lib = tempfile::tempdir().unwrap();
        std::fs::write(lib.path().join("a.jpg"), b"not-a-jpeg").unwrap();
        let cancel = AtomicBool::new(false);
        let first = open_library(lib.path(), &cancel, None).unwrap();
        assert_eq!(first.snapshot_reuse, SnapshotReuse::Missing);
        let second = open_library(lib.path(), &cancel, None).unwrap();
        assert_eq!(second.snapshot_reuse, SnapshotReuse::Hit);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(config::snapshot_path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, persist::FILE_MODE);
            let dir_mode = std::fs::metadata(config::cache_dir())
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(dir_mode, persist::DIR_MODE);
        }
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_root_is_a_diagnostic() {
        use std::os::unix::ffi::OsStringExt;
        let root = PathBuf::from(std::ffi::OsString::from_vec(vec![0xff, 0xfe]));
        let err = open_library(&root, &AtomicBool::new(false), None).unwrap_err();
        assert!(matches!(err, HostError::InvalidPath { .. }), "{err}");
        assert!(err.to_string().contains("not valid UTF-8"));
    }
}
