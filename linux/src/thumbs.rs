//! Bounded thumbnail / viewer decode pool. GTK binds pictures; this file
//! owns the worker count, in-flight key set, and the ready-frame cache.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

use gallery_model::photo::FaceRegion;

use crate::decode::{decode_limited, RgbFrame};
use crate::faces::crop_region;
use crate::xdg_thumb::{self, ThumbSize};

/// Default worker threads. Two keeps a 4 GB Comet from exploding; the
/// channel queues the rest.
pub const DEFAULT_WORKERS: usize = 2;

/// Hard cap on decode threads.
pub const MAX_WORKERS: usize = 4;

/// Ready-cache entry cap (one decoded tile or viewer frame each).
pub const MAX_READY_ENTRIES: usize = 192;

/// Ready-cache RGB-byte budget.
pub const MAX_READY_COST: usize = 48 * 1024 * 1024;

/// Clamp a requested pool size into `1..=`[`MAX_WORKERS`].
pub fn clamp_workers(n: usize) -> usize {
    n.clamp(1, MAX_WORKERS)
}

/// In-flight key book: at most one job per key, regardless of waiter count.
#[derive(Debug)]
pub struct FlightBook {
    inflight: HashSet<String>,
    workers: usize,
}

impl FlightBook {
    /// Empty book for `workers` threads (clamped).
    pub fn new(workers: usize) -> Self {
        Self {
            inflight: HashSet::new(),
            workers: clamp_workers(workers),
        }
    }

    /// Thread count the pool was built for.
    pub fn workers(&self) -> usize {
        self.workers
    }

    /// Keys submitted and not yet finished.
    pub fn inflight_len(&self) -> usize {
        self.inflight.len()
    }

    /// Whether this key already has a job on the wire.
    pub fn is_inflight(&self, key: &str) -> bool {
        self.inflight.contains(key)
    }

    /// Claim `key`. `false` if a job is already in flight (join that one).
    pub fn try_start(&mut self, key: &str) -> bool {
        self.inflight.insert(key.to_string())
    }

    /// Release `key` after a completion (live or obsolete).
    pub fn finish(&mut self, key: &str) {
        self.inflight.remove(key);
    }
}

/// LRU map with an entry cap and a cost cap (RGB bytes).
#[derive(Debug)]
pub struct ReadyCache<V> {
    entries: HashMap<String, ReadyEntry<V>>,
    lru: VecDeque<String>,
    cost: usize,
    max_entries: usize,
    max_cost: usize,
}

#[derive(Debug)]
struct ReadyEntry<V> {
    value: V,
    cost: usize,
}

impl<V> ReadyCache<V> {
    /// Empty cache with the given bounds.
    pub fn new(max_entries: usize, max_cost: usize) -> Self {
        Self {
            entries: HashMap::new(),
            lru: VecDeque::new(),
            cost: 0,
            max_entries: max_entries.max(1),
            max_cost: max_cost.max(1),
        }
    }

    /// Product defaults.
    pub fn product() -> Self {
        Self::new(MAX_READY_ENTRIES, MAX_READY_COST)
    }

    /// Number of live entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Sum of stored costs.
    pub fn cost(&self) -> usize {
        self.cost
    }

    /// Borrow a value, marking it most-recent.
    pub fn get(&mut self, key: &str) -> Option<&V> {
        if self.entries.contains_key(key) {
            self.touch(key);
            self.entries.get(key).map(|e| &e.value)
        } else {
            None
        }
    }

    /// Clone-out helper for GTK textures.
    pub fn get_cloned(&mut self, key: &str) -> Option<V>
    where
        V: Clone,
    {
        if self.entries.contains_key(key) {
            self.touch(key);
            self.entries.get(key).map(|e| e.value.clone())
        } else {
            None
        }
    }

    /// Insert, then evict until both bounds hold. Keeps at least the newest
    /// entry so a single oversize frame cannot empty the cache and disappear.
    pub fn insert(&mut self, key: String, value: V, cost: usize) {
        if let Some(old) = self.entries.remove(&key) {
            self.cost = self.cost.saturating_sub(old.cost);
            self.lru.retain(|k| k != &key);
        }
        self.entries.insert(key.clone(), ReadyEntry { value, cost });
        self.lru.push_back(key);
        self.cost = self.cost.saturating_add(cost);
        self.evict();
    }

    fn touch(&mut self, key: &str) {
        if let Some(i) = self.lru.iter().position(|k| k == key) {
            if let Some(k) = self.lru.remove(i) {
                self.lru.push_back(k);
            }
        }
    }

    fn evict(&mut self) {
        while self.entries.len() > 1
            && (self.entries.len() > self.max_entries || self.cost > self.max_cost)
        {
            let Some(old) = self.lru.pop_front() else {
                break;
            };
            if let Some(e) = self.entries.remove(&old) {
                self.cost = self.cost.saturating_sub(e.cost);
            }
        }
    }
}

/// RGB byte cost of a frame (tight buffer).
pub fn frame_cost(frame: &RgbFrame) -> usize {
    frame.rgb.len()
}

/// What a completion should do with the GTK waiters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompleteAction {
    /// Waiters are still listening — paint them.
    Deliver,
    /// No waiters (rebound / cancelled) — cache only, do not publish.
    Obsolete,
}

/// A completion is obsolete when nobody is waiting for that key anymore.
pub fn complete_action(waiter_count: usize) -> CompleteAction {
    if waiter_count == 0 {
        CompleteAction::Obsolete
    } else {
        CompleteAction::Deliver
    }
}

/// Work handed to a pool thread.
pub struct PoolJob {
    /// Cache / waiter key.
    pub key: String,
    /// Filesystem path.
    pub path: String,
    /// Decode flavour.
    pub kind: PoolKind,
}

/// Kind of display decode.
pub enum PoolKind {
    /// XDG grid tile.
    Grid {
        /// Bucket.
        size: ThumbSize,
    },
    /// Viewer, long side capped.
    Viewer {
        /// Device-pixel long side.
        max_side: u32,
    },
    /// Face crop from the display thumb.
    Face {
        /// Bucket the thumb is taken from.
        size: ThumbSize,
        /// MWG rectangle.
        region: FaceRegion,
    },
}

/// Result of one pool job (frame may be missing).
pub struct PoolResult {
    /// Key the job was started under.
    pub key: String,
    /// Decoded pixels, if the file opened.
    pub frame: Option<RgbFrame>,
}

/// Bounded worker pool. Submit unique keys; join duplicates in the UI.
pub struct DecodePool {
    jobs: Sender<PoolJob>,
    workers: usize,
}

impl DecodePool {
    /// Spawn `workers` threads that decode with the product backends.
    pub fn spawn(workers: usize, results: Sender<PoolResult>) -> Self {
        Self::spawn_work(workers, results, run_job)
    }

    /// Spawn with an injected body (tests).
    pub fn spawn_work<F>(workers: usize, results: Sender<PoolResult>, work: F) -> Self
    where
        F: Fn(&PoolJob) -> Option<RgbFrame> + Send + Sync + 'static,
    {
        let workers = clamp_workers(workers);
        let (jobs, job_rx) = mpsc::channel::<PoolJob>();
        let job_rx = Arc::new(Mutex::new(job_rx));
        let work = Arc::new(work);
        for _ in 0..workers {
            let rx = job_rx.clone();
            let tx = results.clone();
            let work = work.clone();
            thread::spawn(move || loop {
                let job = {
                    let guard = match rx.lock() {
                        Ok(g) => g,
                        Err(_) => return,
                    };
                    guard.recv()
                };
                let Ok(job) = job else {
                    return;
                };
                let frame = work(&job);
                if tx
                    .send(PoolResult {
                        key: job.key,
                        frame,
                    })
                    .is_err()
                {
                    return;
                }
            });
        }
        Self { jobs, workers }
    }

    /// How many threads this pool started.
    pub fn worker_count(&self) -> usize {
        self.workers
    }

    /// Queue a job. Callers must have won [`FlightBook::try_start`].
    pub fn submit(&self, job: PoolJob) {
        let _ = self.jobs.send(job);
    }
}

fn run_job(job: &PoolJob) -> Option<RgbFrame> {
    match &job.kind {
        PoolKind::Grid { size } => {
            xdg_thumb::load_or_make(&xdg_thumb::cache_root(), &job.path, *size)
        }
        PoolKind::Viewer { max_side } => decode_limited(&job.path, *max_side),
        PoolKind::Face { size, region } => {
            xdg_thumb::load_or_make(&xdg_thumb::cache_root(), &job.path, *size)
                .and_then(|frame| crop_region(&frame, region))
        }
    }
}

/// Cache key for a grid / viewer / face bind.
pub fn job_key(id: &str, kind: &PoolKind) -> String {
    match kind {
        PoolKind::Grid { size } => format!("{id}:xdg:{}", size.dir_name()),
        PoolKind::Viewer { max_side } => format!("{id}:view:{max_side}"),
        PoolKind::Face { size, region } => format!(
            "{id}:face:{}:{:.3}:{:.3}",
            size.dir_name(),
            region.center_x,
            region.center_y
        ),
    }
}

/// Split a result channel the GTK pump can drain.
pub fn result_channel() -> (Sender<PoolResult>, Receiver<PoolResult>) {
    mpsc::channel()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    #[test]
    fn workers_are_clamped() {
        assert_eq!(clamp_workers(0), 1);
        assert_eq!(clamp_workers(2), 2);
        assert_eq!(clamp_workers(99), MAX_WORKERS);
        assert_eq!(FlightBook::new(99).workers(), MAX_WORKERS);
    }

    #[test]
    fn inflight_dedups_the_same_key() {
        let mut book = FlightBook::new(2);
        assert!(book.try_start("a:xdg:large"));
        assert!(!book.try_start("a:xdg:large"));
        assert!(book.is_inflight("a:xdg:large"));
        assert!(book.try_start("b:xdg:large"));
        assert_eq!(book.inflight_len(), 2);
        book.finish("a:xdg:large");
        assert!(!book.is_inflight("a:xdg:large"));
        assert!(book.try_start("a:xdg:large"));
    }

    #[test]
    fn ready_cache_evicts_by_entry_and_cost() {
        let mut cache = ReadyCache::new(2, 10);
        cache.insert("a".into(), 1u8, 4);
        cache.insert("b".into(), 2, 4);
        cache.insert("c".into(), 3, 4);
        assert_eq!(cache.len(), 2);
        assert!(cache.get("a").is_none());
        assert_eq!(cache.get("c").copied(), Some(3));

        let mut tight = ReadyCache::new(8, 5);
        tight.insert("x".into(), 1u8, 3);
        tight.insert("y".into(), 2, 3);
        assert_eq!(tight.len(), 1);
        assert!(tight.cost() <= 5);
        assert_eq!(tight.get("y").copied(), Some(2));
    }

    #[test]
    fn empty_waiters_are_obsolete() {
        assert_eq!(complete_action(0), CompleteAction::Obsolete);
        assert_eq!(complete_action(2), CompleteAction::Deliver);
    }

    #[test]
    fn pool_never_exceeds_worker_bound() {
        let current = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let (tx, rx) = result_channel();
        let work = {
            let current = current.clone();
            let peak = peak.clone();
            move |_job: &PoolJob| {
                let n = current.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(n, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(30));
                current.fetch_sub(1, Ordering::SeqCst);
                None
            }
        };
        let pool = DecodePool::spawn_work(2, tx, work);
        assert_eq!(pool.worker_count(), 2);
        for i in 0..8 {
            pool.submit(PoolJob {
                key: format!("k{i}"),
                path: String::new(),
                kind: PoolKind::Viewer { max_side: 8 },
            });
        }
        let mut got = 0;
        while got < 8 {
            rx.recv().expect("pool result");
            got += 1;
        }
        assert!(
            peak.load(Ordering::SeqCst) <= 2,
            "peak concurrency {}",
            peak.load(Ordering::SeqCst)
        );
    }
}
