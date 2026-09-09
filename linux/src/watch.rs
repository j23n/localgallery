//! Directory-only library watch. Sidecar writes from Scan Photos look like
//! mutations, so the host mutes this for the length of a walk or analysis
//! run — same rule as iOS `LibraryRootMonitor.shouldIgnoreEvents`.
//!
//! Mute does not drop the fact that *something* happened: a dirty bit is
//! kept, and unmuting triggers exactly one reconciliation.

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

/// Mute flag plus the dirty bit retained while events are suppressed.
#[derive(Debug, Default)]
pub struct MuteGate {
    muted: AtomicBool,
    dirty: AtomicBool,
}

/// What to do with a filesystem event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventAction {
    /// Not muted — coalesce / fire as usual.
    Coalesce,
    /// Muted — remember that a pass is needed after unmute.
    MarkDirty,
}

/// What unmuting should do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnmuteAction {
    /// Nothing happened while muted (or we just muted).
    Idle,
    /// At least one event was suppressed — run one reconciliation.
    ReconcileOnce,
}

impl MuteGate {
    /// Shared gate for the watcher thread and the GTK host.
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Whether events are currently suppressed.
    pub fn is_muted(&self) -> bool {
        self.muted.load(Ordering::Acquire)
    }

    /// Whether a suppressed event is waiting for unmute.
    pub fn is_dirty(&self) -> bool {
        self.dirty.load(Ordering::Acquire)
    }

    /// Note a disk event. Muted events set the dirty bit and are not fired.
    pub fn note_event(&self) -> EventAction {
        if self.is_muted() {
            self.dirty.store(true, Ordering::Release);
            EventAction::MarkDirty
        } else {
            EventAction::Coalesce
        }
    }

    /// Mute or unmute. Unmuting with a dirty bit returns
    /// [`UnmuteAction::ReconcileOnce`] exactly once (the bit is cleared).
    pub fn set_muted(&self, muted: bool) -> UnmuteAction {
        let was = self.muted.swap(muted, Ordering::AcqRel);
        if was && !muted && self.dirty.swap(false, Ordering::AcqRel) {
            UnmuteAction::ReconcileOnce
        } else {
            UnmuteAction::Idle
        }
    }
}

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
/// returned receiver. `mute` retains a dirty bit while the host is writing
/// sidecars or walking the tree; the host reconciles once on unmute.
pub fn start(root: PathBuf, mute: Arc<MuteGate>) -> std::io::Result<(WatchHandle, Receiver<()>)> {
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
    mute: Arc<MuteGate>,
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
            Ok(()) => match mute.note_event() {
                EventAction::Coalesce => pending = Some(Instant::now()),
                EventAction::MarkDirty => {}
            },
            Err(RecvTimeoutError::Timeout) => {
                if pending.is_some_and(|t| t.elapsed() >= REFRESH_INTERVAL) {
                    pending = None;
                    match mute.note_event() {
                        EventAction::Coalesce => {
                            if out.send(()).is_err() {
                                return;
                            }
                        }
                        EventAction::MarkDirty => {}
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

    #[test]
    fn muted_events_set_dirty_and_unmute_reconciles_once() {
        let gate = MuteGate::new();
        assert_eq!(gate.note_event(), EventAction::Coalesce);
        assert_eq!(gate.set_muted(true), UnmuteAction::Idle);
        assert_eq!(gate.note_event(), EventAction::MarkDirty);
        assert_eq!(gate.note_event(), EventAction::MarkDirty);
        assert!(gate.is_dirty());
        assert_eq!(gate.set_muted(false), UnmuteAction::ReconcileOnce);
        assert!(!gate.is_dirty());
        assert_eq!(gate.set_muted(false), UnmuteAction::Idle);
        assert_eq!(gate.note_event(), EventAction::Coalesce);
    }

    #[test]
    fn unmute_without_events_does_not_reconcile() {
        let gate = MuteGate::new();
        assert_eq!(gate.set_muted(true), UnmuteAction::Idle);
        assert_eq!(gate.set_muted(false), UnmuteAction::Idle);
    }
}
