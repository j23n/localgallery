import Foundation

/// SplitMix64-derived RNG seeded by FNV-1a over the seed's UTF-8 bytes.
/// Deterministic across processes — widget extensions, app previews, and
/// timeline rebuilds all see the same sequence for the same seed.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: String) {
        var s: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { s = (s ^ UInt64(b)) &* 0x100000001b3 }
        self.state = s == 0 ? 0xdeadbeef : s
    }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
