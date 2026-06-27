// SPDX-License-Identifier: MIT
//! Integration tests for df-index: walk a temp tree → build → reopen → query.

use std::fs;

use df_core::db::DbReader;
use df_core::query::query;
use df_index::{build_index, build_index_with, FileSource};

fn make_tree(root: &std::path::Path) {
    fs::create_dir_all(root.join("docs")).unwrap();
    fs::write(root.join("docs/notes.txt"), b"x").unwrap();
    fs::create_dir_all(root.join("downloads")).unwrap();
    fs::write(root.join("downloads/report.pdf"), b"x").unwrap();
    fs::write(root.join("readme.md"), b"x").unwrap();
}

#[test]
fn build_reopen_query() {
    let tmp = tempfile::tempdir().unwrap();
    make_tree(tmp.path());

    let db_path = tmp.path().join("index.dfdb");
    let n = build_index(tmp.path(), &db_path).unwrap();
    assert!(n >= 4, "expected at least 4 entries, got {n}");

    // DB file exists, no leftover .tmp.
    assert!(db_path.is_file());
    assert!(!tmp.path().join("index.dfdb.tmp").exists());

    // Reopen via pread FileSource and query.
    let src = FileSource::open(&db_path).unwrap();
    let reader = DbReader::open(src).unwrap();
    assert_eq!(reader.num_docs(), n);

    let report = query(&reader, "report", None).unwrap();
    assert!(report.iter().any(|p| p.ends_with("downloads/report.pdf")));

    let notes = query(&reader, "notes", None).unwrap();
    assert!(notes.iter().any(|p| p.ends_with("docs/notes.txt")));

    let readme = query(&reader, "readme", None).unwrap();
    assert!(readme.iter().any(|p| p.ends_with("readme.md")));
}

#[test]
fn skip_list_excludes_build_dirs() {
    let tmp = tempfile::tempdir().unwrap();
    // real file
    fs::write(tmp.path().join("real.txt"), b"x").unwrap();
    // skipped dir + file under it
    fs::create_dir_all(tmp.path().join("node_modules/pkg")).unwrap();
    fs::write(tmp.path().join("node_modules/pkg/index.js"), b"x").unwrap();
    fs::create_dir_all(tmp.path().join("target")).unwrap();
    fs::write(tmp.path().join("target/debug.bin"), b"x").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    build_index(tmp.path(), &db_path).unwrap();
    let src = FileSource::open(&db_path).unwrap();
    let reader = DbReader::open(src).unwrap();

    // "real" is indexed; "index.js" and "debug.bin" (under skipped dirs) are not.
    assert!(query(&reader, "real", None)
        .unwrap()
        .iter()
        .any(|p| p.ends_with("real.txt")));
    assert!(query(&reader, "index", None).unwrap().is_empty());
    assert!(query(&reader, "debug", None).unwrap().is_empty());
}

#[test]
fn extra_skip_excludes_custom_dirs() {
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("keep.txt"), b"x").unwrap();
    fs::create_dir_all(tmp.path().join("vendored/lib")).unwrap();
    fs::write(tmp.path().join("vendored/lib/a.c"), b"x").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    build_index_with(tmp.path(), &db_path, &["vendored".to_string()], false, &[]).unwrap();
    let src = FileSource::open(&db_path).unwrap();
    let reader = DbReader::open(src).unwrap();

    assert!(query(&reader, "keep", None)
        .unwrap()
        .iter()
        .any(|p| p.ends_with("keep.txt")));
    // "vendored" was pruned via the extra skip name.
    assert!(query(&reader, "vendored", None).unwrap().is_empty());
    assert!(query(&reader, "a.c", None).unwrap().is_empty());
}
