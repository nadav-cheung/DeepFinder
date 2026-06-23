// SPDX-License-Identifier: MIT
//! End-to-end: build a temp tree with text + binary + oversized files, then
//! verify shards + MANIFEST + a content query.

use df_content::fold::fold;
use df_content::ShardReader;
use df_core::candidate::candidates;
use df_index::{build_content_index, ContentBuildOptions, Manifest, MmapSource};

#[test]
fn build_content_index_end_to_end() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("a.rs"), b"fn alpha() {}").unwrap();
    std::fs::write(root.join("b.rs"), b"fn beta() {}").unwrap();
    std::fs::write(root.join("bin.dat"), b"abc\x00def").unwrap(); // binary (NUL)
    std::fs::write(root.join("big.txt"), vec![b'z'; 100]).unwrap(); // >tiny cap

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    // tiny max_file_size so big.txt (100 B) is TooLarge but the .rs files index.
    let opts = ContentBuildOptions {
        max_file_size: 50,
        ..Default::default()
    };
    let report = build_content_index(root, &db, &content_dir, &opts).unwrap();

    // filename DB covers all 4 files (+ the root dir entry); content = 2 .rs files.
    assert!(
        report.filename_docs >= 4,
        "filename_docs={}",
        report.filename_docs
    );
    assert_eq!(
        report.content_docs, 2,
        "content_docs={}",
        report.content_docs
    );
    assert!(
        report.content_skipped_binary >= 1,
        "binary skip not counted"
    );
    assert!(report.content_skipped_large >= 1, "large skip not counted");
    assert!(db.is_file());

    let manifest = Manifest::read(&content_dir.join("MANIFEST")).expect("MANIFEST readable");
    assert!(!manifest.shards.is_empty());
    assert_eq!(manifest.total_content_docs, 2);

    // mmap the shard and query content.
    let shard_path = content_dir.join(&manifest.shards[0].file);
    let src = MmapSource::open(&shard_path).unwrap();
    let r = ShardReader::open(src.as_slice()).unwrap();

    let got = candidates(&r, &fold(b"alpha"), b"alpha", false, None).unwrap();
    assert!(got.iter().any(|&d| r.path(d).unwrap().ends_with("a.rs")));
    let got = candidates(&r, &fold(b"beta"), b"beta", false, None).unwrap();
    assert!(got.iter().any(|&d| r.path(d).unwrap().ends_with("b.rs")));
    // "zzz" absent
    assert!(candidates(&r, &fold(b"zzz"), b"zzz", false, None)
        .unwrap()
        .is_empty());
}

#[test]
fn build_content_index_empty_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    let opts = ContentBuildOptions::default();
    let report = build_content_index(root, &db, &content_dir, &opts).unwrap();
    // just the root entry (filename), no content docs, no shards with docs.
    assert!(report.content_docs == 0);
    let manifest = Manifest::read(&content_dir.join("MANIFEST")).expect("MANIFEST");
    assert_eq!(manifest.total_content_docs, 0);
    assert!(db.is_file());
}
