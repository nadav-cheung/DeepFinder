// SPDX-License-Identifier: MIT
//! Shard roundtrip: build → open → read paths/meta/content/postings.

use df_content::{ShardBuilder, ShardReader};
use df_core::LiteMeta;

fn sample() -> Vec<u8> {
    let mut b = ShardBuilder::new(0, 1000);
    b.add_file(
        "/src/main.rs",
        false,
        12,
        1_700_000_000,
        b"fn main() { todo() }",
    );
    b.add_file("/src/lib.rs", false, 8, 1_700_000_010, b"pub fn lib() {}");
    b.add_file("/docs/readme.md", false, 5, 1_700_000_020, b"# readme");
    b.finish(1_700_000_030)
}

#[test]
fn open_and_metadata() {
    let bytes = sample();
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.num_docs(), 3);
    assert_eq!(r.base_docid(), 1000);
    assert_eq!(r.path(0).unwrap(), "/src/main.rs");
    let m = r.meta(1).unwrap();
    assert_eq!(
        m,
        LiteMeta {
            is_dir: false,
            size: 8,
            mtime: 1_700_000_010
        }
    );
}

#[test]
fn content_slice() {
    let bytes = sample();
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.content(0).unwrap(), b"fn main() { todo() }");
    assert_eq!(r.content(2).unwrap(), b"# readme");
}

#[test]
fn posting_roundtrip() {
    let bytes = sample();
    let r = ShardReader::open(&bytes).unwrap();
    // trigram "fn " appears in main.rs (docid 0) and lib.rs (docid 1).
    let key = (b'f' as u32) << 16 | (b'n' as u32) << 8 | b' ' as u32;
    let post = r.posting(key).unwrap().unwrap();
    assert!(post.contains(&0));
    assert!(post.contains(&1));
    assert!(!post.contains(&2));
    // absent trigram
    let zzz = (b'z' as u32) << 16 | (b'z' as u32) << 8 | b'z' as u32;
    assert!(r.posting(zzz).unwrap().is_none());
}

#[test]
fn empty_shard_roundtrips() {
    let bytes = ShardBuilder::new(0, 0).finish(1);
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.num_docs(), 0);
    let zzz = (b'z' as u32) << 16 | (b'z' as u32) << 8 | b'z' as u32;
    assert!(r.posting(zzz).unwrap().is_none());
}
