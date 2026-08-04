//! The traversal. A port of `FolderScanner.scan`, behaviour for behaviour.
//!
//! # The two modes
//!
//! **Full** (`reuse_cached: false`) stats every file and rebuilds every
//! `PhotoFile`; cached metadata is still carried forward for unchanged files
//! so enrichment does not re-run.
//!
//! **Light** (`reuse_cached: true`) reuses the cached `PhotoFile` verbatim for
//! any path already in the cache, refreshing only `filename` and the
//! live-photo pairing.
//!
//! # The blind spot, which is the point of the light mode and its whole cost
//!
//! For a path already in the cache the light pass takes the **cached** size
//! and mtime and never looks at the listing's. So a light scan can never
//! notice a change to a file it already knows — not a new mtime, not even a
//! new size. Only a full scan stats. Passes 2 and 3 of the scanner fixture
//! differ in exactly this and nothing else: `a.jpg` is rewritten bigger and
//! newer, and only the full pass reports it modified.
//!
//! Neither mode hashes content, so a rewrite that preserves size *and* mtime
//! is invisible to both (`Unicode/emoji 🌵 cactus.jpg` in the fixture).
//!
//! # The carry-forward
//!
//! A directory whose listing throws is recorded in `failed_directory_paths`,
//! its photos are absent from `flat_photos`, and — critically — they are
//! **excluded from `removed_paths`**. The Store keeps its cached copies, so a
//! transient provider error cannot wipe a subtree's tags and enrichment. The
//! directory still becomes a photo-less node: it is stat-able even when it is
//! not listable.

use std::collections::{HashMap, HashSet};

use gallery_model::date::AppleDate;
use gallery_model::file_url::{join, stem};
use gallery_model::photo::{PhotoFile, PhotoFolder, PhotoLocality, StableId};
use gallery_model::snapshot::{ContentVersion, DownloadStatus, SidecarCandidate};
use gallery_vfs::{Entry, EntryKind, FileTime, Vfs};

use crate::classify::{
    classify, image_stem_key, is_hidden, sidecar_key, sidecar_owner_key, video_stem, MediaKind,
};
use crate::order::localized_standard_compare;
use crate::path_form::decomposed;

/// How many photos are discovered between progress callbacks.
///
/// The callback hops to the main actor and invalidates `@Observable` state;
/// firing per file made the hops dominate the walk on a 20k library.
const PROGRESS_BATCH: usize = 500;

/// What the caller knows before the scan starts.
#[derive(Default)]
pub struct ScanInput {
    /// Reuse cached `PhotoFile`s for unchanged paths — the light scan.
    pub reuse_cached: bool,
    /// Previous scan's photos, keyed by path.
    pub cached_photos: HashMap<String, PhotoFile>,
    /// Previous scan's sidecar rows, keyed by photo id. A hit here is what
    /// lets a light scan skip re-probing a `.xmp` — the single most expensive
    /// thing a scan does on a provider-backed library.
    pub cached_sidecar_manifest: HashMap<StableId, SidecarCandidate>,
}

/// Everything one pass produces.
#[derive(Debug, Clone, PartialEq)]
pub struct ScanOutcome {
    /// The tree, or `None` when the root itself could not be visited.
    pub root_folder: Option<PhotoFolder>,
    /// Every photo, in traversal order.
    pub flat_photos: Vec<PhotoFile>,
    /// Whether anything needs an enrichment pass.
    pub needs_enrichment: bool,
    /// One row per image that has a `<basename>.xmp` beside it.
    pub sidecar_manifest: Vec<SidecarCandidate>,
    /// Paths seen now and absent from the cache.
    pub added_paths: Vec<String>,
    /// Paths in the cache and not seen now — **excluding** anything under a
    /// failed directory.
    pub removed_paths: Vec<String>,
    /// Paths whose size or mtime changed. Disjoint from `added_paths`.
    pub modified_paths: Vec<String>,
    /// **Decomposed** paths of directories whose listing failed. NFD because
    /// Swift emits them through `standardizedFileURL.path` and the Store's
    /// prefix check compares against that same form.
    pub failed_directory_paths: Vec<String>,
}

/// Walk `root` and produce the tree, the flat list, and the diff against the
/// cache.
pub fn scan(vfs: &dyn Vfs, root: &str, input: &ScanInput) -> ScanOutcome {
    scan_with_progress(vfs, root, input, None)
}

/// [`scan`], with a callback invoked every [`PROGRESS_BATCH`] photos and once
/// at the end with the true total.
///
/// The callback runs on the scanning thread and must not call back into the
/// core — the VFS is already re-entrant from the platform side, and a second
/// hop through it is how a synchronous callback bridge deadlocks.
pub fn scan_with_progress(
    vfs: &dyn Vfs,
    root: &str,
    input: &ScanInput,
    on_progress: Option<&dyn Fn(usize)>,
) -> ScanOutcome {
    let mut walk = Walk::new(input);
    let mut stack: Vec<(String, Option<usize>)> = vec![(root.to_string(), None)];

    while let Some((dir, parent)) = stack.pop() {
        let mut subdirs = walk.visit_directory(vfs, &dir, parent);
        if let Some(callback) = on_progress {
            walk.report(callback, false);
        }
        // Sorted ascending, pushed in reverse, so they pop ascending. Swift
        // sorts descending and pushes in order; same result, said once.
        subdirs.sort_by(|a, b| localized_standard_compare(&a.0, &b.0));
        let node_index = walk.nodes.len() - 1;
        for (_, path) in subdirs.into_iter().rev() {
            stack.push((path, Some(node_index)));
        }
    }

    if let Some(callback) = on_progress {
        walk.report(callback, true);
    }
    walk.finish()
}

/// One file the classify pass kept.
struct ScanFile {
    path: String,
    name: String,
    file_size: i64,
    mod_date: Option<AppleDate>,
    creation_date: Option<AppleDate>,
    is_image: bool,
    is_video: bool,
    is_file_provider: bool,
    is_placeholder: bool,
}

/// A folder node before the tree is assembled. Flat, indexed by
/// `parent_index`, so the recursive `PhotoFolder` is built in one second pass
/// with no intermediate copies.
struct ScanNode {
    path: String,
    name: String,
    photos: Vec<PhotoFile>,
    child_indices: Vec<usize>,
    date_modified: Option<AppleDate>,
    date_created: Option<AppleDate>,
}

struct Walk<'a> {
    input: &'a ScanInput,
    nodes: Vec<ScanNode>,
    flat_photos: Vec<PhotoFile>,
    needs_enrichment: bool,
    sidecar_manifest: Vec<SidecarCandidate>,
    added_paths: Vec<String>,
    modified_paths: Vec<String>,
    seen_paths: HashSet<String>,
    failed_directory_paths: Vec<String>,
    progress_tick: usize,
}

impl<'a> Walk<'a> {
    fn new(input: &'a ScanInput) -> Self {
        Walk {
            input,
            nodes: Vec::new(),
            flat_photos: Vec::new(),
            needs_enrichment: false,
            sidecar_manifest: Vec::new(),
            added_paths: Vec::new(),
            modified_paths: Vec::new(),
            seen_paths: HashSet::new(),
            failed_directory_paths: Vec::new(),
            progress_tick: 0,
        }
    }

    fn report(&mut self, callback: &dyn Fn(usize), force: bool) {
        if force || self.progress_tick >= PROGRESS_BATCH {
            callback(self.flat_photos.len());
            self.progress_tick = 0;
        }
    }

    /// Visit one directory, append its node, and return its subdirectories as
    /// `(name, path)` pairs for the caller to order and push.
    fn visit_directory(
        &mut self,
        vfs: &dyn Vfs,
        dir: &str,
        parent_index: Option<usize>,
    ) -> Vec<(String, String)> {
        let mut photos: Vec<PhotoFile> = Vec::new();
        let mut subdirs: Vec<(String, String)> = Vec::new();

        match vfs.list(dir) {
            Ok(entries) => {
                let (files, sidecars) = self.classify_pass(vfs, dir, entries, &mut subdirs);
                photos = self.build_photos(files, &sidecars);
            }
            Err(_) => {
                // No log surface here: the core does not own logging. The
                // Store learns about it through `failed_directory_paths`,
                // which is also what keeps the subtree's photos alive.
                self.failed_directory_paths.push(decomposed(dir));
            }
        }

        // The folder's own timestamps. One call per *directory* — where the
        // Swift baseline calls `dirURL.resourceValues(forKeys:)`, not the
        // per-file chatter `_plans/06` Finding 1 is about.
        let dir_entry = vfs.stat_entry(dir).ok();
        let node_index = self.nodes.len();
        self.nodes.push(ScanNode {
            path: dir.to_string(),
            name: gallery_model::file_url::last_component(dir).to_string(),
            photos: photos.clone(),
            child_indices: Vec::new(),
            date_modified: dir_entry.as_ref().and_then(|e| e.modified).map(apple_date),
            date_created: dir_entry.as_ref().and_then(|e| e.created).map(apple_date),
        });
        if let Some(parent) = parent_index {
            self.nodes[parent].child_indices.push(node_index);
        }
        self.progress_tick += photos.len();
        self.flat_photos.extend(photos);
        subdirs
    }

    /// First pass: sort the listing into media files, sidecars and
    /// subdirectories.
    fn classify_pass(
        &self,
        vfs: &dyn Vfs,
        dir: &str,
        entries: Vec<Entry>,
        subdirs: &mut Vec<(String, String)>,
    ) -> (Vec<ScanFile>, HashMap<String, Entry>) {
        let mut files = Vec::new();
        // Lowercased full basename → the `.xmp` entry beside it.
        let mut sidecars: HashMap<String, Entry> = HashMap::new();

        for entry in entries {
            if is_hidden(&entry.name) {
                continue;
            }
            let path = join(dir, &entry.name);

            if classify(&entry.name) == MediaKind::Sidecar {
                // Recorded without a stat; the manifest reads its size and
                // mtime straight off this listing row.
                sidecars.insert(sidecar_owner_key(&entry.name), entry);
                continue;
            }

            // The light-scan fast path, and the reason the blind spot exists:
            // a known path is classified from the **cache**, so its size and
            // mtime are last scan's. Placed before the directory check exactly
            // as in Swift — a directory can never be in `cached_photos`, so
            // the ordering is only a shortcut, not a hazard.
            if self.input.reuse_cached {
                if let Some(cached) = self.input.cached_photos.get(&path) {
                    files.push(ScanFile {
                        path,
                        name: entry.name,
                        file_size: cached.file_size,
                        mod_date: cached.file_modification_date,
                        creation_date: None,
                        is_image: !cached.is_video,
                        is_video: cached.is_video,
                        is_file_provider: entry.is_file_provider,
                        is_placeholder: entry.is_placeholder,
                    });
                    continue;
                }
            }

            // A symlink is resolved only far enough to decide whether it is a
            // directory, which is what `isDirectoryKey` reports. Its size and
            // times stay the link's.
            let is_dir = match entry.kind {
                EntryKind::Dir => true,
                EntryKind::Symlink => vfs.stat(&path).map(|s| s.is_dir).unwrap_or(false),
                EntryKind::File => false,
            };
            if is_dir {
                subdirs.push((entry.name, path));
                continue;
            }
            let (is_image, is_video) = match classify(&entry.name) {
                MediaKind::Image => (true, false),
                MediaKind::Video => (false, true),
                _ => continue,
            };
            files.push(ScanFile {
                path,
                file_size: entry.size as i64,
                mod_date: entry.modified.map(apple_date),
                creation_date: entry.created.map(apple_date),
                is_image,
                is_video,
                is_file_provider: entry.is_file_provider,
                is_placeholder: entry.is_placeholder,
                name: entry.name,
            });
        }
        (files, sidecars)
    }

    /// Second and third passes: pair live photos, then build one `PhotoFile`
    /// per image and per *standalone* video.
    fn build_photos(
        &mut self,
        files: Vec<ScanFile>,
        sidecars: &HashMap<String, Entry>,
    ) -> Vec<PhotoFile> {
        // First video wins a contested stem, matching `uniquingKeysWith`.
        let mut video_by_stem: HashMap<String, String> = HashMap::new();
        for file in files.iter().filter(|f| f.is_video) {
            video_by_stem
                .entry(video_stem(&file.name))
                .or_insert_with(|| file.path.clone());
        }
        let image_stems: HashSet<String> = files
            .iter()
            .filter(|f| f.is_image)
            .map(|f| image_stem_key(&f.name))
            .collect();

        let mut photos = Vec::new();

        for file in files.iter().filter(|f| f.is_image) {
            self.seen_paths.insert(file.path.clone());
            // The image branch keeps the stem's original case.
            let filename = stem(&file.name).to_string();
            let live = video_by_stem.get(&filename.to_lowercase()).cloned();
            let photo = self.photo_for(file, filename, live, false);

            // The sidecar manifest is emitted **only here**, inside the image
            // loop. That is why `Clip.MOV.xmp` never produces a row: a video
            // can never carry a sidecar through a scan (landmine 23).
            if let Some(sidecar) = sidecars.get(&sidecar_key(&file.name)) {
                self.push_sidecar_row(file, &photo, sidecar);
            }
            photos.push(photo);
        }

        for file in files.iter().filter(|f| f.is_video) {
            let key = video_stem(&file.name);
            if image_stems.contains(&key) {
                continue; // paired: it belongs to its image, not to itself
            }
            self.seen_paths.insert(file.path.clone());
            // …and the video branch reuses the pairing key, which is
            // lowercased. `Clip.MOV` becomes `clip` (landmine 22).
            let photo = self.photo_for(file, key, None, true);
            photos.push(photo);
        }

        photos
    }

    /// Build (or reuse) the `PhotoFile` for one file, and record it in the
    /// added/modified accounting.
    fn photo_for(
        &mut self,
        file: &ScanFile,
        filename: String,
        live: Option<String>,
        is_video: bool,
    ) -> PhotoFile {
        let cached = self.input.cached_photos.get(&file.path);
        let unchanged = cached.is_some_and(|c| {
            c.file_size == file.file_size && c.file_modification_date == file.mod_date
        });

        let photo = if self.input.reuse_cached && unchanged {
            // Verbatim, except for the two things that can change without the
            // photo's own bytes changing.
            let mut photo = cached.expect("unchanged implies cached").clone();
            photo.filename = filename;
            photo.live_photo_video_url = live.map(gallery_model::photo::FileUrl::new);
            photo
        } else {
            self.rebuild(file, filename, live, is_video, cached, unchanged)
        };

        if cached.is_none() {
            self.added_paths.push(file.path.clone());
            self.needs_enrichment = true;
        } else if !unchanged {
            self.modified_paths.push(file.path.clone());
            self.needs_enrichment = true;
        }
        photo
    }

    /// The slow path: a fresh `PhotoFile`, with whatever the cache can still
    /// contribute.
    fn rebuild(
        &mut self,
        file: &ScanFile,
        filename: String,
        live: Option<String>,
        is_video: bool,
        cached: Option<&PhotoFile>,
        unchanged: bool,
    ) -> PhotoFile {
        // The scanner never opens a file, so there is no EXIF here. An
        // unchanged file keeps its cached date; anything else falls back to
        // the earlier of the filesystem's two dates — creation is when the
        // file appeared on *this* volume (a download), modification is often
        // preserved from the original (AirDrop, chat saves), so the earlier
        // one is closer to when the photo was taken.
        let date_taken = unchanged
            .then(|| cached.and_then(|c| c.date_taken))
            .flatten()
            .or_else(|| AppleDate::earliest(file.creation_date, file.mod_date));

        let locality = if file.is_file_provider {
            PhotoLocality::Remote {
                downloaded: !file.is_placeholder,
            }
        } else {
            PhotoLocality::Local
        };
        // A former placeholder whose bytes have arrived needs a real EXIF
        // pass: its first enrichment ran against a byteless file.
        let became_downloaded = matches!(
            cached.map(|c| c.locality),
            Some(PhotoLocality::Remote { downloaded: false })
        ) && !file.is_placeholder;

        let cached_enriched = cached.and_then(|c| c.enriched_file_date);
        let stale = !unchanged
            || cached_enriched.is_none()
            || file.mod_date != cached_enriched
            || became_downloaded;
        if stale {
            self.needs_enrichment = true;
        }

        PhotoFile {
            id: StableId::for_photo(&file.path),
            url: gallery_model::photo::FileUrl::new(file.path.clone()),
            filename,
            file_size: file.file_size,
            date_taken,
            date_from_metadata: false,
            is_video,
            live_photo_video_url: live.map(gallery_model::photo::FileUrl::new),
            hierarchical_tags: unchanged
                .then(|| cached.map(|c| c.hierarchical_tags.clone()))
                .flatten()
                .unwrap_or_default(),
            country_code: unchanged
                .then(|| cached.and_then(|c| c.country_code.clone()))
                .flatten(),
            enriched_file_date: if stale { None } else { cached_enriched },
            file_modification_date: file.mod_date,
            gps_latitude: unchanged
                .then(|| cached.and_then(|c| c.gps_latitude))
                .flatten(),
            gps_longitude: unchanged
                .then(|| cached.and_then(|c| c.gps_longitude))
                .flatten(),
            face_regions: unchanged
                .then(|| cached.map(|c| c.face_regions.clone()))
                .flatten()
                .unwrap_or_default(),
            locality,
            sidecar_status: gallery_model::photo::SidecarStatus::Absent,
        }
    }

    /// One manifest row, reusing the cached one when nothing about the photo
    /// changed.
    ///
    /// That reuse is the whole optimisation: re-probing every `.xmp` cost 257
    /// of the 259 seconds a zero-change light scan used to take. The cached
    /// row is safe because the fast path requires an unchanged photo, the
    /// sidecar sync still diffs content versions, and a *deleted* sidecar
    /// drops out through the directory listing rather than through the cache.
    fn push_sidecar_row(&mut self, file: &ScanFile, photo: &PhotoFile, sidecar: &Entry) {
        let unchanged = self.input.cached_photos.get(&file.path).is_some_and(|c| {
            c.file_size == file.file_size && c.file_modification_date == file.mod_date
        });
        if self.input.reuse_cached && unchanged {
            if let Some(cached) = self.input.cached_sidecar_manifest.get(&photo.id) {
                self.sidecar_manifest.push(cached.clone());
                return;
            }
        }
        self.sidecar_manifest.push(SidecarCandidate {
            photo_id: photo.id,
            sidecar_url: gallery_model::photo::FileUrl::new(join(
                parent_of(&file.path),
                &sidecar.name,
            )),
            current_version: ContentVersion {
                content_identifier: sidecar.content_version.clone(),
                modification_date: sidecar.modified.map(apple_date),
                size: Some(sidecar.size as i64),
            },
            download_status: if sidecar.is_placeholder {
                DownloadStatus::Placeholder
            } else {
                DownloadStatus::Local
            },
        });
    }

    fn finish(self) -> ScanOutcome {
        let Walk {
            input,
            nodes,
            flat_photos,
            needs_enrichment,
            sidecar_manifest,
            added_paths,
            modified_paths,
            seen_paths,
            failed_directory_paths,
            ..
        } = self;

        // Anything cached and unseen was moved, removed or unmounted — unless
        // it lives under a directory whose listing failed, in which case it is
        // merely invisible this pass and must not be reported as gone.
        let mut removed_paths: Vec<String> = Vec::new();
        for path in input.cached_photos.keys() {
            if seen_paths.contains(path) {
                continue;
            }
            let normalized = decomposed(path);
            if failed_directory_paths
                .iter()
                .any(|failed| normalized.starts_with(&format!("{failed}/")))
            {
                continue;
            }
            removed_paths.push(path.clone());
        }

        let root_folder = (!nodes.is_empty()).then(|| build_folder(&nodes, 0));

        ScanOutcome {
            root_folder,
            flat_photos,
            needs_enrichment,
            sidecar_manifest,
            added_paths,
            removed_paths,
            modified_paths,
            failed_directory_paths,
        }
    }
}

/// Assemble the recursive tree from the flat node list.
fn build_folder(nodes: &[ScanNode], index: usize) -> PhotoFolder {
    let node = &nodes[index];
    let subfolders: Vec<PhotoFolder> = node
        .child_indices
        .iter()
        .map(|&child| build_folder(nodes, child))
        .collect();

    let total =
        node.photos.len() as i64 + subfolders.iter().map(|f| f.total_photo_count).sum::<i64>();

    // `photos.first`, else the first subfolder that has a cover. Within-folder
    // order is unspecified, so *which* photo this is, is unspecified too — the
    // fixture records the rule, not the URL.
    let cover = node
        .photos
        .first()
        .map(|p| p.url.clone())
        .or_else(|| subfolders.iter().find_map(|f| f.cover_photo_url.clone()));

    PhotoFolder {
        id: StableId::for_folder(&node.path),
        url: gallery_model::photo::FileUrl::new(node.path.clone()),
        name: node.name.clone(),
        subfolders,
        photos: node.photos.clone(),
        cover_photo_url: cover,
        total_photo_count: total,
        date_modified: node.date_modified,
        date_created: node.date_created,
    }
}

fn apple_date(t: FileTime) -> AppleDate {
    AppleDate::from_unix(t.secs, t.subsec_nanos)
}

/// Everything up to the last `/`. `"/"` for a top-level path.
fn parent_of(path: &str) -> &str {
    match path.rfind('/') {
        Some(0) | None => "/",
        Some(i) => &path[..i],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_vfs::MemVfs;

    fn library() -> MemVfs {
        let vfs = MemVfs::new();
        vfs.insert_at("/lib/a.jpg", vec![0u8; 10], FileTime::new(1000, 0));
        vfs.insert_at("/lib/B.JPG", vec![0u8; 11], FileTime::new(1001, 0));
        vfs.insert_at("/lib/B.JPG.xmp", vec![0u8; 5], FileTime::new(1002, 0));
        vfs.insert_at("/lib/Nested/n.jpg", vec![0u8; 12], FileTime::new(1003, 0));
        vfs.insert_at("/lib/Media/Clip.MOV", vec![0u8; 13], FileTime::new(1004, 0));
        vfs.insert_at(
            "/lib/Media/IMG_1.jpg",
            vec![0u8; 14],
            FileTime::new(1005, 0),
        );
        vfs.insert_at(
            "/lib/Media/IMG_1.mov",
            vec![0u8; 15],
            FileTime::new(1006, 0),
        );
        vfs.insert_at("/lib/Junk/readme.txt", vec![0u8; 3], FileTime::new(1007, 0));
        vfs.insert_at(
            "/lib/Junk/.hidden.jpg",
            vec![0u8; 3],
            FileTime::new(1008, 0),
        );
        vfs
    }

    fn paths(photos: &[PhotoFile]) -> Vec<&str> {
        let mut out: Vec<&str> = photos.iter().map(|p| p.path()).collect();
        out.sort_unstable();
        out
    }

    fn cache(outcome: &ScanOutcome) -> ScanInput {
        ScanInput {
            reuse_cached: true,
            cached_photos: outcome
                .flat_photos
                .iter()
                .map(|p| (p.path().to_string(), p.clone()))
                .collect(),
            cached_sidecar_manifest: outcome
                .sidecar_manifest
                .iter()
                .map(|r| (r.photo_id, r.clone()))
                .collect(),
        }
    }

    #[test]
    fn a_cold_scan_finds_the_media_and_skips_everything_else() {
        let vfs = library();
        let out = scan(&vfs, "/lib", &ScanInput::default());
        assert_eq!(
            paths(&out.flat_photos),
            vec![
                "/lib/B.JPG",
                "/lib/Media/Clip.MOV",
                "/lib/Media/IMG_1.jpg",
                "/lib/Nested/n.jpg",
                "/lib/a.jpg",
            ],
            "readme.txt, .hidden.jpg and the paired IMG_1.mov are not photos"
        );
        assert!(out.needs_enrichment);
        assert_eq!(out.added_paths.len(), 5);
        assert!(out.removed_paths.is_empty() && out.modified_paths.is_empty());
    }

    #[test]
    fn a_paired_movie_belongs_to_its_image_and_a_lone_one_does_not() {
        let out = scan(&library(), "/lib", &ScanInput::default());
        let image = out
            .flat_photos
            .iter()
            .find(|p| p.path() == "/lib/Media/IMG_1.jpg")
            .unwrap();
        assert_eq!(
            image.live_photo_video_url.as_ref().map(|u| u.path()),
            Some("/lib/Media/IMG_1.mov")
        );
        let clip = out
            .flat_photos
            .iter()
            .find(|p| p.path() == "/lib/Media/Clip.MOV")
            .unwrap();
        assert!(clip.is_video);
        assert_eq!(
            clip.filename, "clip",
            "the standalone-video stem is lowercased"
        );
    }

    #[test]
    fn folders_come_out_in_localized_standard_order_with_recursive_counts() {
        let out = scan(&library(), "/lib", &ScanInput::default());
        let root = out.root_folder.unwrap();
        assert_eq!(
            root.subfolders
                .iter()
                .map(|f| f.name.as_str())
                .collect::<Vec<_>>(),
            vec!["Junk", "Media", "Nested"]
        );
        assert_eq!(root.total_photo_count, 5);
        assert_eq!(root.photos.len(), 2);
        assert!(root.date_modified.is_some() && root.date_created.is_some());
        let junk = &root.subfolders[0];
        assert_eq!(junk.total_photo_count, 0);
        assert_eq!(junk.cover_photo_url, None);
    }

    #[test]
    fn only_images_get_sidecar_rows_and_they_key_on_the_full_basename() {
        let vfs = library();
        // A sidecar next to the standalone video, which must be ignored.
        vfs.insert_at(
            "/lib/Media/Clip.MOV.xmp",
            vec![0u8; 7],
            FileTime::new(1009, 0),
        );
        let out = scan(&vfs, "/lib", &ScanInput::default());
        assert_eq!(out.sidecar_manifest.len(), 1);
        let row = &out.sidecar_manifest[0];
        assert_eq!(row.sidecar_url.path(), "/lib/B.JPG.xmp");
        assert_eq!(row.current_version.size, Some(5));
        assert_eq!(row.download_status, DownloadStatus::Local);
    }

    #[test]
    fn a_light_scan_cannot_see_a_change_to_a_file_it_already_knows() {
        let vfs = library();
        let cold = scan(&vfs, "/lib", &ScanInput::default());
        // Bigger *and* newer — the strongest change signal there is.
        vfs.insert_at("/lib/a.jpg", vec![0u8; 999], FileTime::new(9999, 0));

        let light = scan(&vfs, "/lib", &cache(&cold));
        assert!(
            light.modified_paths.is_empty(),
            "the blind spot is total: light reuses the cached size and mtime"
        );

        let full = scan(
            &vfs,
            "/lib",
            &ScanInput {
                reuse_cached: false,
                ..cache(&cold)
            },
        );
        assert_eq!(full.modified_paths, vec!["/lib/a.jpg"]);
    }

    #[test]
    fn neither_scan_kind_notices_a_same_size_same_mtime_rewrite() {
        let vfs = library();
        let cold = scan(&vfs, "/lib", &ScanInput::default());
        vfs.insert_at("/lib/a.jpg", vec![7u8; 10], FileTime::new(1000, 0));
        for reuse_cached in [true, false] {
            let out = scan(
                &vfs,
                "/lib",
                &ScanInput {
                    reuse_cached,
                    ..cache(&cold)
                },
            );
            assert!(
                out.modified_paths.is_empty(),
                "reuse_cached = {reuse_cached}"
            );
        }
    }

    #[test]
    fn a_deleted_photo_is_reported_removed() {
        let vfs = library();
        let cold = scan(&vfs, "/lib", &ScanInput::default());
        let vfs2 = MemVfs::new();
        for path in vfs.paths() {
            if path != "/lib/Nested/n.jpg" {
                vfs2.insert(&path, vfs.read(&path).unwrap());
            }
        }
        let out = scan(&vfs2, "/lib", &cache(&cold));
        assert_eq!(out.removed_paths, vec!["/lib/Nested/n.jpg"]);
    }

    #[test]
    fn a_light_scan_refreshes_pairing_without_rebuilding_the_photo() {
        let vfs = library();
        let mut cold = scan(&vfs, "/lib", &ScanInput::default());
        // Decorate the cached entry with things only enrichment sets, so a
        // rebuild would be visible.
        for photo in &mut cold.flat_photos {
            photo.date_from_metadata = true;
            photo.country_code = Some("IT".into());
        }
        let out = scan(&vfs, "/lib", &cache(&cold));
        let a = out
            .flat_photos
            .iter()
            .find(|p| p.path() == "/lib/a.jpg")
            .unwrap();
        assert!(a.date_from_metadata, "the cached PhotoFile was rebuilt");
        assert_eq!(a.country_code.as_deref(), Some("IT"));
    }

    #[test]
    fn sub_second_mtimes_participate_in_the_change_signal() {
        // Truncating to whole seconds here would make this rewrite invisible
        // to a *full* scan too, which is not the pinned behaviour.
        let vfs = MemVfs::new();
        vfs.insert_at("/lib/a.jpg", vec![0u8; 10], FileTime::new(1000, 0));
        let cold = scan(&vfs, "/lib", &ScanInput::default());
        vfs.insert_at(
            "/lib/a.jpg",
            vec![0u8; 10],
            FileTime::new(1000, 500_000_000),
        );
        let full = scan(
            &vfs,
            "/lib",
            &ScanInput {
                reuse_cached: false,
                ..cache(&cold)
            },
        );
        assert_eq!(full.modified_paths, vec!["/lib/a.jpg"]);
    }

    #[test]
    fn progress_is_reported_at_least_once_with_the_true_total() {
        let vfs = library();
        let seen = std::cell::RefCell::new(Vec::new());
        let out = scan_with_progress(
            &vfs,
            "/lib",
            &ScanInput::default(),
            Some(&|n| seen.borrow_mut().push(n)),
        );
        assert_eq!(seen.borrow().last().copied(), Some(out.flat_photos.len()));
    }

    #[test]
    fn a_missing_root_produces_no_tree_and_no_photos() {
        let vfs = MemVfs::new();
        vfs.insert("/other/a.jpg", vec![0u8; 1]);
        let out = scan(&vfs, "/lib", &ScanInput::default());
        assert!(out.flat_photos.is_empty());
        assert_eq!(out.failed_directory_paths, vec!["/lib"]);
        // The root still becomes a node — it is the tree's anchor.
        assert!(out.root_folder.is_some());
    }

    #[test]
    fn parents_are_everything_before_the_last_separator() {
        assert_eq!(parent_of("/a/b/c.jpg"), "/a/b");
        assert_eq!(parent_of("/c.jpg"), "/");
        assert_eq!(parent_of("c.jpg"), "/");
    }
}
