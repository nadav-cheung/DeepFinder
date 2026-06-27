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

#[test]
fn ignore_patterns_skip_matching_files_and_dirs() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("keep.rs"), b"fn keepme() {}").unwrap();
    // A file matching `*.log` (should be skipped) and a dir matching `secret`
    // (should not be descended into — its inner file must not be indexed).
    std::fs::write(root.join("noise.log"), b"fn droplog() {}").unwrap();
    std::fs::create_dir_all(root.join("secret")).unwrap();
    std::fs::write(root.join("secret").join("hidden.rs"), b"fn dropdir() {}").unwrap();

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    let opts = ContentBuildOptions {
        ignore_patterns: vec!["*.log".into(), "secret".into()],
        ..Default::default()
    };
    let report = build_content_index(root, &db, &content_dir, &opts).unwrap();
    // Only keep.rs is a content doc (1); the ignored .log and the dir are gone.
    assert_eq!(
        report.content_docs, 1,
        "content_docs={}",
        report.content_docs
    );

    let manifest = Manifest::read(&content_dir.join("MANIFEST")).expect("MANIFEST");
    let shard_path = content_dir.join(&manifest.shards[0].file);
    let src = MmapSource::open(&shard_path).unwrap();
    let r = ShardReader::open(src.as_slice()).unwrap();

    let kept = candidates(&r, &fold(b"keepme"), b"keepme", false, None).unwrap();
    assert!(
        kept.iter()
            .any(|&d| r.path(d).unwrap().ends_with("keep.rs")),
        "keep.rs must be indexed"
    );
    assert!(
        candidates(&r, &fold(b"droplog"), b"droplog", false, None)
            .unwrap()
            .is_empty(),
        "noise.log must be ignored"
    );
    assert!(
        candidates(&r, &fold(b"dropdir"), b"dropdir", false, None)
            .unwrap()
            .is_empty(),
        "secret/hidden.rs must be ignored (dir pruned)"
    );
}

// edge-1: an absolute-path pattern pointing at a folder UNDER the build root
// (the spec's `/Users/x/Secret` motivating example) must prune it. The naive
// gitignore form fails because a leading `/` anchors relative to the build
// root, not as a filesystem-absolute path.
#[test]
fn ignore_absolute_path_pattern_under_root_prunes_dir() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("keep.rs"), b"fn keepme() {}").unwrap();
    let secret = root.join("Secret");
    std::fs::create_dir_all(&secret).unwrap();
    std::fs::write(secret.join("hidden.rs"), b"fn dropdir() {}").unwrap();

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    // The spec's absolute-path form: the full FS path of the folder to ignore.
    let abs_pat = secret.to_string_lossy().into_owned();
    let opts = ContentBuildOptions {
        ignore_patterns: vec![abs_pat],
        ..Default::default()
    };
    let report = build_content_index(root, &db, &content_dir, &opts).unwrap();
    // Only keep.rs is a content doc; the absolute-path-ignored dir is pruned.
    assert_eq!(
        report.content_docs, 1,
        "content_docs={}",
        report.content_docs
    );

    let manifest = Manifest::read(&content_dir.join("MANIFEST")).expect("MANIFEST");
    let shard_path = content_dir.join(&manifest.shards[0].file);
    let src = MmapSource::open(&shard_path).unwrap();
    let r = ShardReader::open(src.as_slice()).unwrap();
    assert!(
        candidates(&r, &fold(b"keepme"), b"keepme", false, None)
            .unwrap()
            .iter()
            .any(|&d| r.path(d).unwrap().ends_with("keep.rs")),
        "keep.rs must be indexed"
    );
    assert!(
        candidates(&r, &fold(b"dropdir"), b"dropdir", false, None)
            .unwrap()
            .is_empty(),
        "Secret/hidden.rs must be ignored (absolute-path pattern pruned the dir)"
    );
}

// edge-3 / spec §4: a rebuild with a NEW ignore pattern drops files that were
// indexed in the previous cold layer but now match the pattern. This locks the
// documented contract: "already-indexed-but-now-ignored files are dropped at
// the next compaction / safety-net rebuild" — the rebuild path threads
// `ignore_patterns` (from Settings::load) into the build, so the rebuilt cold
// layer honors ignore. (No hot-reload; the rebuild is the recovery path.)
#[test]
fn rebuild_with_new_ignore_pattern_drops_previously_indexed_file() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("keep.rs"), b"fn keepme() {}").unwrap();
    std::fs::write(root.join("noise.log"), b"fn droplog() {}").unwrap();

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");

    // v1: NO ignore pattern → both files indexed.
    let v1 = build_content_index(root, &db, &content_dir, &ContentBuildOptions::default()).unwrap();
    assert_eq!(v1.content_docs, 2, "v1: both files indexed");

    let assert_present = |needle: &[u8], want_suffix: &str| {
        let manifest = Manifest::read(&content_dir.join("MANIFEST")).unwrap();
        let shard_path = content_dir.join(&manifest.shards[0].file);
        let src = MmapSource::open(&shard_path).unwrap();
        let r = ShardReader::open(src.as_slice()).unwrap();
        candidates(&r, &fold(needle), needle, false, None)
            .unwrap()
            .iter()
            .any(|&d| r.path(d).unwrap().ends_with(want_suffix))
    };
    assert!(assert_present(b"keepme", "keep.rs"), "v1: keep.rs present");
    assert!(
        assert_present(b"droplog", "noise.log"),
        "v1: noise.log present"
    );

    // v2: rebuild WITH `*.log` ignore → noise.log is dropped from the cold
    // layer; keep.rs survives.
    let v2 = build_content_index(
        root,
        &db,
        &content_dir,
        &ContentBuildOptions {
            ignore_patterns: vec!["*.log".into()],
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(v2.content_docs, 1, "v2: ignored file dropped on rebuild");
    assert!(assert_present(b"keepme", "keep.rs"), "v2: keep.rs survives");
    assert!(
        !assert_present(b"droplog", "noise.log"),
        "v2: noise.log dropped (already-indexed-but-now-ignored file removed by rebuild)"
    );
}
