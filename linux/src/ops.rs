//! Scan / analysis generations. Stale completions must not clear or publish
//! newer host state.

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

/// One-slot ledger: a new begin retires the previous generation.
#[derive(Debug, Default)]
pub struct OpLedger {
    next: u64,
    current: Option<OpToken>,
}

impl OpLedger {
    /// Start a run. The previous token, if any, becomes stale.
    pub fn begin(&mut self, kind: OpKind) -> OpToken {
        self.next += 1;
        let token = OpToken {
            kind,
            generation: self.next,
        };
        self.current = Some(token);
        token
    }

    /// Token of the run that may still publish.
    pub fn current(&self) -> Option<OpToken> {
        self.current
    }

    /// Whether `token` is the in-flight generation.
    pub fn is_current(&self, token: OpToken) -> bool {
        self.current == Some(token)
    }

    /// Consume `token` if it is still current. Stale tokens leave the ledger
    /// (and therefore the UI flags) untouched.
    pub fn finish(&mut self, token: OpToken) -> bool {
        if self.current == Some(token) {
            self.current = None;
            true
        } else {
            false
        }
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
pub fn apply_begin(ledger: &mut OpLedger, flags: &mut SurfaceFlags, kind: OpKind) -> OpToken {
    let token = ledger.begin(kind);
    flags.banner = true;
    flags.busy = true;
    flags.watch_muted = true;
    token
}

/// Apply a completion. A stale token must not clear flags or publish.
pub fn apply_done(ledger: &mut OpLedger, flags: &mut SurfaceFlags, token: OpToken, publish: bool) {
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

    #[test]
    fn stale_done_does_not_clear_or_publish_newer_state() {
        let mut ledger = OpLedger::default();
        let mut flags = SurfaceFlags::idle();
        let first = apply_begin(&mut ledger, &mut flags, OpKind::Scan);
        let second = apply_begin(&mut ledger, &mut flags, OpKind::Scan);
        assert_ne!(first.generation, second.generation);
        assert!(ledger.is_current(second));
        assert!(!ledger.is_current(first));

        apply_done(&mut ledger, &mut flags, first, true);
        assert!(flags.banner);
        assert!(flags.busy);
        assert!(flags.watch_muted);
        assert_eq!(flags.published_generation, None);
        assert_eq!(ledger.current(), Some(second));

        apply_done(&mut ledger, &mut flags, second, true);
        assert!(!flags.banner);
        assert!(!flags.busy);
        assert!(!flags.watch_muted);
        assert_eq!(flags.published_generation, Some(second.generation));
        assert!(ledger.current().is_none());
    }

    #[test]
    fn cancelled_current_run_clears_flags_without_publishing() {
        let mut ledger = OpLedger::default();
        let mut flags = SurfaceFlags::idle();
        let token = apply_begin(&mut ledger, &mut flags, OpKind::Analysis);
        apply_done(&mut ledger, &mut flags, token, false);
        assert!(!flags.busy);
        assert_eq!(flags.published_generation, None);
    }

    #[test]
    fn progress_is_live_only_for_the_current_generation() {
        let mut ledger = OpLedger::default();
        let a = ledger.begin(OpKind::Scan);
        let b = ledger.begin(OpKind::Analysis);
        assert!(!ledger.is_current(a));
        assert!(ledger.is_current(b));
    }
}
