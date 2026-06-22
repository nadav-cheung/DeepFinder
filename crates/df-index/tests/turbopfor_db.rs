// SPDX-License-Identifier: MIT
//! Integration test exercising the TurboPFor posting codec end-to-end at
//! scale: build an index over a large temp tree and over a directly-built DB,
//! then reopen and query, asserting correct matches and no spurious ones.

use std::collections::HashSet;
use std::fs;

use df_core::db::{DbBuilder, DbReader};
use df_core::query::query;
use df_index::{build_index, FileSource};

/// Build a temp tree of ~2000 files with varied names and return the set of
/// full absolute paths written.
///
/// Files live directly under the temp root (no skip-list dir names, none
/// hidden, no .gitignore) so `ignore`-based `build_index` indexes all of them.
fn make_big_tree(root: &std::path::Path) -> HashSet<String> {
    let mut all = HashSet::new();
    for i in 0u32..2000 {
        // Three name "kinds" so we have rare and common substrings to query.
        let name = match i % 3 {
            0 => format!("alpha_{:04}.txt", i),
            1 => format!("beta_{:04}.log", i),
            _ => format!("gamma_{:04}.dat", i),
        };
        let path = root.join(&name);
        fs::write(&path, b"x").unwrap();
        all.insert(path.to_str().unwrap().to_string());
    }
    // A few uniquely-named needles so we can assert exact matches.
    let needle = root.join("unique_unicorn.md");
    fs::write(&needle, b"x").unwrap();
    all.insert(needle.to_str().unwrap().to_string());

    let needle2 = root.join("ZEBRA_SENTINEL.json");
    fs::write(&needle2, b"x").unwrap();
    all.insert(needle2.to_str().unwrap().to_string());

    all
}

#[test]
fn filesource_roundtrip_2000_files() {
    let tmp = tempfile::tempdir().unwrap();
    let written = make_big_tree(tmp.path());

    let db_path = tmp.path().join("index.dfdb");
    let n = build_index(tmp.path(), &db_path).unwrap();
    // 2000 generated files + 2 needles = 2002 files. `build_index` also indexes
    // directory entries walked by `ignore`, so the total is ≥ the file count.
    assert!(n >= 2002, "expected at least 2002 indexed entries, got {n}");

    // Atomic write: DB file present, no leftover .tmp.
    assert!(db_path.is_file());
    assert!(!tmp.path().join("index.dfdb.tmp").exists());

    // Reopen via pread FileSource (the daemon path).
    let src = FileSource::open(&db_path).unwrap();
    let reader = DbReader::open(src).unwrap();
    assert_eq!(reader.num_docs(), n);

    // --- Correct matches ---------------------------------------------------
    // Unique needles: exactly one match, the right path.
    let unicorn = query(&reader, "unique_unicorn", None).unwrap();
    assert_eq!(unicorn.len(), 1);
    assert!(unicorn[0].ends_with("unique_unicorn.md"));

    // Case-insensitive: lowercase query matches the uppercase path.
    let zebra = query(&reader, "zebra_sentinel", None).unwrap();
    assert_eq!(zebra.len(), 1);
    assert!(zebra[0].ends_with("ZEBRA_SENTINEL.json"));

    // Common substring "alpha" → exactly the alpha_{*}.txt files (every third
    // index from 0..2000 → 667 files: i in {0,3,...,1998}).
    let alpha = query(&reader, "alpha", None).unwrap();
    assert_eq!(alpha.len(), 667, "alpha substring count");
    assert!(alpha.iter().all(|p| p.contains("alpha_")));

    // "beta_" prefix family → 667 (i in {1,4,...,1999}).
    let beta = query(&reader, "beta_", None).unwrap();
    assert_eq!(beta.len(), 667);
    assert!(beta.iter().all(|p| p.contains("beta_")));

    // All matches are real indexed paths, not fabricated.
    for p in &alpha {
        assert!(written.contains(p), "spurious alpha match: {p}");
    }

    // A specific docid pattern: "alpha_0042" → exactly one file (i=42, 42%3==0).
    let a42 = query(&reader, "alpha_0042", None).unwrap();
    assert_eq!(a42.len(), 1);
    assert!(a42[0].ends_with("alpha_0042.txt"));

    // "alpha_00" is a substring of every alpha file whose formatted index is in
    // 0..100 (i in {0,3,...,99}, i%3==0) → 34 files. None of the beta/gamma
    // files contain it, so this confirms no spurious cross-family matches and
    // no missed alpha matches.
    let a00 = query(&reader, "alpha_00", None).unwrap();
    assert_eq!(a00.len(), 34, "alpha_00 substring count");
    assert!(a00.iter().all(|p| p.contains("alpha_00")));

    // Limit is honored.
    assert_eq!(query(&reader, "alpha", Some(5)).unwrap().len(), 5);

    // --- No spurious matches ------------------------------------------------
    // A trigram sequence that cannot appear in any indexed path.
    let none = query(&reader, "qqqxqqq", None).unwrap();
    assert!(
        none.is_empty(),
        "expected no matches for impossible trigram"
    );

    // A plausible-but-absent substring.
    let absent = query(&reader, "delta", None).unwrap();
    assert!(absent.is_empty(), "expected no matches for 'delta'");
}

#[test]
fn dbbuilder_direct_5000_paths_slice_reopen() {
    // Build directly via DbBuilder with 5000 varied paths, finish to bytes,
    // then reopen over an in-memory &[u8] slice (the test DbSource) and query.
    let mut builder = DbBuilder::new();
    let mut expected_alpha: Vec<String> = Vec::new();
    let mut expected_beta: Vec<String> = Vec::new();
    let mut all: Vec<String> = Vec::new();
    for i in 0u32..5000 {
        let p = match i % 4 {
            0 => {
                let s = format!("/srv/data/alpha_{:05}.bin", i);
                expected_alpha.push(s.clone());
                s
            }
            1 => {
                let s = format!("/srv/data/beta_{:05}.bin", i);
                expected_beta.push(s.clone());
                s
            }
            2 => format!("/srv/cache/gamma_{:05}.tmp", i),
            _ => format!("/srv/cache/delta_{:05}.tmp", i),
        };
        builder.insert(&p);
        all.push(p);
    }
    let count = builder.doc_count();
    assert_eq!(count, 5000);

    let bytes = builder.finish();
    // Reopen over the raw slice — no filesystem involved.
    let reader = DbReader::open(bytes.as_slice()).unwrap();
    assert_eq!(reader.num_docs(), 5000);

    // "alpha_" selects every 4th path (i % 4 == 0): 1250 of 5000.
    let alpha = query(&reader, "alpha_", None).unwrap();
    assert_eq!(alpha.len(), 1250, "alpha_ count");
    let want_alpha: HashSet<&String> = expected_alpha.iter().collect();
    let got_alpha: HashSet<&String> = alpha.iter().collect();
    assert_eq!(want_alpha, got_alpha, "alpha_ match set mismatch");

    // "beta_" → 1250, exact set.
    let beta = query(&reader, "beta_", None).unwrap();
    assert_eq!(beta.len(), 1250);
    let want_beta: HashSet<&String> = expected_beta.iter().collect();
    let got_beta: HashSet<&String> = beta.iter().collect();
    assert_eq!(want_beta, got_beta, "beta_ match set mismatch");

    // "gamma_" and "delta_" each 1250.
    assert_eq!(query(&reader, "gamma_", None).unwrap().len(), 1250);
    assert_eq!(query(&reader, "delta_", None).unwrap().len(), 1250);

    // A single specific file.
    let one = query(&reader, "alpha_01000", None).unwrap();
    assert_eq!(one, vec!["/srv/data/alpha_01000.bin".to_string()]);

    // Case-insensitivity through the slice path too.
    let upper = query(&reader, "ALPHA_01000", None).unwrap();
    assert_eq!(upper.len(), 1);
    assert!(upper[0].ends_with("alpha_01000.bin"));

    // No spurious matches: substring absent from the corpus.
    assert!(query(&reader, "omega_", None).unwrap().is_empty());
    // A trigram that exists nowhere in the index.
    assert!(query(&reader, "zzzzzz", None).unwrap().is_empty());

    // Limit honored.
    assert_eq!(query(&reader, "alpha_", Some(10)).unwrap().len(), 10);

    // Every returned match is a real inserted path.
    let universe: HashSet<&String> = all.iter().collect();
    for p in alpha.iter().chain(beta.iter()) {
        assert!(universe.contains(p), "spurious match not in corpus: {p}");
    }
}
