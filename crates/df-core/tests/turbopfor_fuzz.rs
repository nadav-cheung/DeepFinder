// SPDX-License-Identifier: MIT
//! Adversarial round-trip fuzz for the TurboPFor codec
//! (`df_core::turbopfor::encode` / `decode`).
//!
//! Uses a deterministic xorshift RNG (no `rand` crate) to drive ~5000 trials
//! across the block-boundary sizes {0,1,2,3,127,128,129,255,256,257,1000} and
//! a spread of value distributions chosen to stress bit-width selection,
//! exception packing, and multi-block decode.

use df_core::turbopfor::{decode, encode};

/// Deterministic xorshift32 RNG — no external rand dependency.
struct XorShift32 {
    state: u32,
}

impl XorShift32 {
    fn new(seed: u32) -> Self {
        // A zero state would lock the generator at zero; bias it.
        Self {
            state: if seed == 0 { 0xDEAD_BEEF } else { seed },
        }
    }

    fn next_u32(&mut self) -> u32 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        x
    }

    /// Uniform in [0, bound). bound must be > 0.
    fn below(&mut self, bound: u32) -> u32 {
        self.next_u32() % bound
    }
}

/// Distributions the fuzz exercises. Each shapes a single delta array.
#[derive(Clone, Copy)]
enum Dist {
    AllZero,
    AllIdentical0xDead,
    Uniform0To16,
    Uniform0To1Mib, // 0..(1 << 20)
    Uniform0ToU32Max,
    SparseSpikes,
    StrictlyIncreasing,
    IdenticalBlocks,
}

impl Dist {
    fn name(self) -> &'static str {
        match self {
            Dist::AllZero => "all-zero",
            Dist::AllIdentical0xDead => "all-identical-0xdead",
            Dist::Uniform0To16 => "uniform-0..16",
            Dist::Uniform0To1Mib => "uniform-0..(1<<20)",
            Dist::Uniform0ToU32Max => "uniform-0..u32::MAX",
            Dist::SparseSpikes => "sparse-spikes",
            Dist::StrictlyIncreasing => "strictly-increasing",
            Dist::IdenticalBlocks => "identical-blocks",
        }
    }
}

fn gen_array(rng: &mut XorShift32, n: usize, dist: Dist) -> Vec<u32> {
    match dist {
        Dist::AllZero => vec![0u32; n],
        Dist::AllIdentical0xDead => vec![0xdeadu32; n],
        Dist::Uniform0To16 => {
            let mut v = Vec::with_capacity(n);
            for _ in 0..n {
                v.push(rng.below(16));
            }
            v
        }
        Dist::Uniform0To1Mib => {
            let mut v = Vec::with_capacity(n);
            for _ in 0..n {
                v.push(rng.below(1 << 20));
            }
            v
        }
        Dist::Uniform0ToU32Max => {
            let mut v = Vec::with_capacity(n);
            for _ in 0..n {
                v.push(rng.next_u32());
            }
            v
        }
        Dist::SparseSpikes => {
            // Mostly small values (0..4) with a handful of huge spikes,
            // chosen to maximise exception count relative to bit-width.
            let mut v = Vec::with_capacity(n);
            for _ in 0..n {
                if rng.below(20) == 0 {
                    // Spike: full-width, random high-magnitude value.
                    v.push(rng.next_u32() | 0x8000_0000);
                } else {
                    v.push(rng.below(4));
                }
            }
            v
        }
        Dist::StrictlyIncreasing => {
            // Monotonically increasing deltas (every value strictly larger
            // than the previous) — exercises wide bit-widths at the tail.
            let mut v = Vec::with_capacity(n);
            let mut cur = 0u32;
            for _ in 0..n {
                let step = rng.below(7) + 1; // 1..=7
                cur = cur.wrapping_add(step);
                v.push(cur);
            }
            v
        }
        Dist::IdenticalBlocks => {
            // Build one "block" pattern (length min(n, 128)) then tile it so
            // that consecutive 128-value blocks are identical. This stresses
            // the assumption that each block is decoded independently.
            let mut v = Vec::with_capacity(n);
            if n == 0 {
                return v;
            }
            let blk_len = n.min(128);
            let mut block = Vec::with_capacity(blk_len);
            for _ in 0..blk_len {
                block.push(rng.next_u32());
            }
            for i in 0..n {
                v.push(block[i % blk_len]);
            }
            v
        }
    }
}

const SIZES: &[usize] = &[0, 1, 2, 3, 127, 128, 129, 255, 256, 257, 1000];
const DISTS: &[Dist] = &[
    Dist::AllZero,
    Dist::AllIdentical0xDead,
    Dist::Uniform0To16,
    Dist::Uniform0To1Mib,
    Dist::Uniform0ToU32Max,
    Dist::SparseSpikes,
    Dist::StrictlyIncreasing,
    Dist::IdenticalBlocks,
];

#[test]
fn turbopfor_roundtrip_fuzz() {
    // ~5000 trials total: spread 5000 across (sizes × dists) = 88 buckets,
    // rounded up so each bucket gets a healthy, distinct RNG seed.
    let total_target = 5000usize;
    let bucket_count = SIZES.len() * DISTS.len();
    let per_bucket = total_target.div_ceil(bucket_count); // ceil

    let mut trials = 0usize;
    let mut buckets_run = 0usize;

    for (si, &n) in SIZES.iter().enumerate() {
        for (di, &dist) in DISTS.iter().enumerate() {
            // Distinct seed per bucket so coverage differs across combos.
            let base_seed = 0xC0FFEE_u32
                .wrapping_add((si as u32).wrapping_mul(7919))
                .wrapping_add((di as u32).wrapping_mul(104729));
            for t in 0..per_bucket {
                let seed = base_seed.wrapping_add((t as u32).wrapping_mul(2654435761));
                let mut rng = XorShift32::new(seed);
                let deltas = gen_array(&mut rng, n, dist);

                let enc = encode(&deltas);
                let dec = decode(&enc, deltas.len());

                assert_eq!(
                    dec,
                    deltas,
                    "ROUND-TRIP MISMATCH\nsize={}, dist={}, trial={} (seed={:#010x})\n\
                     encoded len={}\ninput ({}) = {:?}\ndecoded ({}) = {:?}",
                    n,
                    dist.name(),
                    t,
                    seed,
                    enc.len(),
                    deltas.len(),
                    &deltas[..deltas.len().min(64)],
                    dec.len(),
                    &dec[..dec.len().min(64)],
                );
                trials += 1;
            }
            buckets_run += 1;
        }
    }

    eprintln!(
        "turbopfor_fuzz: {} trials across {} (size×dist) buckets ({} sizes × {} dists)",
        trials,
        buckets_run,
        SIZES.len(),
        DISTS.len(),
    );
}
