// SPDX-License-Identifier: MIT
//! Boolean query tests: AND / OR / NOT / parentheses / implicit AND.

use df_core::db::{DbBuilder, DbReader};
use df_core::query::query;

fn build(paths: &[&str]) -> Vec<u8> {
    let mut b = DbBuilder::new();
    for p in paths {
        b.insert(p);
    }
    b.finish()
}

fn paths() -> Vec<&'static str> {
    vec![
        "/proj/src/main.rs",
        "/proj/src/main_test.rs",
        "/proj/docs/readme.md",
        "/proj/build/out.bin",
        "/other/main.go",
    ]
}

#[test]
fn and_operator() {
    let bytes = build(&paths());
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let m = query(&r, "main AND test", None).unwrap();
    assert_eq!(m, vec!["/proj/src/main_test.rs".to_string()]);
}

#[test]
fn implicit_and() {
    let bytes = build(&paths());
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let m = query(&r, "main test", None).unwrap();
    assert_eq!(m, vec!["/proj/src/main_test.rs".to_string()]);
}

#[test]
fn or_operator() {
    let bytes = build(&paths());
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let mut m = query(&r, "readme OR go", None).unwrap();
    m.sort();
    assert_eq!(
        m,
        vec![
            "/other/main.go".to_string(),
            "/proj/docs/readme.md".to_string()
        ]
    );
}

#[test]
fn not_operator() {
    let bytes = build(&paths());
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let m = query(&r, "main NOT test", None).unwrap();
    assert!(m.iter().any(|p| p == "/proj/src/main.rs"));
    assert!(m.iter().any(|p| p == "/other/main.go"));
    assert!(!m.iter().any(|p| p.contains("main_test")));
}

#[test]
fn parens_precedence() {
    let bytes = build(&paths());
    let r = DbReader::open(bytes.as_slice()).unwrap();
    // (readme OR go) AND NOT main → only readme.md (go's path also has "main").
    let m = query(&r, "(readme OR go) AND NOT main", None).unwrap();
    assert_eq!(m, vec!["/proj/docs/readme.md".to_string()]);
}

#[test]
fn lone_term_unchanged() {
    let bytes = build(&paths());
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let m = query(&r, "readme", None).unwrap();
    assert_eq!(m, vec!["/proj/docs/readme.md".to_string()]);
}
