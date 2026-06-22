// SPDX-License-Identifier: MIT
//! TurboPFor codec benchmark: encode/decode throughput on a realistic posting
//! list (many small deltas, a few large spikes → exception-heavy blocks).
//! Run with: cargo bench -p df-core

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use df_core::turbopfor;

fn realistic_deltas(n: usize) -> Vec<u32> {
    (0..n)
        .map(|i| {
            let base = (i % 7) as u32; // small common deltas
            if i % 137 == 0 {
                0xdead_beef // occasional huge delta (exception)
            } else {
                base
            }
        })
        .collect()
}

fn bench_turbopfor(c: &mut Criterion) {
    let deltas = realistic_deltas(10_000);
    let enc = turbopfor::encode(&deltas);

    c.bench_function("encode 10k deltas", |b| {
        b.iter(|| turbopfor::encode(black_box(&deltas)))
    });
    c.bench_function("decode 10k deltas", |b| {
        b.iter(|| turbopfor::decode(black_box(&enc), black_box(deltas.len())))
    });

    // Compression ratio reference.
    let raw_bytes = deltas.len() * 4;
    println!(
        "turbopfor: {} deltas, raw {} B, encoded {} B ({:.2}x)",
        deltas.len(),
        raw_bytes,
        enc.len(),
        raw_bytes as f64 / enc.len() as f64
    );
}

criterion_group!(g, bench_turbopfor);
criterion_main!(g);
