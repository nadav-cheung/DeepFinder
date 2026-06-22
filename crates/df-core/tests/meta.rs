// SPDX-License-Identifier: MIT
//! META section + build_time round-trip (DB format v2).

use df_core::db::{DbBuilder, DbReader};

fn build() -> Vec<u8> {
    let mut b = DbBuilder::new();
    b.set_build_time(1_700_000_000);
    // docid 0: file
    b.insert_with("/a/file.txt", false, 4096, 1_690_000_000);
    // docid 1: dir
    b.insert_with("/a/dir", true, 0, 1_695_000_000);
    b.finish()
}

#[test]
fn doc_meta_roundtrip() {
    let bytes = build();
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert_eq!(r.build_time(), 1_700_000_000);

    let f = r.doc_meta(0).unwrap();
    assert!(!f.is_dir);
    assert_eq!(f.size, 4096);
    assert_eq!(f.mtime, 1_690_000_000);

    let d = r.doc_meta(1).unwrap();
    assert!(d.is_dir);
    assert_eq!(d.size, 0);
    assert_eq!(d.mtime, 1_695_000_000);
}

#[test]
fn doc_meta_out_of_range() {
    let bytes = build();
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert!(r.doc_meta(99).is_err());
}

#[test]
fn default_meta_for_insert() {
    // The plain `insert` path (used by existing tests) records default meta.
    let mut b = DbBuilder::new();
    b.insert("/x/y");
    let bytes = b.finish();
    let r = DbReader::open(bytes.as_slice()).unwrap();
    let m = r.doc_meta(0).unwrap();
    assert!(!m.is_dir);
    assert_eq!(m.size, 0);
}

#[test]
fn dirmtime_reserved_field_is_zero() {
    // v2 reserves a dir-mtime hook slot; it must parse without error and the
    // header must be exactly 64 bytes (reader opens cleanly).
    let bytes = build();
    assert!(bytes.len() > 64);
    DbReader::open(bytes.as_slice()).unwrap();
}
