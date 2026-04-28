import Foundation

/// Injectable clock seam. Production code that reads "now" for memory-day or
/// birthday-today comparisons goes through this so tests can inject a fixed
/// instant. UI fields that just want the current wall clock (e.g. the
/// `lastSyncedAt` label) keep using `Date()` directly.
protocol Clock: Sendable {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

#if DEBUG
struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}
#endif
