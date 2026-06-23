// SPDX-License-Identifier: MIT
//! Single-shard content query: candidates() over a ShardReader must match a
//! brute-force ASCII-folded substring scan of every file.

use df_content::fold::fold;
use df_content::{ShardBuilder, ShardReader};
use df_core::candidate::candidates;

fn brute_force(paths: &[(String, &[u8])], needle: &[u8]) -> Vec<u32> {
    paths
        .iter()
        .enumerate()
        .filter_map(|(i, (_, c))| {
            let f = fold(c);
            memchr::memmem::find(&f, needle)
                .is_some()
                .then_some(i as u32)
        })
        .collect()
}

#[test]
fn content_query_matches_grep() {
    let files: Vec<(String, Vec<u8>)> = vec![
        ("/a/main.rs".into(), b"fn main() { return 0; }".to_vec()),
        (
            "/a/lib.rs".into(),
            b"pub fn lib(x: u32) -> u32 { x }".to_vec(),
        ),
        ("/b/notes.md".into(), b"# Notes\nmain idea here\n".to_vec()),
        ("/b/data.csv".into(), b"name,value\nmain,42\n".to_vec()),
        ("/c/empty.txt".into(), b"".to_vec()),
    ];

    let mut b = ShardBuilder::new(0, 0);
    for (p, c) in &files {
        b.add_file(p, false, c.len() as i64, 1, c);
    }
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();

    let refs: Vec<(String, &[u8])> = files
        .iter()
        .map(|(p, c)| (p.clone(), c.as_slice()))
        .collect();

    for q in ["main", "fn ", "u32", "Notes", "zzz", "MA"] {
        let folded = fold(q.as_bytes());
        let mut got = candidates(&r, &folded, q.as_bytes(), false, None).unwrap();
        got.sort();
        let want = brute_force(&refs, &folded);
        assert_eq!(got, want, "query {q:?} mismatch (folded {:?})", folded);
    }
}

#[test]
fn content_query_respects_limit() {
    let mut b = ShardBuilder::new(0, 0);
    for _ in 0..20u32 {
        b.add_file("/x/f.txt", false, 3, 1, b"abc");
    }
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();
    let folded = fold(b"abc");
    assert_eq!(
        candidates(&r, &folded, b"abc", false, Some(5))
            .unwrap()
            .len(),
        5
    );
    assert_eq!(
        candidates(&r, &folded, b"abc", false, Some(0))
            .unwrap()
            .len(),
        0
    );
}

/// Verify must filter trigram false-positives: a trigram present in a file where
/// the full substring does not occur must NOT be returned.
#[test]
fn content_query_filters_trigram_false_positives() {
    let mut b = ShardBuilder::new(0, 0);
    b.add_file("/a/foobar.txt", false, 6, 1, b"foobar");
    b.add_file("/a/foobaz.txt", false, 6, 1, b"foobaz");
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();

    // "foobaz" shares trigrams with both files; only the foobaz file verifies.
    let folded = fold(b"foobaz");
    let got: Vec<u32> = {
        let mut v = candidates(&r, &folded, b"foobaz", false, None).unwrap();
        v.sort();
        v
    };
    assert_eq!(got, vec![1]); // only /a/foobaz.txt (docid 1)

    // "oob" is a trigram in both; as a query it must match both.
    let folded = fold(b"oob");
    let got: Vec<u32> = {
        let mut v = candidates(&r, &folded, b"oob", false, None).unwrap();
        v.sort();
        v
    };
    assert_eq!(got, vec![0, 1]);
}

/// Byte-trigram index handles multi-byte/CJK content natively (no tokenizer).
#[test]
fn content_query_cjk() {
    let mut b = ShardBuilder::new(0, 0);
    b.add_file("/a/jp.txt", false, 13, 1, "日本語の検索".as_bytes());
    b.add_file("/a/en.txt", false, 5, 1, b"hello");
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();

    // "日本" is 6 UTF-8 bytes (2 trigrams) present only in jp.txt.
    let folded = fold("日本".as_bytes());
    let got: Vec<u32> = {
        let mut v = candidates(&r, &folded, "日本".as_bytes(), false, None).unwrap();
        v.sort();
        v
    };
    assert_eq!(got, vec![0]);
}

/// `case_sensitive = true` verifies exact-case content; `false` stays folded.
#[test]
fn content_query_case_sensitive() {
    let mut b = ShardBuilder::new(0, 0);
    b.add_file("/a/one.rs", false, 13, 1, b"fn FooBar() {}");
    b.add_file("/a/two.rs", false, 13, 1, b"fn foobar() {}");
    b.add_file("/a/three.rs", false, 13, 1, b"fn FOOBAZ() {}");
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();

    let folded = fold(b"FooBar");
    // Exact-case "FooBar" → only the doc with that exact content (docid 0).
    let cs = {
        let mut v = candidates(&r, &folded, b"FooBar", true, None).unwrap();
        v.sort();
        v
    };
    assert_eq!(cs, vec![0]);
    // Folded "foobar" matches FooBar + foobar, but not FOOBAZ.
    let ci = {
        let mut v = candidates(&r, &folded, b"FooBar", false, None).unwrap();
        v.sort();
        v
    };
    assert_eq!(ci, vec![0, 1]);
}

/// metaData accessors + version validation.
#[test]
fn shard_metadata_accessors() {
    let mut b = ShardBuilder::new(7, 1234);
    b.add_file("/x", false, 1, 99, b"a");
    let bytes = b.finish(555);
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.shard_id(), 7);
    assert_eq!(r.base_docid(), 1234);
    assert_eq!(r.build_time(), 555);
    assert_eq!(r.num_docs(), 1);
}
