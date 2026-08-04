import XCTest
@testable import LocalGallery

// MARK: - Fixture shape

struct ConfRNGAlgorithm: Codable, Equatable {
    let hash: String
    let offsetBasis: String
    let prime: String
    let zeroStateFallback: String
    let generator: String
    let gamma: String
    let jitterFormula: String
}

struct ConfRNGSeed: Codable, Equatable {
    let seed: String
    /// The bytes the FNV-1a hash actually consumes. Recorded because two
    /// canonically-equivalent Swift strings (NFC vs NFD) hash *differently* —
    /// `SeededRNG` iterates `seed.utf8`, not grapheme clusters.
    let seedUTF8: [Int]
    let initialState: String
    /// First raw `next()` outputs, decimal — JSON numbers cannot carry a
    /// `UInt64` losslessly (doubles run out at 2^53).
    let next: [String]
    /// First `Double.random(in: 0..<12, using:)` draws off a *fresh* RNG —
    /// the engine's daily jitter.
    let jitter0to12: [Double]
    /// The same draws as raw IEEE-754 bit patterns, decimal.
    ///
    /// Not belt-and-braces: `serde_json` 1.0.151 parses at least one of the
    /// decimal spellings above **one ULP low** (`1.9994953124891874` →
    /// `…872`). A jitter that is one ULP off can reorder two candidates whose
    /// scores are otherwise tied, so the Rust side compares these, not the
    /// decimals.
    let jitter0to12Bits: [String]
    /// First `Double.random(in: 0..<1, using:)` draws off a *fresh* RNG.
    let unit0to1: [Double]
    let unit0to1Bits: [String]
}

/// `WidgetDayKey.string(for:)` — the seed string `MemoryCoordinator` hands the
/// engine on a normal (non-force-regenerate) run.
struct ConfDaySeed: Codable, Equatable {
    let instantUTC: String
    let timeZone: String
    let seed: String
}

struct ConfRNGDump: Codable, Equatable {
    let schema: Int
    let algorithm: ConfRNGAlgorithm
    let notes: [String]
    let seeds: [ConfRNGSeed]
    let daySeeds: [ConfDaySeed]
    /// `MemoryCoordinator.forceRegenerate` seeds with
    /// `"\(clock.now().timeIntervalSinceReferenceDate)"` — a Swift `Double`
    /// interpolation, whose spelling is part of the seed.
    let forceRegenerateSeeds: [ConfDaySeed]
}

// MARK: - Harness

/// `SeededRNG` is the first thing the Phase-4 port has to implement: every
/// memory the engine selects depends on the daily jitter, and the jitter is
/// this generator plus Swift's `BinaryFloatingPoint.random(in:using:)`.
///
/// This suite pins three separate things, and the port needs all three:
///   1. FNV-1a over the seed's UTF-8 bytes → the initial SplitMix64 state.
///   2. SplitMix64's `next()` sequence.
///   3. The **stdlib** conversion from a `UInt64` to a `Double` in a range.
///      That last one is not in `SeededRNG.swift` at all — it lives in the
///      Swift standard library, and reimplementing it wrong is the easiest
///      way to get every memory id right and every memory *order* wrong.
final class SeededRNGConformanceTests: XCTestCase {

    private static let fixtureName = "seeded_rng.json"
    private static let drawCount = 8

    /// Seeds worth pinning. Each is a real shape the app produces, plus the
    /// two edge cases (`""`, and canonically-equivalent Unicode).
    private static let seeds: [String] = [
        "",                                  // MemoryEngine.generate's default
        "2024-06-11",                        // WidgetDayKey, the normal case
        "2024-06-12",                        // the adjacent day: no correlation
        "2025-01-01",
        "760000000.0",                       // forceRegenerate's time-based seed
        "caf\u{00E9}",                       // NFC  — 5 UTF-8 bytes
        "cafe\u{0301}",                      // NFD  — 6 UTF-8 bytes, `==` the above in Swift
        "🌵",                                 // 4-byte scalar
    ]

    private func vector(for seed: String) -> ConfRNGSeed {
        var raw = SeededRNG(seed: seed)
        let next = (0..<Self.drawCount).map { _ in String(raw.next()) }

        var jitterRNG = SeededRNG(seed: seed)
        let jitter = (0..<Self.drawCount).map { _ in Double.random(in: 0..<12, using: &jitterRNG) }

        var unitRNG = SeededRNG(seed: seed)
        let unit = (0..<Self.drawCount).map { _ in Double.random(in: 0..<1, using: &unitRNG) }

        // The initial state is `next()`'s input, not its output; recover it by
        // reproducing the documented FNV-1a over the seed's UTF-8 bytes. The
        // test below proves this reproduction drives the same sequence.
        var state: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in seed.utf8 { state = (state ^ UInt64(b)) &* 0x100_0000_01b3 }
        if state == 0 { state = 0xdeadbeef }

        return ConfRNGSeed(
            seed: seed,
            seedUTF8: seed.utf8.map(Int.init),
            initialState: String(state),
            next: next,
            jitter0to12: jitter,
            jitter0to12Bits: jitter.map { String($0.bitPattern) },
            unit0to1: unit,
            unit0to1Bits: unit.map { String($0.bitPattern) }
        )
    }

    private func dump() -> ConfRNGDump {
        let instant = MemoriesConformance.utc(2024, 6, 11, 15, 30)
        let daySeeds = ["UTC", "Asia/Tokyo", "America/Los_Angeles"].map { tz in
            MemoriesConformance.withTimeZoneSync(tz) {
                ConfDaySeed(
                    instantUTC: MemoriesConformance.iso(instant),
                    timeZone: tz,
                    seed: WidgetDayKey.string(for: instant)
                )
            }
        }
        // forceRegenerate: `"\(now.timeIntervalSinceReferenceDate)"`.
        let forceSeeds = [
            MemoriesConformance.utc(2024, 6, 11, 15, 30),
            Date(timeIntervalSinceReferenceDate: 760_000_000),
        ].map { d in
            ConfDaySeed(
                instantUTC: MemoriesConformance.iso(d),
                timeZone: "n/a — the seed is an absolute interval",
                seed: "\(d.timeIntervalSinceReferenceDate)"
            )
        }

        return ConfRNGDump(
            schema: 1,
            algorithm: ConfRNGAlgorithm(
                hash: "FNV-1a, 64-bit, over the seed's UTF-8 bytes",
                offsetBasis: "0xcbf29ce484222325",
                prime: "0x100000001b3",
                zeroStateFallback: "0xdeadbeef",
                generator: "SplitMix64: state &+= gamma; z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31)",
                gamma: "0x9E3779B97F4A7C15",
                jitterFormula: "Double.random(in: 0..<12, using:) == 12.0 * (Double(next() & 0x1F_FFFF_FFFF_FFFF) * 0x1p-53) — ONE next() call, its LOW 53 bits (not the high ones), scaled by 2^-53, then multiplied by the range width. The multiplication order matters: 12.0 * (rand * 2^-53), not (12.0 * rand) * 2^-53. Discovered by experiment and asserted, not assumed: see testTheStdlibDoubleConversionIsTheDocumentedFormula."
            ),
            notes: [
                "Seeded first, ported first: every other Phase-4 fixture depends on this one.",
                "`next` and the two draw lists each start from a FRESH SeededRNG(seed:) — they are three independent runs of the same seed, not one interleaved stream.",
                "`Double.random(in:using:)` and `next()` are different contracts: the first is Swift stdlib code that could in principle change between Swift releases, the second is this repo's SplitMix64. Both are pinned because the engine's output depends on both.",
                "Collection.shuffle / Int.random(in:) are deliberately NOT pinned here: nothing in MemoryEngine uses them (only `Shared/WidgetRotation.pickRotation` does, and widgets stay Swift), and Swift's integer-range algorithm is a stdlib implementation detail that would make this fixture fail on a toolchain bump for no benefit to the port.",
                "NFC and NFD spellings of the same name are `==` in Swift but hash to DIFFERENT states here, because the hash walks `seed.utf8`. Same landmine as stable_uuid_vectors.json — a port that normalizes its input diverges.",
                "Every draw is recorded TWICE: as a decimal and as its IEEE-754 bit pattern. serde_json (1.0.151) parses some 17-significant-digit decimals one ULP low, so the bit patterns are the authority and the decimals are for reading. Swift's own JSONDecoder round-trips the decimals exactly, which is why the Swift harness compares those.",
            ],
            seeds: Self.seeds.map(vector(for:)),
            daySeeds: daySeeds,
            forceRegenerateSeeds: forceSeeds
        )
    }

    // MARK: Tests

    func testSeededRNGVectorsMatchTheCommittedFixture() throws {
        try ConformanceFixtures.assertMatches(
            dump(), fixture: Self.fixtureName, in: MemoriesConformance.directory
        )
    }

    func testCommittedFixtureIsCanonical() throws {
        try ConformanceFixtures.assertCommittedBytesAreCanonical(
            ConfRNGDump.self, fixture: Self.fixtureName, in: MemoriesConformance.directory
        )
    }

    /// The port must reproduce Swift's `Double` conversion, not just
    /// SplitMix64. Proving the formula here means the Rust side can implement
    /// it from the fixture's `algorithm.jitterFormula` instead of guessing.
    func testTheStdlibDoubleConversionIsTheDocumentedFormula() {
        for seed in Self.seeds {
            var a = SeededRNG(seed: seed)
            var b = SeededRNG(seed: seed)
            for i in 0..<64 {
                let observed = Double.random(in: 0..<12, using: &a)
                let derived = 12.0 * (Double(b.next() & 0x1F_FFFF_FFFF_FFFF) * 0x1p-53)
                XCTAssertEqual(observed, derived, "seed '\(seed)' draw \(i)")
                XCTAssertTrue((0..<12).contains(observed))
            }
        }
    }

    /// FNV-1a's zero-state guard: the recorded `initialState` must actually be
    /// the state `next()` consumes, or the fixture's most useful field is a
    /// decoration.
    func testRecordedInitialStateDrivesTheRecordedSequence() {
        for vector in dump().seeds {
            guard var state = UInt64(vector.initialState) else {
                return XCTFail("initialState is not a UInt64: \(vector.initialState)")
            }
            let expected: [String] = (0..<Self.drawCount).map { _ in
                state = state &+ 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return String(z ^ (z >> 31))
            }
            XCTAssertEqual(expected, vector.next, "seed '\(vector.seed)'")
        }
    }

    /// Canonically-equivalent strings are `==` in Swift and produce different
    /// random streams. Pinned because it decides whether a person named "José"
    /// gets the same daily rotation on two devices.
    func testCanonicallyEquivalentSeedsDiverge() {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertEqual(nfc, nfd, "Swift string equality is canonical equivalence")
        var a = SeededRNG(seed: nfc)
        var b = SeededRNG(seed: nfd)
        XCTAssertNotEqual(a.next(), b.next(), "…but the RNG walks UTF-8 bytes")
    }
}
