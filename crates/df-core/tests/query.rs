// SPDX-License-Identifier: MIT
//! Integration tests for the df-core slice: build → serialize → reopen → query.

use df_core::db::{DbBuilder, DbReader};
use df_core::query::query;

fn build(paths: &[&str]) -> Vec<u8> {
    let mut b = DbBuilder::new();
    for p in paths {
        b.insert(p);
    }
    b.finish()
}

#[test]
fn substring_among_100_paths() {
    let mut paths: Vec<String> = (0..100)
        .map(|i| format!("/users/x/docs/file_{:03}.txt", i))
        .collect();
    paths.push("/users/x/downloads/report.pdf".to_string());
    let refs: Vec<&str> = paths.iter().map(|s| s.as_str()).collect();

    let bytes = build(&refs);
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert_eq!(r.num_docs(), 101);

    // unambiguous matches
    assert_eq!(
        query(&r, "downloads", None).unwrap(),
        vec!["/users/x/downloads/report.pdf"]
    );
    assert_eq!(
        query(&r, "report", None).unwrap(),
        vec!["/users/x/downloads/report.pdf"]
    );
    assert_eq!(
        query(&r, "file_042", None).unwrap(),
        vec!["/users/x/docs/file_042.txt"]
    );

    // "file_04" is a substring of file_040..file_049 (10 files), not file_004.
    let m = query(&r, "file_04", None).unwrap();
    assert_eq!(m.len(), 10);
    assert!(m.iter().all(|p| p.starts_with("/users/x/docs/file_04")));

    // limit
    assert_eq!(query(&r, "file_04", Some(3)).unwrap().len(), 3);
}

#[test]
fn short_query_linear_scan() {
    let bytes = build(&["/a/ab", "/a/cd", "/a/aba"]);
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let mut m = query(&r, "ab", None).unwrap();
    m.sort();
    assert_eq!(m, vec!["/a/ab".to_string(), "/a/aba".to_string()]);
}

#[test]
fn case_insensitive() {
    let bytes = build(&["/Users/X/Downloads/Report.PDF"]);
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert_eq!(query(&r, "REPORT", None).unwrap().len(), 1);
    assert_eq!(query(&r, "pdf", None).unwrap().len(), 1);
}

#[test]
fn no_match() {
    let bytes = build(&["/a/b/c.txt"]);
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert!(query(&r, "zzz", None).unwrap().is_empty());
    // a trigram that can't exist → empty
    assert!(query(&r, "qqq", None).unwrap().is_empty());
}

#[test]
fn empty_query() {
    let bytes = build(&["/a/b"]);
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert!(query(&r, "", None).unwrap().is_empty());
}

#[test]
fn cjk_substring() {
    let bytes = build(&["/users/x/下载/安全浏览器.app", "/users/x/docs/notes.txt"]);
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let m = query(&r, "安全", None).unwrap();
    assert_eq!(m, vec!["/users/x/下载/安全浏览器.app".to_string()]);
    let m2 = query(&r, "下载", None).unwrap();
    assert_eq!(m2, vec!["/users/x/下载/安全浏览器.app".to_string()]);
}
