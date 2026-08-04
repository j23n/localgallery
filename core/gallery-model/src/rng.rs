//! `Shared/SeededRNG.swift`, ported — and with it the one piece of the Swift
//! *standard library* the memory engine's output depends on.
//!
//! The daily jitter that orders the memories rail is `Double.random(in: 0..<12,
//! using: &rng)`. Reproducing the generator is not enough: the conversion from
//! the generator's `UInt64` to a `Double` is stdlib code, and getting it wrong
//! by one bit reorders two candidates whose ladder scores are equal. The exact
//! formula is pinned by `core/fixtures/memories-conformance/seeded_rng.json`
//! (`algorithm.jitterFormula`) and reproduced in [`SeededRng::next_double`].
//!
//! Seeding walks the seed's **UTF-8 bytes**, so canonically-equivalent
//! spellings (NFC vs NFD) of the same name produce different streams — the same
//! landmine `stable_uuid` carries, and for the same reason. Do not normalise
//! the seed.

/// SplitMix64 seeded by FNV-1a over the seed's UTF-8 bytes.
#[derive(Debug, Clone)]
pub struct SeededRng {
    state: u64,
}

/// FNV-1a 64-bit offset basis.
const FNV_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
/// FNV-1a 64-bit prime.
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
/// SplitMix64's golden-ratio increment.
const GAMMA: u64 = 0x9E37_79B9_7F4A_7C15;
/// The state a zero hash falls back to — a zero state is a fixed point of
/// nothing in SplitMix64, but Swift guards it anyway and so must this.
const ZERO_STATE_FALLBACK: u64 = 0xdead_beef;

impl SeededRng {
    /// Hash `seed`'s UTF-8 bytes with FNV-1a into the generator state.
    pub fn new(seed: &str) -> Self {
        let mut s = FNV_OFFSET_BASIS;
        for b in seed.as_bytes() {
            s = (s ^ u64::from(*b)).wrapping_mul(FNV_PRIME);
        }
        SeededRng {
            state: if s == 0 { ZERO_STATE_FALLBACK } else { s },
        }
    }

    /// The state right after seeding. Pinned per seed in `seeded_rng.json`.
    pub fn state(&self) -> u64 {
        self.state
    }

    /// One SplitMix64 draw — `RandomNumberGenerator.next()`.
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(GAMMA);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Swift's `Double.random(in: 0..<width, using: &self)`.
    ///
    /// One `next()` call, its **low** 53 bits (not the high ones), scaled by
    /// `2^-53`, then multiplied by the range width. The multiplication order is
    /// load-bearing: `width * (rand * 2^-53)` and `(width * rand) * 2^-53`
    /// differ in the last bit, and one ULP of jitter is enough to swap two
    /// candidates whose ladder scores tie.
    pub fn next_double(&mut self, width: f64) -> f64 {
        let rand = self.next_u64() & ((1u64 << 53) - 1);
        width * (rand as f64 * f64::from_bits(0x3CA0_0000_0000_0000))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_seed_hashes_to_the_bare_offset_basis() {
        assert_eq!(SeededRng::new("").state(), FNV_OFFSET_BASIS);
    }

    #[test]
    fn nfc_and_nfd_spellings_do_not_collide() {
        // `==` in Swift, different byte strings here — the seed is hashed as
        // bytes and a port that normalises diverges from the app.
        let nfc = SeededRng::new("caf\u{00E9}").state();
        let nfd = SeededRng::new("cafe\u{0301}").state();
        assert_ne!(nfc, nfd);
    }

    #[test]
    fn the_scale_constant_is_two_to_the_minus_53() {
        assert_eq!(f64::from_bits(0x3CA0_0000_0000_0000), 2f64.powi(-53));
    }

    #[test]
    fn draws_stay_inside_the_half_open_range() {
        let mut rng = SeededRng::new("2024-06-11");
        for _ in 0..1000 {
            let d = rng.next_double(12.0);
            assert!((0.0..12.0).contains(&d));
        }
    }
}
