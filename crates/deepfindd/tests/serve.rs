// SPDX-License-Identifier: MIT
//! End-to-end test: build a DB, start the daemon, query over the socket.

use std::path::Path;
use std::time::Duration;

use df_index::{build_content_index, build_index, ContentBuildOptions};
use df_ipc::proto::{CaseControl, LineHit, MatchKind, ResponseFrame, SearchOptions, SearchRequest};
use df_ipc::{decode_frame, encode_request, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::UnixStream;

/// The two df-watch integration tests (`df_watch_serves_incremental_update`,
/// `background_built_db_is_watched`) each drive a daemon through
/// `build_content_index` + FSEvents-driven `rebuild_and_swap` convergence
/// windows. Run concurrently they double the system load and occasionally
/// flake against the tight convergence deadlines. This async lock serializes
/// them (one at a time) to remove the concurrent-load contention. A tokio
/// Mutex is used because the guard must be held across `.await` points.
static DF_WATCH_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn connect_wait(sock: &Path) -> UnixStream {
    for _ in 0..200 {
        if let Ok(s) = UnixStream::connect(sock).await {
            return s;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("daemon did not come up at {}", sock.display());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn serve_query_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("alpha.txt"), b"x").unwrap();
    std::fs::write(tmp.path().join("beta.log"), b"x").unwrap();
    std::fs::create_dir_all(tmp.path().join("docs")).unwrap();
    std::fs::write(tmp.path().join("docs/gamma.md"), b"x").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    build_index(tmp.path(), &db_path).unwrap();
    let socket = tmp.path().join("daemon.sock");

    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let stream = connect_wait(&socket).await;
    let mut f = framed(stream);
    let req = SearchRequest {
        query: "alpha".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    f.send(encode_request(&req).unwrap()).await.unwrap();

    let mut got: Vec<String> = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Batch { paths, .. }) => got.extend(paths),
            Ok(ResponseFrame::Lines { .. }) => {}
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::Error { message }) => panic!("error frame: {message}"),
            Err(e) => panic!("decode: {e}"),
        }
    }
    assert!(got.iter().any(|p| p.ends_with("alpha.txt")));
    assert!(!got.iter().any(|p| p.ends_with("beta.log")));

    // second query: directory match
    let stream2 = connect_wait(&socket).await;
    let mut f2 = framed(stream2);
    let req2 = SearchRequest {
        query: "docs".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    f2.send(encode_request(&req2).unwrap()).await.unwrap();
    while let Some(frame) = f2.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::Batch { .. }) => {}
            other => panic!("{other:?}"),
        }
    }

    server.abort();
}

/// `query_and_collect`: send a request, count Batch frames, return all paths.
async fn query_and_collect(socket: &Path, req: SearchRequest) -> (usize, Vec<String>) {
    let stream = connect_wait(socket).await;
    let mut f = framed(stream);
    f.send(encode_request(&req).unwrap()).await.unwrap();
    let mut batches = 0usize;
    let mut got: Vec<String> = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Batch { paths, .. }) => {
                batches += 1;
                got.extend(paths);
            }
            Ok(ResponseFrame::Lines { .. }) => {}
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::Error { message }) => panic!("error frame: {message}"),
            Err(e) => panic!("decode: {e}"),
        }
    }
    (batches, got)
}

/// >512 matches must arrive as multiple streamed Batch frames (REVIEW §7.9).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streamed_in_multiple_batches() {
    let tmp = tempfile::tempdir().unwrap();
    for i in 0..600u32 {
        std::fs::write(tmp.path().join(format!("bulk_{i:04}.txt")), b"x").unwrap();
    }
    let db_path = tmp.path().join("index.dfdb");
    build_index(tmp.path(), &db_path).unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "bulk".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    let (batches, got) = query_and_collect(&socket, req).await;
    assert!(batches >= 2, "expected streamed multi-batch, got {batches}");
    assert_eq!(got.len(), 600);

    server.abort();
}

/// `scope` filters matches to a subtree.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn scope_filters_subtree() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tmp.path().join("src")).unwrap();
    std::fs::create_dir_all(tmp.path().join("docs")).unwrap();
    std::fs::write(tmp.path().join("src/match_a.txt"), b"x").unwrap();
    std::fs::write(tmp.path().join("docs/match_b.txt"), b"x").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    build_index(tmp.path(), &db_path).unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "match".into(),
        scope: Some(tmp.path().join("src")),
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    let (_batches, got) = query_and_collect(&socket, req).await;
    assert!(got.iter().any(|p| p.ends_with("match_a.txt")));
    assert!(!got.iter().any(|p| p.ends_with("match_b.txt")));

    server.abort();
}

/// Combined filename + content results: a file matching by BOTH name and content
/// is reported once with MatchKind::Both.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn combined_filename_and_content_results() {
    let tmp = tempfile::tempdir().unwrap();
    // alpha.rs matches by filename (path contains "alpha") AND content ("fn alpha").
    std::fs::write(tmp.path().join("alpha.rs"), b"fn alpha() {}").unwrap();
    // other.txt matches by NEITHER name nor content for query "alpha".
    std::fs::write(tmp.path().join("other.txt"), b"nothing relevant here").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    let _ = build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();

    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let stream = connect_wait(&socket).await;
    let mut f = framed(stream);
    let req = SearchRequest {
        query: "alpha".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    f.send(encode_request(&req).unwrap()).await.unwrap();

    let mut paths: Vec<String> = Vec::new();
    let mut kinds: Vec<MatchKind> = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Batch { paths: p, kind, .. }) => {
                paths.extend(p);
                kinds.extend(kind);
            }
            Ok(ResponseFrame::Lines { .. }) => {}
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::Error { message }) => panic!("error frame: {message}"),
            Err(e) => panic!("decode: {e}"),
        }
    }
    assert!(paths.iter().any(|p| p.ends_with("alpha.rs")));
    // alpha.rs matched both layers ⇒ at least one Both.
    assert!(
        kinds.contains(&MatchKind::Both),
        "no Both kind: {:?}",
        kinds
    );

    server.abort();
}

/// Smart-case + `-s`/`-i` end-to-end through the daemon. Files live in separate
/// subdirs so the case-insensitive macOS FS can't collapse "Foo.txt"/"foo.txt".
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn case_sensitivity_end_to_end() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tmp.path().join("d1")).unwrap();
    std::fs::create_dir_all(tmp.path().join("d2")).unwrap();
    std::fs::write(tmp.path().join("d1/Foo.txt"), b"fn Foo() {}").unwrap();
    std::fs::write(tmp.path().join("d2/foo.txt"), b"fn foo() {}").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    let _ = build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();

    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let basenames = |got: Vec<String>| {
        let mut v: Vec<String> = got
            .iter()
            .filter_map(|p| p.rsplit('/').next().map(|s| s.to_string()))
            .collect();
        v.sort();
        v
    };
    let req = |query: &str, case: CaseControl| SearchRequest {
        query: query.into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            case,
            ..Default::default()
        },
        db: None,
    };

    // Smart-case default, uppercase query ⇒ case-sensitive: only Foo.txt.
    let (_b, got) = query_and_collect(&socket, req("Foo", CaseControl::Smart)).await;
    assert_eq!(basenames(got), vec!["Foo.txt".to_string()]);

    // Smart-case, lowercase query ⇒ case-insensitive: both.
    let (_b, got) = query_and_collect(&socket, req("foo", CaseControl::Smart)).await;
    assert_eq!(
        basenames(got),
        vec!["Foo.txt".to_string(), "foo.txt".to_string()]
    );

    // Explicit -s on a lowercase query ⇒ case-sensitive: only foo.txt.
    let (_b, got) = query_and_collect(&socket, req("foo", CaseControl::Sensitive)).await;
    assert_eq!(basenames(got), vec!["foo.txt".to_string()]);

    // Explicit -i on an uppercase query ⇒ case-insensitive: both.
    let (_b, got) = query_and_collect(&socket, req("Foo", CaseControl::Insensitive)).await;
    assert_eq!(
        basenames(got),
        vec!["Foo.txt".to_string(), "foo.txt".to_string()]
    );

    server.abort();
}

/// Content-regex (`--regex`) matches files whose *content* matches the pattern,
/// equivalent to `grep -El`. The longest literal atom drives candidate gen;
/// `regex.is_match` over the mmap content bytes is authoritative.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn content_regex_matches_grep_e() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("a.rs"), b"fn main() { }").unwrap();
    std::fs::write(tmp.path().join("b.rs"), b"async fn main() {}").unwrap();
    std::fs::write(tmp.path().join("c.rs"), b"struct Foo;").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();

    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "fn.*main".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            regex: Some("fn.*main".into()),
            ..Default::default()
        },
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert!(
        got.iter().any(|p| p.ends_with("a.rs")),
        "missing a.rs: {got:?}"
    );
    assert!(
        got.iter().any(|p| p.ends_with("b.rs")),
        "missing b.rs: {got:?}"
    );
    assert!(
        !got.iter().any(|p| p.ends_with("c.rs")),
        "unexpected c.rs: {got:?}"
    );

    server.abort();
}

/// `query_lines`: send a request, collect all `Lines` hits.
async fn query_lines(socket: &Path, req: SearchRequest) -> Vec<LineHit> {
    let stream = connect_wait(socket).await;
    let mut f = framed(stream);
    f.send(encode_request(&req).unwrap()).await.unwrap();
    let mut hits = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Lines { hits: h }) => hits.extend(h),
            Ok(ResponseFrame::Batch { .. }) => {}
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::Error { message }) => panic!("error frame: {message}"),
            Err(e) => panic!("decode: {e}"),
        }
    }
    hits
}

/// `-n` reports one line hit per matching line, numbered like `grep -n`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn content_line_numbers_match_grep_n() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(
        tmp.path().join("a.txt"),
        b"alpha\nbeta main\ngamma\nmain delta\n",
    )
    .unwrap();

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();

    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "main".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            line_numbers: true,
            ..Default::default()
        },
        db: None,
    };
    let hits = query_lines(&socket, req).await;
    let mut nos: Vec<u32> = hits.iter().map(|h| h.line_no).collect();
    nos.sort();
    assert_eq!(nos, vec![2, 4], "line numbers: {hits:?}"); // "beta main" / "main delta"

    server.abort();
}

/// `--filename` layer-only excludes content matches; `--content` excludes
/// filename matches.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn layer_select_restricts_layers() {
    let tmp = tempfile::tempdir().unwrap();
    // alpha.rs matches "alpha" by BOTH filename and content.
    std::fs::write(tmp.path().join("alpha.rs"), b"fn alpha() {}").unwrap();
    // beta.rs matches "alpha" by CONTENT only.
    std::fs::write(tmp.path().join("beta.rs"), b"// alpha mention\n").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let basenames = |got: Vec<String>| {
        let mut v: Vec<String> = got
            .iter()
            .filter_map(|p| p.rsplit('/').next().map(|s| s.to_string()))
            .collect();
        v.sort();
        v
    };

    // Filename-only: only alpha.rs (its path contains "alpha"); beta.rs path does not.
    let req = SearchRequest {
        query: "alpha".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            layers: df_ipc::proto::LayerMask {
                filename: true,
                content: false,
            },
            ..Default::default()
        },
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert_eq!(basenames(got), vec!["alpha.rs".to_string()]);

    // Content-only: both (alpha.rs content + beta.rs content).
    let req = SearchRequest {
        query: "alpha".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            layers: df_ipc::proto::LayerMask {
                filename: false,
                content: true,
            },
            ..Default::default()
        },
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert_eq!(
        basenames(got),
        vec!["alpha.rs".to_string(), "beta.rs".to_string()]
    );

    server.abort();
}

/// `-b` (basename mode): the query must match the file's base name, not the
/// full path.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn basename_mode_matches_only_basename() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tmp.path().join("sub")).unwrap();
    // "x.txt" under dir "sub": full path contains "sub", basename does not.
    std::fs::write(tmp.path().join("sub/x.txt"), b"x").unwrap();
    // a file literally named "sub.txt": basename contains "sub".
    std::fs::write(tmp.path().join("sub.txt"), b"x").unwrap();

    let db_path = tmp.path().join("index.dfdb");
    build_index(tmp.path(), &db_path).unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let basenames = |got: Vec<String>| {
        let mut v: Vec<String> = got
            .iter()
            .filter_map(|p| p.rsplit('/').next().map(|s| s.to_string()))
            .collect();
        v.sort();
        v
    };

    // Full-path mode (default): x.txt matches because its PATH contains "sub".
    let req = SearchRequest {
        query: "sub".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert!(
        basenames(got).contains(&"x.txt".to_string()),
        "full-path mode should include x.txt"
    );

    // Basename mode: x.txt is gone (its basename "x.txt" lacks "sub"); sub.txt
    // still matches (basename "sub.txt" contains "sub").
    let req = SearchRequest {
        query: "sub".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            path_mode: df_ipc::proto::PathMode::Basename,
            ..Default::default()
        },
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    let bn = basenames(got);
    assert!(
        !bn.contains(&"x.txt".to_string()),
        "basename mode should exclude x.txt: {bn:?}"
    );
    assert!(
        bn.contains(&"sub.txt".to_string()),
        "basename mode should include sub.txt: {bn:?}"
    );

    server.abort();
}

/// Default sort: Both before Content before Filename, then by path; stable.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_sort_orders_by_kind_then_path() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("zfile.txt"), b"needle here\n").unwrap(); // content-only
    std::fs::write(tmp.path().join("aneedle.txt"), b"unrelated\n").unwrap(); // filename-only

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    // Collect paths in delivery order (default sort applied server-side).
    let stream = connect_wait(&socket).await;
    let mut f = framed(stream);
    f.send(encode_request(&req).unwrap()).await.unwrap();
    let mut order: Vec<String> = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Batch { paths, .. }) => order.extend(paths),
            Ok(ResponseFrame::Lines { .. }) => {}
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::Error { message }) => panic!("error frame: {message}"),
            Err(e) => panic!("decode: {e}"),
        }
    }
    // zfile.txt is a content match (weight 1); aneedle.txt is filename-only (weight 2).
    // Content-first ⇒ zfile.txt before aneedle.txt regardless of alphabetic order.
    let basenames: Vec<&str> = order
        .iter()
        .map(|p| p.rsplit('/').next().unwrap())
        .collect();
    assert_eq!(
        basenames,
        vec!["zfile.txt", "aneedle.txt"],
        "order: {order:?}"
    );

    server.abort();
}

/// Multi-DB: the daemon serves the default DB + registered named DBs. A default
/// search unions both (path-keyed dedup); `--db <name>` restricts to one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn multi_db_search_unions_and_selects() {
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let db_path = data.join("db/index.dfdb");

    // Default DB: root1 holds "shared.txt".
    let root1 = data.join("root1");
    std::fs::create_dir_all(&root1).unwrap();
    std::fs::write(root1.join("shared.txt"), b"needle").unwrap();
    build_content_index(
        &root1,
        &db_path,
        &data.join("db/content"),
        &ContentBuildOptions::default(),
    )
    .unwrap();

    // Named DB "proj": root2 also holds "shared.txt" (same basename, different path).
    let root2 = data.join("root2");
    std::fs::create_dir_all(&root2).unwrap();
    std::fs::write(root2.join("shared.txt"), b"needle").unwrap();
    let proj_db = data.join("db/proj/index.dfdb");
    build_content_index(
        &root2,
        &proj_db,
        &data.join("db/proj/content"),
        &ContentBuildOptions::default(),
    )
    .unwrap();

    // Register "proj".
    let mut reg = df_index::Registry::load(data);
    reg.upsert(df_index::DbRecord {
        name: "proj".into(),
        root: root2.clone(),
        db_path: proj_db.clone(),
        content_dir: data.join("db/proj/content"),
    });
    reg.save().unwrap();

    let socket = data.join("daemon.sock");
    let sock = socket.clone();
    let dbp = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });

    // Default search (db: None): both DBs contribute → two distinct paths.
    let req = SearchRequest {
        query: "shared".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert_eq!(
        got.len(),
        2,
        "default search should union both DBs: {got:?}"
    );

    // `--db proj`: only the proj DB → one path (root2/shared.txt).
    let req = SearchRequest {
        query: "shared".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("proj".into()),
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert_eq!(got.len(), 1, "--db proj should select one DB: {got:?}");
    assert!(got[0].ends_with("root2/shared.txt"), "got: {got:?}");

    server.abort();
}

/// `--expr` (bfs): a find-style expression filters query results post-query.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bfs_expression_filters_results() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("adata.rs"), vec![b'x'; 200]).unwrap(); // rs + >100 bytes
    std::fs::write(tmp.path().join("bdata.rs"), vec![b'x'; 10]).unwrap(); // rs but small
    std::fs::write(tmp.path().join("cdata.txt"), vec![b'x'; 200]).unwrap(); // big but .txt

    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    build_content_index(
        tmp.path(),
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    // "data" matches all three by filename; the expr keeps only *.rs over 100 bytes.
    let req = SearchRequest {
        query: "data".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            expr: Some("-name '*.rs' -size +100c".into()),
            ..Default::default()
        },
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    let basenames: Vec<&str> = got.iter().map(|p| p.rsplit('/').next().unwrap()).collect();
    assert_eq!(basenames, vec!["adata.rs"], "expr filter: {got:?}");

    server.abort();
}

/// df-watch (DEEPFIND_WATCH): mutating a file under a registered DB's root triggers
/// an incremental rebuild + hot-swap; the daemon then serves the UPDATED result
/// without restart (equivalent to a fresh rebuild).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn df_watch_serves_incremental_update() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

    let db_path = data.join("db/index.dfdb");
    // A default DB (so serve() finds one) + the watched named DB "w".
    build_content_index(
        &root,
        &db_path,
        &data.join("db/content"),
        &ContentBuildOptions::default(),
    )
    .unwrap();
    let w_db = data.join("db/w/index.dfdb");
    build_content_index(
        &root,
        &w_db,
        &data.join("db/w/content"),
        &ContentBuildOptions::default(),
    )
    .unwrap();
    let mut reg = df_index::Registry::load(data);
    reg.upsert(df_index::DbRecord {
        name: "w".into(),
        root: root.clone(),
        db_path: w_db.clone(),
        content_dir: data.join("db/w/content"),
    });
    reg.save().unwrap();

    let socket = data.join("daemon.sock");
    std::env::set_var("DEEPFIND_WATCH", "1");
    let sock = socket.clone();
    let dbp = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    // Give the watcher a moment to install.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Baseline: "needle --db w" finds a.txt.
    let req = SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("w".into()),
    };
    let (_b, got) = query_and_collect(&socket, req).await;
    assert!(
        got.iter().any(|p| p.ends_with("a.txt")),
        "baseline: {got:?}"
    );

    // Mutate: a.txt drops the needle; b.txt gains it.
    std::fs::write(root.join("a.txt"), b"nothing now").unwrap();
    std::fs::write(root.join("b.txt"), b"needle now here").unwrap();

    // Poll until the incremental rebuild swaps in (debounce + rebuild + FSEvents).
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let req = SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: Some("w".into()),
        };
        let (_b, got) = query_and_collect(&socket, req).await;
        let has_b = got.iter().any(|p| p.ends_with("b.txt"));
        let no_a = !got.iter().any(|p| p.ends_with("a.txt"));
        if has_b && no_a {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_WATCH");
    server.abort();
    assert!(converged, "incremental update did not converge");
}

/// A registered DB whose index is missing gets built in the background on
/// serve() startup; once built, queries return the indexed content (equivalent
/// to a full `deepfind index`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_build_populates_missing_index() {
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

    // Register watched DB "w" with a root, but build NO index for it yet.
    let w_db = data.join("db/w/index.dfdb");
    let mut reg = df_index::Registry::load(data);
    reg.upsert(df_index::DbRecord {
        name: "w".into(),
        root: root.clone(),
        db_path: w_db.clone(),
        content_dir: data.join("db/w/content"),
    });
    reg.save().unwrap();

    let socket = data.join("daemon.sock");
    let sock = socket.clone();
    let dbp = data.join("db/index.dfdb"); // default DB path passed to serve (also unbuilt)
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });

    // Poll until the background build swaps "w" in.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let req = SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: Some("w".into()),
        };
        let (_b, got) = query_and_collect(&socket, req).await;
        if got.iter().any(|p| p.ends_with("a.txt")) {
            converged = true;
            break;
        }
    }
    server.abort();
    assert!(converged, "background build did not populate the index");
}

/// A registered DB with no index gets background-built AND watched: after the
/// build swaps in, mutating a file under the root is reflected in queries
/// (df-watch attached post-build). Regression for the holistic-review I1 bug.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_built_db_is_watched() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

    // Register watched DB "w" with a root but NO index yet.
    let w_db = data.join("db/w/index.dfdb");
    let mut reg = df_index::Registry::load(data);
    reg.upsert(df_index::DbRecord {
        name: "w".into(),
        root: root.clone(),
        db_path: w_db.clone(),
        content_dir: data.join("db/w/content"),
    });
    reg.save().unwrap();

    let socket = data.join("daemon.sock");
    let sock = socket.clone();
    let dbp = data.join("db/index.dfdb");
    std::env::set_var("DEEPFIND_WATCH", "1");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Wait for the background build to populate "w" (a.txt found).
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    let mut built = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let req = SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: Some("w".into()),
        };
        let (_b, got) = query_and_collect(&socket, req).await;
        if got.iter().any(|p| p.ends_with("a.txt")) {
            built = true;
            break;
        }
    }
    assert!(built, "background build did not populate");

    // NOW mutate: add a NEW file with the needle. If df-watch attached, it shows up.
    std::fs::write(root.join("b.txt"), b"needle now here").unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let req = SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: Some("w".into()),
        };
        let (_b, got) = query_and_collect(&socket, req).await;
        if got.iter().any(|p| p.ends_with("b.txt")) {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_WATCH");
    server.abort();
    assert!(
        converged,
        "df-watch did not attach to the background-built DB (I1 regression)"
    );
}

/// With no index present, serve() still binds + answers (empty result), so the
/// background builder (Task 2.3) can populate it later without a restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn serve_starts_with_no_index() {
    let tmp = tempfile::tempdir().unwrap();
    let socket = tmp.path().join("daemon.sock");
    let db = tmp.path().join("db/index.dfdb"); // intentionally NOT built
    let sock = socket.clone();
    let dbp = db.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    let req = SearchRequest {
        query: "x".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: None,
    };
    let (_b, got) = query_and_collect(&socket, req).await; // must NOT error / hang
    assert!(got.is_empty());
    server.abort();
}
