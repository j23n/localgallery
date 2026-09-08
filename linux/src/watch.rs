//! Directory-only library watch. Sidecar writes from Scan Photos look like
//! mutations, so the host mutes this for the length of a walk or analysis
//! run — same rule as iOS `LibraryRootMonitor.shouldIgnoreEvents`.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use gallery_model::photo::PhotoFolder;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};

pub use gallery_session::watch::{should_note, REFRESH_INTERVAL};

/// Root plus every folder in the last published tree, de-duplicated.
/// Directories only — photo files are not watched.
pub fn watch_dirs(root: &Path, tree: Option<&PhotoFolder>) -> Vec<PathBuf> {
    let mut ordered = vec![root.to_path_buf()];
    if let Some(tree) = tree {
        collect_dirs(tree, &mut ordered);
    }
    let mut seen = HashSet::new();
    ordered
        .into_iter()
        .filter(|p| seen.insert(std::fs::canonicalize(p).unwrap_or_else(|_| p.clone())))
        .collect()
}

fn collect_dirs(folder: &PhotoFolder, out: &mut Vec<PathBuf>) {
    out.push(PathBuf::from(folder.url.path()));
    for child in &folder.subfolders {
        collect_dirs(child, out);
    }
}

/// Holds the inotify watcher and the debounce thread.
pub struct WatchHandle {
    stop: Arc<AtomicBool>,
    _watcher: RecommendedWatcher,
}

impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// Watch `root` recursively. Events are coalesced and sent as `()` on the
/// returned receiver. `mute` drops events while the host is writing sidecars
/// or walking the tree.
pub fn start(root: PathBuf, mute: Arc<AtomicBool>) -> std::io::Result<(WatchHandle, Receiver<()>)> {
    let (raw_tx, raw_rx) = mpsc::channel::<()>();
    let mut watcher = RecommendedWatcher::new(
        move |res: Result<Event, notify::Error>| {
            if res.is_ok() {
                let _ = raw_tx.send(());
            }
        },
        notify::Config::default(),
    )
    .map_err(|e| std::io::Error::other(e.to_string()))?;
    watcher
        .watch(&root, RecursiveMode::Recursive)
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    let (out_tx, out_rx) = mpsc::channel();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    thread::spawn(move || coalesce_loop(raw_rx, out_tx, mute, stop_thread));

    Ok((
        WatchHandle {
            stop,
            _watcher: watcher,
        },
        out_rx,
    ))
}

fn coalesce_loop(
    raw: Receiver<()>,
    out: mpsc::Sender<()>,
    mute: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) {
    let mut pending: Option<Instant> = None;
    loop {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let timeout = pending
            .map(|t| REFRESH_INTERVAL.saturating_sub(t.elapsed()))
            .unwrap_or(Duration::from_millis(200));
        match raw.recv_timeout(timeout) {
            Ok(()) => {
                if should_note(true, mute.load(Ordering::Relaxed)) {
                    pending = Some(Instant::now());
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                if pending.is_some_and(|t| t.elapsed() >= REFRESH_INTERVAL) {
                    pending = None;
                    if should_note(true, mute.load(Ordering::Relaxed)) && out.send(()).is_err() {
                        return;
                    }
                }
            }
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_model::photo::{FileUrl, PhotoFolder, StableId};

    fn folder(path: &str, name: &str, subs: Vec<PhotoFolder>) -> PhotoFolder {
        PhotoFolder {
            id: StableId::for_folder(path),
            url: FileUrl::new(path),
            name: name.into(),
            subfolders: subs,
            photos: vec![],
            cover_photo_url: None,
            total_photo_count: 0,
            date_modified: None,
            date_created: None,
        }
    }

    #[test]
    fn watch_dirs_are_root_plus_tree_folders() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let a = root.join("a");
        let b = a.join("b");
        std::fs::create_dir_all(&b).unwrap();
        let leaf = folder(b.to_str().unwrap(), "b", vec![]);
        let mid = folder(a.to_str().unwrap(), "a", vec![leaf]);
        let tree = folder(root.to_str().unwrap(), "lib", vec![mid]);
        let dirs = watch_dirs(root, Some(&tree));
        assert!(dirs.iter().any(|p| p == root));
        assert!(dirs.iter().any(|p| p.ends_with("a")));
        assert!(dirs.iter().any(|p| p.ends_with("b")));
    }

    #[test]
    fn mute_drops_events() {
        assert!(should_note(true, false));
        assert!(!should_note(true, true));
        assert!(!should_note(false, false));
    }
}
