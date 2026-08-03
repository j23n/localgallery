//! The run-thread plumbing both sessions are built on.
//!
//! [`crate::tagging`] and [`crate::faces`] wrap two different engines, but the
//! *shape* of the boundary is identical and load-bearing in exactly the same
//! places: one run at a time, the run lock released before `on_finished` fires,
//! the release-then-report pair surviving a panic, and no path that can make a
//! thread join itself. Those four facts are the contract the app's services
//! rely on, and they are stated once, here, rather than twice.
//!
//! What the two sessions still own for themselves is everything *typed*: their
//! error enums, their summaries, and the shape of their listener. Only the
//! mechanics are shared.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;

/// Take a lock, ignoring poisoning.
///
/// A poisoned mutex here means a previous holder panicked while it held the
/// thread slot — the data behind it is an `Option<JoinHandle>` or a plain
/// summary, neither of which a panic can leave in a half-written state.
/// Propagating the poison would turn a recoverable run failure into a session
/// that can never start again.
pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Join `handle` unless it *is* the current thread.
///
/// `on_finished` runs on the run thread, and the contract explicitly invites a
/// listener to call `start()` from it — or to drop its last session reference,
/// which reaches `Drop`. Both paths would otherwise join the very thread they
/// are running on, and a self-join aborts the process. Skipping the join
/// detaches the thread, which is safe precisely here: the thread is finishing
/// its own last statement, so nothing outlives what the join was protecting.
pub(crate) fn join_unless_current(handle: JoinHandle<()>) {
    if handle.thread().id() == std::thread::current().id() {
        return;
    }
    let _ = handle.join();
}

/// Why [`RunLock::start`] did not spawn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StartError {
    /// A run is already in flight.
    AlreadyRunning,
    /// The OS refused a thread.
    Spawn(String),
}

/// One core-owned run thread, and the lock that keeps there being only one.
///
/// Holds the cancel flag too: the two are always set and cleared together
/// (`start` clears cancel under the lock, `Drop` sets it before joining), and
/// keeping them in one place is what makes that ordering checkable.
pub(crate) struct RunLock {
    running: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
    /// The in-flight (or just-finished) run thread, joined on the next `start`
    /// and on drop so a session never outlives its worker.
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl RunLock {
    pub(crate) fn new() -> RunLock {
        RunLock {
            running: Arc::new(AtomicBool::new(false)),
            cancel: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
        }
    }

    /// Whether a run is in flight.
    pub(crate) fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    /// Ask the in-flight run to stop. Returns immediately.
    pub(crate) fn request_cancel(&self) {
        self.cancel.store(true, Ordering::Release);
    }

    /// Take the lock and spawn `body` on a named thread.
    ///
    /// `body` is handed the cancel flag and the running flag: the first to pass
    /// to the engine, the second to build a [`FinishGuard`] from, which is what
    /// releases the lock on the way out.
    pub(crate) fn start<F>(&self, name: &str, body: F) -> Result<(), StartError>
    where
        F: FnOnce(Arc<AtomicBool>, Arc<AtomicBool>) + Send + 'static,
    {
        // Acquire the run lock before touching anything else: two concurrent
        // `start` calls must not both get as far as spawning.
        if self
            .running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(StartError::AlreadyRunning);
        }

        // Reap the previous run's thread. It has already cleared `running`, so
        // this join is effectively instant; skipping it would leak a thread
        // handle per run.
        let mut slot = lock(&self.thread);
        if let Some(previous) = slot.take() {
            join_unless_current(previous);
        }

        self.cancel.store(false, Ordering::Release);
        let cancel = Arc::clone(&self.cancel);
        let running = Arc::clone(&self.running);

        match std::thread::Builder::new()
            .name(name.to_string())
            .spawn(move || body(cancel, running))
        {
            Ok(handle) => {
                *slot = Some(handle);
                Ok(())
            }
            Err(e) => {
                self.running.store(false, Ordering::Release);
                Err(StartError::Spawn(e.to_string()))
            }
        }
    }

    /// Cancel and join, for `Drop`.
    ///
    /// A detached worker thread would keep the engine — and with it the SQLite
    /// connection — alive past the session the app thinks it released.
    pub(crate) fn shutdown(&self) {
        self.cancel.store(true, Ordering::Release);
        if let Some(handle) = lock(&self.thread).take() {
            join_unless_current(handle);
        }
    }
}

/// Runs the end-of-run cleanup on the way out of the run thread, unwinding or
/// not: release the run lock first, then report.
///
/// The ordering is the documented contract — a listener that reacts to
/// `onFinished` by calling `isRunning()` or `start()` must see a settled
/// session — and it is why this is a guard rather than two statements: a panic
/// between them would strand the lock.
///
/// `report` is handed `None` when the run thread unwound before setting a
/// summary. Each session decides what that means; both report it as a failure
/// rather than as a quiet zero-item success.
pub(crate) struct FinishGuard<S, F: FnOnce(Option<S>)> {
    running: Arc<AtomicBool>,
    report: Option<F>,
    /// Set by the run body just before it returns.
    pub(crate) summary: Option<S>,
}

impl<S, F: FnOnce(Option<S>)> FinishGuard<S, F> {
    pub(crate) fn new(running: Arc<AtomicBool>, report: F) -> FinishGuard<S, F> {
        FinishGuard {
            running,
            report: Some(report),
            summary: None,
        }
    }
}

impl<S, F: FnOnce(Option<S>)> Drop for FinishGuard<S, F> {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Release);
        if let Some(report) = self.report.take() {
            report(self.summary.take());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The guard is what keeps a panicking run thread from latching `running`
    /// true forever — after which every `start` answers `AlreadyRunning` and
    /// the app's UI is wedged until it is killed.
    /// What a report saw: the summary it was handed, and `running` as observed
    /// from inside it — the ordering the listener traits document.
    type Observed = Arc<Mutex<Vec<(Option<u32>, bool)>>>;

    #[test]
    fn an_unwinding_run_thread_still_releases_the_lock_and_reports() {
        let running = Arc::new(AtomicBool::new(true));
        let reported: Observed = Arc::new(Mutex::new(Vec::new()));

        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let flag = Arc::clone(&running);
            let sink = Arc::clone(&reported);
            let _guard = FinishGuard::new(Arc::clone(&running), move |summary: Option<u32>| {
                lock(&sink).push((summary, flag.load(Ordering::Acquire)));
            });
            panic!("the run thread exploded");
        }))
        .is_err();
        std::panic::set_hook(previous);

        assert!(unwound);
        assert!(
            !running.load(Ordering::Acquire),
            "the run lock was stranded"
        );
        // Exactly once, with no summary, and released *before* the report so a
        // listener that restarts the session from it sees a settled one.
        assert_eq!(lock(&reported).as_slice(), &[(None, false)]);
    }

    #[test]
    fn a_completed_run_reports_the_summary_it_was_given() {
        let reported: Arc<Mutex<Vec<Option<u32>>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&reported);
        let mut guard = FinishGuard::new(Arc::new(AtomicBool::new(true)), move |s: Option<u32>| {
            lock(&sink).push(s);
        });
        guard.summary = Some(7);
        drop(guard);
        assert_eq!(lock(&reported).as_slice(), &[Some(7)]);
    }

    /// `on_finished` runs on the run thread and the contract invites a listener
    /// to call `start()` (or release its last session reference) from it. Both
    /// reach a `JoinHandle` for the thread they are standing on, and joining
    /// yourself aborts the process.
    #[test]
    fn a_thread_handed_its_own_handle_does_not_self_join() {
        let done = Arc::new(AtomicBool::new(false));
        let (tx, rx) = std::sync::mpsc::channel::<JoinHandle<()>>();

        let flag = Arc::clone(&done);
        let handle = std::thread::spawn(move || {
            let own = rx.recv().expect("handle");
            join_unless_current(own);
            flag.store(true, Ordering::SeqCst);
        });
        tx.send(handle).unwrap();

        for _ in 0..300 {
            if done.load(Ordering::SeqCst) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("the thread never got past join_unless_current — it self-joined");
    }

    #[test]
    fn a_handle_for_another_thread_is_still_joined() {
        let done = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&done);
        let handle = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(20));
            flag.store(true, Ordering::SeqCst);
        });
        join_unless_current(handle);
        assert!(done.load(Ordering::SeqCst), "the join did not wait");
    }

    #[test]
    fn a_second_start_while_running_is_refused() {
        let run = RunLock::new();
        let release = Arc::new(AtomicBool::new(false));
        let gate = Arc::clone(&release);
        run.start("test-run", move |_cancel, running| {
            let _guard = FinishGuard::new(running, |_: Option<()>| {});
            while !gate.load(Ordering::Acquire) {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        })
        .expect("first start");

        assert_eq!(
            run.start("test-run", |_, _| {}).unwrap_err(),
            StartError::AlreadyRunning
        );
        release.store(true, Ordering::Release);
        run.shutdown();
        assert!(!run.is_running());
        // And the lock is genuinely free again, not merely reported as free.
        run.start("test-run", |_cancel, running| {
            let _guard = FinishGuard::new(running, |_: Option<()>| {});
        })
        .expect("the lock did not come back");
        run.shutdown();
    }
}
