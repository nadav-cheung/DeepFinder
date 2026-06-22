// SPDX-License-Identifier: MIT
//! Query-latency benchmark: build a realistic corpus, then time representative
// queries (common trigram, rare substring, boolean) against an in-memory
// DbReader. Validates the v1 sub-millisecond target (REVIEW §8.4 / §7.9).
//
// Production adds a pread (page-cache hit) per posting/block; this measures the
// core engine path, which dominates. Run: cargo bench -p df-core --bench query

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use df_core::db::{DbBuilder, DbReader};
use df_core::query::query;

/// ~40k paths resembling a real tree: common dir/ext trigrams + unique names.
fn corpus(n: usize) -> Vec<String> {
    const DIRS: &[&str] = &[
        "src", "tests", "docs", "crates", "vendor", "scripts", "config",
    ];
    const EXTS: &[&str] = &["rs", "md", "toml", "js", "ts", "go"];
    (0..n)
        .map(|i| {
            let d = DIRS[i % DIRS.len()];
            let e = EXTS[i % EXTS.len()];
            format!("/{d}/module_{:05}/file_{:05}.{e}", i / 100, i)
        })
        .collect()
}

fn build_db(paths: &[String]) -> Vec<u8> {
    let mut b = DbBuilder::new();
    for p in paths {
        b.insert(p);
    }
    b.finish()
}

fn bench_query(c: &mut Criterion) {
    let paths = corpus(40_000);
    let bytes = build_db(&paths);
    let reader = DbReader::open(bytes.as_slice()).expect("open");
    eprintln!(
        "query bench: {} docs, DB {} B ({:.1} KB)",
        reader.num_docs(),
        bytes.len(),
        bytes.len() as f64 / 1024.0
    );

    let cases: &[(&str, &str)] = &[
        ("rare", "module_00123"),     // selective substring (typical query)
        ("common", "src"),            // ~1/7 of corpus
        ("boolean", "src AND tests"), // two mid-selectivity terms
        ("short", "go"),              // 2 bytes → linear-scan fallback
    ];

    let mut g = c.benchmark_group("query");
    for (label, q) in cases {
        g.bench_with_input(BenchmarkId::from_parameter(label), q, |b, q| {
            b.iter(|| {
                let _ = black_box(query(&reader, q, Some(1000)).expect("query"));
            });
        });
    }
    g.finish();
}

criterion_group!(g, bench_query);
criterion_main!(g);
