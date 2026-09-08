//! Watch mute + debounce. The OS watcher stays on the host.

use std::time::Duration;

/// Tight enough that a Syncthing delete appears while Collections is on
/// screen; wide enough that a burst is one rescan.
pub const REFRESH_INTERVAL: Duration = Duration::from_millis(1500);

/// Whether a disk event should start the coalescer.
pub fn should_note(watching: bool, muted: bool) -> bool {
    watching && !muted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mute_drops_events() {
        assert!(should_note(true, false));
        assert!(!should_note(true, true));
        assert!(!should_note(false, false));
    }
}
