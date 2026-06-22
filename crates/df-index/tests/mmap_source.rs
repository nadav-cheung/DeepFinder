// SPDX-License-Identifier-Identifier: MIT
//! MmapSource: write a shard to disk, mmap it, read it back identically.

use df_content::{ShardBuilder, ShardReader};
use df_index::MmapSource;

#[test]
fn mmap_shard_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("shard-00000.dfcs");

    let mut b = ShardBuilder::new(0, 0);
    b.add_file("/a/x.txt", false, 3, 1, b"abc");
    b.add_file("/a/y.txt", false, 3, 2, b"abd");
    let bytes = b.finish(99);
    std::fs::write(&path, &bytes).unwrap();

    let src = MmapSource::open(&path).unwrap();
    assert_eq!(src.as_slice(), &bytes[..]);

    let r = ShardReader::open(src.as_slice()).unwrap();
    assert_eq!(r.num_docs(), 2);
    assert_eq!(r.content(0).unwrap(), b"abc");

    use df_core::DbSource;
    let head = src.read_at(0, 4).unwrap();
    assert_eq!(head.len(), 4);
}
