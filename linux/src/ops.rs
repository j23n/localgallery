//! Scan / analysis generations. Stale completions must not clear, publish, or
//! persist newer host state.
//!
//! The ledger is thread-safe so a worker can take the same generation that
//! started the run and commit snapshot / config / geocode writes under it.
//! UI-only gating is not enough: a superseded thread must not `write_atomic`
//! after a newer generation has begun.

use std::sync::{Arc, Mutex};

/// Which long-running host job a token names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpKind {
    /// Folder walk + enrichment.
    Scan,
    /// Tag / faces / places run.
    Analysis,
}

/// Generation of one begin/done pair. Never reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpToken {
    /// Scan vs analysis.
    pub kind: OpKind,
    /// Monotonic id from [`OpLedger::begin`].
    pub generation: u64,
}

#[derive(Debug, Default)]
struct OpInner {
    next: u64,
    current: Option<OpToken>,
}

/// One-slot ledger: a new begin retires the previous generation.
///
/// Cheap to clone — every clone shares the same generation slot and persist
/// lock, which is how a background scan and the GTK shell agree on who may
/// write the library snapshot.
#[derive(Debug, Clone)]
pub struct OpLedger {
    inner: Arc<Mutex<OpInner>>,
}

impl Default for OpLedger {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(OpInner::default())),
        }
    }
}

impl OpLedger {
    fn lock(&self) -> std::sync::MutexGuard<'_, OpInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Start a run. The previous token, if any, becomes stale.
    ///
    /// Takes the persist lock so a later [`Self::commit`] from the retired
    /// generation cannot start (or finish) a write after this returns.
    pub fn begin(&self, kind: OpKind) -> OpToken {
        let mut inner = self.lock();
        inner.next += 1;
        let token = OpToken {
            kind,
            generation: inner.next,
        };
        inner.current = Some(token);
        token
    }

    /// Token of the run that may still publish.
    pub fn current(&self) -> Option<OpToken> {
        self.lock().current
    }

    /// Whether `token` is the in-flight generation.
    pub fn is_current(&self, token: OpToken) -> bool {
        self.lock().current == Some(token)
    }

    /// Consume `token` if it is still current. Stale tokens leave the ledger
    /// (and therefore the UI flags) untouched.
    pub fn finish(&self, token: OpToken) -> bool {
        let mut inner = self.lock();
        if inner.current == Some(token) {
            inner.current = None;
            true
        } else {
            false
        }
    }

    /// Run `write` only while `token` is the live generation.
    ///
    /// The same lock [`Self::begin`] takes is held for the whole write, so a
    /// newer generation cannot start until this persist finishes or is
    /// rejected. That makes the final state write authoritative and avoids a
    /// check-then-write race on snapshot / config / geocode files.
    pub fn commit<T, E>(
        &self,
        token: OpToken,
        write: impl FnOnce() -> Result<T, E>,
    ) -> Result<Option<T>, E> {
        let inner = self.lock();
        if inner.current != Some(token) {
            return Ok(None);
        }
        write().map(Some)
    }
}

/// Banner / busy / mute flags the GTK shell mirrors. Kept here so the
/// stale-completion rule is testable without a display.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SurfaceFlags {
    /// Progress banner is showing.
    pub banner: bool,
    /// A cancel flag is live.
    pub busy: bool,
    /// Folder watch is muted.
    pub watch_muted: bool,
    /// Last generation that was allowed to publish library state.
    pub published_generation: Option<u64>,
}

impl SurfaceFlags {
    /// Nothing running.
    pub fn idle() -> Self {
        Self {
            banner: false,
            busy: false,
            watch_muted: false,
            published_generation: None,
        }
    }
}

/// Begin a run and raise the host flags that go with it.
pub fn apply_begin(ledger: &OpLedger, flags: &mut SurfaceFlags, kind: OpKind) -> OpToken {
    let token = ledger.begin(kind);
    flags.banner = true;
    flags.busy = true;
    flags.watch_muted = true;
    token
}

/// Apply a completion. A stale token must not clear flags or publish.
pub fn apply_done(ledger: &OpLedger, flags: &mut SurfaceFlags, token: OpToken, publish: bool) {
    if !ledger.finish(token) {
        return;
    }
    flags.banner = false;
    flags.busy = false;
    flags.watch_muted = false;
    if publish {
        flags.published_generation = Some(token.generation);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[test]
    fn stale_done_does_not_clear_or_publish_newer_state() {
        let ledger = OpLedger::default();
        let mut flags = SurfaceFlags::idle();
        let first = apply_begin(&ledger, &mut flags, OpKind::Scan);
        let second = apply_begin(&ledger, &mut flags, OpKind::Scan);
        assert_ne!(first.generation, second.generation);
        assert!(ledger.is_current(second));
        assert!(!ledger.is_current(first));

        apply_done(&ledger, &mut flags, first, true);
        assert!(flags.banner);
        assert!(flags.busy);
        assert!(flags.watch_muted);
        assert_eq!(flags.published_generation, None);
        assert_eq!(ledger.current(), Some(second));

        apply_done(&ledger, &mut flags, second, true);
        assert!(!flags.banner);
        assert!(!flags.busy);
        assert!(!flags.watch_muted);
        assert_eq!(flags.published_generation, Some(second.generation));
        assert!(ledger.current().is_none());
    }

    #[test]
    fn cancelled_current_run_clears_flags_without_publishing() {
        let ledger = OpLedger::default();
        let mut flags = SurfaceFlags::idle();
        let token = apply_begin(&ledger, &mut flags, OpKind::Analysis);
        apply_done(&ledger, &mut flags, token, false);
        assert!(!flags.busy);
        assert_eq!(flags.published_generation, None);
    }

    #[test]
    fn progress_is_live_only_for_the_current_generation() {
        let ledger = OpLedger::default();
        let a = ledger.begin(OpKind::Scan);
        let b = ledger.begin(OpKind::Analysis);
        assert!(!ledger.is_current(a));
        assert!(ledger.is_current(b));
    }

    #[test]
    fn stale_commit_does_not_run_the_write() {
        let ledger = OpLedger::default();
        let first = ledger.begin(OpKind::Scan);
        let _second = ledger.begin(OpKind::Scan);
        let writes = Arc::new(AtomicUsize::new(0));
        let wrote = ledger
            .commit(first, || {
                writes.fetch_add(1, Ordering::SeqCst);
                Ok::<(), ()>(())
            })
            .unwrap();
        assert!(wrote.is_none());
        assert_eq!(writes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn live_commit_runs_the_write() {
        let ledger = OpLedger::default();
        let token = ledger.begin(OpKind::Scan);
        let wrote = ledger.commit(token, || Ok::<u8, ()>(7)).unwrap();
        assert_eq!(wrote, Some(7));
    }

    #[test]
    fn begin_waits_for_an_in_flight_commit_then_retires_it() {
        use std::sync::mpsc;
        use std::thread;
        use std::time::Duration;

        let ledger = OpLedger::default();
        let first = ledger.begin(OpKind::Scan);
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker = {
            let ledger = ledger.clone();
            thread::spawn(move || {
                ledger.commit(first, || {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok::<(), ()>(())
                })
            })
        };
        entered_rx.recv().unwrap();
        let (begun_tx, begun_rx) = mpsc::channel();
        let starter = {
            let ledger = ledger.clone();
            thread::spawn(move || {
                let second = ledger.begin(OpKind::Analysis);
                begun_tx.send(second).unwrap();
                second
            })
        };
        // begin must not return while the first generation is still writing.
        assert!(begun_rx.recv_timeout(Duration::from_millis(50)).is_err());
        release_tx.send(()).unwrap();
        let second = starter.join().unwrap();
        assert!(worker.join().unwrap().unwrap().is_some());
        assert!(ledger.is_current(second));
        assert!(!ledger.is_current(first));
        assert!(ledger.commit(first, || Ok::<(), ()>(())).unwrap().is_none());
    }
}
