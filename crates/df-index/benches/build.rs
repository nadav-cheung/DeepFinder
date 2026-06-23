// SPDX-License-Identifier: MIT
//! Build-throughput benchmark: time `build_content_index` over a temp corpus of
// N small text files (walk → text-gate → dual builders → shard flush). Run:
// cargo bench -p df-index --bench build

use std::path::Path;

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use df_index::{build_content_index, ContentBuildOptions};

fn make_corpus(dir: &Path, n: usize) {
    for i in 0..n {
        let p = dir.join(format!("file_{i:05}.txt"));
        std::fs::write(&p, b"the quick brown fox jumps over the lazy dog\n").unwrap();
    }
}

fn bench_build(c: &mut Criterion) {
    let mut g = c.benchmark_group("build");
    for n in [1_000usize, 5_000] {
        g.bench_with_input(BenchmarkId::from_parameter(n), &n, |b, &n| {
            b.iter_with_setup(
                || {
                    let tmp = tempfile::tempdir().expect("tempdir");
                    make_corpus(tmp.path(), n);
                    tmp
                },
                |tmp| {
                    let db = tmp.path().join("index.dfdb");
                    let content = tmp.path().join("content");
                    let r = build_content_index(
                        tmp.path(),
                        &db,
                        &content,
                        &ContentBuildOptions::default(),
                    )
                    .expect("build");
                    black_box(r);
                },
            );
        });
    }
    g.finish();
}

criterion_group!(g, bench_build);
criterion_main!(g);
