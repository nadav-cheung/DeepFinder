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
        let mut got = candidates(&r, &folded, None).unwrap();
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
    assert_eq!(candidates(&r, &folded, Some(5)).unwrap().len(), 5);
    assert_eq!(candidates(&r, &folded, Some(0)).unwrap().len(), 0);
}
