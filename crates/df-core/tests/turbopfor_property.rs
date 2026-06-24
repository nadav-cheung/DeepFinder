// SPDX-License-Identifier: MIT
//! Property verifier for the TurboPFor codec.
//!
//! Real-world use: sorted-unique u32 DocID lists -> delta -> encode ->
//! decode(count) -> prefix-sum == original list.
//!
//! Run: `cargo test -p df-core --test turbopfor_property`

use df_core::turbopfor;

/// xorshift32 RNG — no `rand` crate dependency.
struct Xorshift32 {
    state: u32,
}

impl Xorshift32 {
    fn new(seed: u32) -> Self {
        // xorshift32 requires a non-zero state.
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
}

#[test]
fn sorted_unique_roundtrip() {
    const TRIALS: usize = 1000;
    let mut rng = Xorshift32::new(0xC0FFEE);

    let mut failures: Vec<(usize, Vec<u32>)> = Vec::new();

    for trial in 0..TRIALS {
        // Length in 0..500 (i.e. 0..=499).
        let len = (rng.next_u32() as usize) % 500;

        // Generate a sorted-unique u32 list with values across 0..=u32::MAX.
        // Rejection-sample sorted-unique values from the full u32 range.
        let mut ids: Vec<u32> = Vec::with_capacity(len);
        // Cap attempts to avoid pathological spin loops when len is large.
        let max_attempts = len.saturating_mul(32).max(1024);
        let mut attempts = 0;
        while ids.len() < len && attempts < max_attempts {
            attempts += 1;
            let v = rng.next_u32();
            match ids.binary_search(&v) {
                Ok(_) => continue, // duplicate, reject
                Err(idx) => ids.insert(idx, v),
            }
        }
        // If we exhausted attempts before filling len, that subset is still
        // sorted-unique and is a valid test input.

        // Compute deltas (prev starts at 0, so the first delta == ids[0]).
        let mut deltas: Vec<u32> = Vec::with_capacity(ids.len());
        let mut prev: u32 = 0;
        for &d in &ids {
            deltas.push(d - prev);
            prev = d;
        }

        // Encode -> decode(count).
        let enc = turbopfor::encode(&deltas);
        let dec = turbopfor::decode(&enc, deltas.len());

        if dec != deltas {
            failures.push((trial, ids.clone()));
            continue;
        }

        // Prefix-sum back to original docids.
        let mut recovered: Vec<u32> = Vec::with_capacity(dec.len());
        let mut acc: u32 = 0;
        for d in dec {
            acc += d;
            recovered.push(acc);
        }

        if recovered != ids {
            failures.push((trial, ids.clone()));
        }
    }

    if !failures.is_empty() {
        let mut msg = format!("property failed: {}/{} trials\n", failures.len(), TRIALS);
        for (trial, ids) in failures.iter().take(10) {
            msg.push_str(&format!(
                "  trial {}: len={} first few = {:?}\n",
                trial,
                ids.len(),
                &ids[..ids.len().min(8)]
            ));
        }
        panic!("{}", msg);
    }
}
