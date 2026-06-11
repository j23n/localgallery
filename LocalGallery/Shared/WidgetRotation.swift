import Foundation

// MARK: - Day key

/// Stable yyyy-MM-dd string for the start of the given day in the user's
/// calendar. Used as a seed component so widget rotation varies day to day
/// while staying deterministic within a given day.
enum WidgetDayKey {
    static func string(for date: Date = Date()) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

// MARK: - Rotation

/// Picks `slots` indices from `0..<count`, deterministically keyed by `seed`.
/// When `count >= slots` the result is a permutation prefix (no repeats).
/// When `count < slots` the pool is re-shuffled and concatenated; the loop
/// guards against the same index landing back-to-back at the join boundary.
func pickRotation(count: Int, slots: Int, seed: String) -> [Int] {
    guard count > 0, slots > 0 else { return [] }
    var rng = SeededRNG(seed: seed)
    let initial = Array(0..<count).shuffled(using: &rng)
    if initial.count >= slots { return Array(initial.prefix(slots)) }

    var out = initial
    while out.count < slots {
        var next = initial.shuffled(using: &rng)
        // Re-shuffle until the join doesn't repeat. Bounded — with count >= 2
        // a random shuffle has at most a 1/count chance of starting with a
        // given index, so this terminates in expected O(1).
        if count > 1 {
            var attempts = 0
            while next.first == out.last, attempts < 8 {
                next = initial.shuffled(using: &rng)
                attempts += 1
            }
            if next.first == out.last, next.count > 1 {
                next.swapAt(0, 1)
            }
        }
        out.append(contentsOf: next)
    }
    return Array(out.prefix(slots))
}
