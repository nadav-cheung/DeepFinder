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

/// Single-instance guard: a second `serve()` sharing the daemon's lock dir is
/// rejected fast (WouldBlock) instead of binding a second socket. Two different
/// socket paths under the same tempdir resolve to the same `daemon.lock`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn second_serve_in_same_dir_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().to_path_buf();
    let sock_a = dir.join("a.sock");
    let sock_b = dir.join("b.sock"); // different socket, same dir → same daemon.lock
    let db = dir.join("index.dfdb");

    let s1 = {
        let sock_a = sock_a.clone();
        let db = db.clone();
        tokio::spawn(async move { deepfindd::serve(&sock_a, &db).await })
    };
    // Let the first serve acquire the singleton lock (its first sync op).
    tokio::time::sleep(Duration::from_millis(150)).await;

    let res = deepfindd::serve(&sock_b, &db).await;
    assert!(
        matches!(res, Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock),
        "second serve should be rejected as already-running, got {res:?}"
    );
    s1.abort();
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
            Ok(ResponseFrame::IndexAck { .. }) => panic!("unexpected IndexAck"),
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
            Ok(ResponseFrame::IndexAck { .. }) => panic!("unexpected IndexAck"),
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
            Ok(ResponseFrame::IndexAck { .. }) => panic!("unexpected IndexAck"),
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
            Ok(ResponseFrame::IndexAck { .. }) => panic!("unexpected IndexAck"),
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
            Ok(ResponseFrame::IndexAck { .. }) => panic!("unexpected IndexAck"),
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

/// `--db nonexistent` returns an Error frame (not silently empty).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn error_on_nonexistent_db() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("a.txt"), b"needle").unwrap();
    let db_path = tmp.path().join("index.dfdb");
    build_index(tmp.path(), &db_path).unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("nonexistent".into()),
    };
    let stream = connect_wait(&socket).await;
    let mut f = framed(stream);
    f.send(encode_request(&req).unwrap()).await.unwrap();
    let mut err = None;
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Error { message }) => {
                err = Some(message);
                break;
            }
            Ok(ResponseFrame::Batch { .. }) | Ok(ResponseFrame::Lines { .. }) => {}
            Ok(ResponseFrame::Done { .. }) => break,
            Ok(ResponseFrame::IndexAck { .. }) => panic!("unexpected IndexAck"),
            Err(e) => panic!("decode: {e}"),
        }
    }
    let msg = err.expect("should receive an Error frame for nonexistent DB");
    assert!(
        msg.contains("nonexistent"),
        "error should mention the DB name: {msg}"
    );

    server.abort();
}

/// `--limit 3` returns exactly 3 results.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn limit_caps_results() {
    let tmp = tempfile::tempdir().unwrap();
    for i in 0..10 {
        std::fs::write(tmp.path().join(format!("match_{i}.txt")), b"needle").unwrap();
    }
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

    // Unlimited: all 10.
    let (_b, got) = query_and_collect(
        &socket,
        SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: None,
        },
    )
    .await;
    assert_eq!(got.len(), 10, "unlimited should return all: {got:?}");

    // Limit: exactly 3.
    let (_b, got) = query_and_collect(
        &socket,
        SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: Some(3),
            opts: SearchOptions::default(),
            db: None,
        },
    )
    .await;
    assert_eq!(got.len(), 3, "limit 3 should return 3: {got:?}");

    server.abort();
}

/// P2.3: `deepfind index` over the socket submits a background build; the daemon
/// hot-swaps the index, after which queries see the freshly-indexed content.
/// Mirrors `background_build_populates_missing_index` but the build is triggered
/// by an `IndexRequest`, not startup. (No df-watch / FSEvents ⇒ not subject to
/// the DF_WATCH_LOCK concurrency flake.)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn submit_index_request_builds_in_background() {
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

    let socket = data.join("daemon.sock");
    let dbp = data.join("db/index.dfdb"); // does not exist yet
    let sock = socket.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });

    // Wait for the listener to bind, then submit an IndexRequest and read the ack.
    {
        let stream = connect_wait(&socket).await;
        let mut f = framed(stream);
        let req = df_ipc::proto::IndexRequest {
            root: Some(root.clone()),
            ..Default::default()
        };
        f.send(df_ipc::encode_index_request(&req).unwrap())
            .await
            .unwrap();
        let frame = f.next().await.expect("ack frame");
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::IndexAck { accepted, .. }) => {
                assert!(accepted, "build not accepted")
            }
            Ok(other) => panic!("expected IndexAck, got {other:?}"),
            Err(e) => panic!("decode: {e}"),
        }
    }

    // Poll until the background build swaps the index in.
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let req = SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: None,
        };
        let (_n, got) = query_and_collect(&socket, req).await;
        if got.iter().any(|p| p.ends_with("a.txt")) {
            converged = true;
            break;
        }
    }
    server.abort();
    assert!(
        converged,
        "submitted index build did not populate the index"
    );
}

/// Every query takes a per-connection `Arc<DbSet>` snapshot; a background
/// rebuild hot-swaps via `ArcSwap::store`, so a snapshot taken before the swap
/// stays valid for its whole query. This test asserts the practical guarantee:
/// searches run *during* a rebuild never error and never return a partial /
/// mixed result set — each is cleanly the OLD state ([a.txt]) or the NEW ([]).
/// It does NOT use df-watch (no FSEvents ⇒ not subject to the DF_WATCH_LOCK
/// flake); the swap is triggered by an IndexRequest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn searches_during_rebuild_never_error() {
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle").unwrap();

    // v1 index so the daemon starts with a real, queryable DB.
    let dbp = data.join("db/index.dfdb");
    let content_dir = data.join("db/content");
    df_index::build_content_index(&root, &dbp, &content_dir, &Default::default()).unwrap();
    let socket = data.join("daemon.sock");
    let sock = socket.clone();
    let dbp_run = dbp.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp_run).await });

    // Concurrent search loop. query_and_collect panics on an Error frame, so a
    // mid-swap failure fails the test directly; we also collect the sets to
    // assert none is partial/garbage.
    let search_task = tokio::spawn({
        let socket = socket.clone();
        async move {
            let mut sets: Vec<Vec<String>> = Vec::new();
            let deadline = std::time::Instant::now() + Duration::from_millis(1000);
            while std::time::Instant::now() < deadline {
                let req = SearchRequest {
                    query: "needle".into(),
                    scope: None,
                    limit: None,
                    opts: SearchOptions::default(),
                    db: None,
                };
                let (_n, got) = query_and_collect(&socket, req).await;
                sets.push(got);
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            sets
        }
    });

    // Mid-loop: change the file so the rebuild swaps to a state without "needle",
    // then submit the rebuild over the socket.
    tokio::time::sleep(Duration::from_millis(150)).await;
    std::fs::write(root.join("a.txt"), b"all clear nothing to find here").unwrap();
    {
        let stream = connect_wait(&socket).await;
        let mut f = framed(stream);
        let req = df_ipc::proto::IndexRequest {
            root: Some(root.clone()),
            ..Default::default()
        };
        f.send(df_ipc::encode_index_request(&req).unwrap())
            .await
            .unwrap();
        let _ = f.next().await; // consume the IndexAck
    }

    let sets = search_task.await.unwrap();

    // Confirm the rebuild actually landed (so the swap was exercised, not
    // skipped): "needle" must eventually return nothing.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut swapped = false;
    while std::time::Instant::now() < deadline {
        let req = SearchRequest {
            query: "needle".into(),
            scope: None,
            limit: None,
            opts: SearchOptions::default(),
            db: None,
        };
        let (_n, got) = query_and_collect(&socket, req).await;
        if got.is_empty() {
            swapped = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    server.abort();
    assert!(swapped, "rebuild never landed; the swap was not exercised");
    assert!(!sets.is_empty(), "search loop ran no iterations");
    for s in &sets {
        assert!(
            s.is_empty() || s.iter().all(|p| p.ends_with("a.txt")),
            "partial/garbage result set during rebuild: {s:?}"
        );
    }
}

/// Overlay (LSM hot layer), read-only path: an overlay WAL written beside the
/// index is replayed on `serve()`. Overlay hits appear in BOTH the content and
/// filename layers, and a tombstone suppresses a stale cold-layer match — in
/// path-batch mode AND in `-n` line mode. No df-watch here (DEEPFIND_WATCH
/// unset): this exercises only the query-merge read path (Phase 2).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn overlay_wal_replay_merges_and_suppresses() {
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    // cold.txt lives in the COLD shard; the overlay tombstones it.
    std::fs::write(root.join("cold.txt"), b"needle cold\n").unwrap();

    let db_path = data.join("db/index.dfdb");
    let content_dir = data.join("db/content");
    build_content_index(
        &root,
        &db_path,
        &content_dir,
        &ContentBuildOptions::default(),
    )
    .unwrap();

    // Pre-write the overlay WAL beside the index, then drop the store so serve()
    // reopens + replays it.
    let wal_path = data.join("db/overlay.wal");
    let overlay_path = root.join("overlay.txt").to_string_lossy().into_owned();
    let cold_path = root.join("cold.txt").to_string_lossy().into_owned();
    {
        let store = df_index::OverlayStore::open(&wal_path).unwrap();
        let _ = store.append(&df_content::WalRecord::Upsert {
            path: overlay_path.clone(),
            meta: df_core::LiteMeta {
                is_dir: false,
                size: 18,
                mtime: 0,
            },
            content: Some(b"needle in overlay\n".to_vec()),
        });
        let _ = store.append(&df_content::WalRecord::Delete {
            path: cold_path.clone(),
        });
        store.sync().unwrap();
    }

    let socket = data.join("daemon.sock");
    let sock = socket.clone();
    let dbp = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Content query "needle": overlay.txt appears (overlay); cold.txt is suppressed.
    let content_only = SearchRequest {
        query: "needle".into(),
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
    let (_b, got) = query_and_collect(&socket, content_only).await;
    assert!(
        got.iter().any(|p| p.ends_with("overlay.txt")),
        "overlay content hit missing: {got:?}"
    );
    assert!(
        !got.iter().any(|p| p.ends_with("cold.txt")),
        "cold.txt should be tombstoned: {got:?}"
    );

    // Filename query "overlay": overlay file found via the filename overlay.
    let filename_only = SearchRequest {
        query: "overlay".into(),
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
    let (_b, got) = query_and_collect(&socket, filename_only).await;
    assert!(
        got.iter().any(|p| p.ends_with("overlay.txt")),
        "overlay filename hit missing: {got:?}"
    );

    // `-n` line mode: overlay.txt renders a line hit; cold.txt's cold line hit
    // is dropped by tombstone suppression.
    let line_req = SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions {
            line_numbers: true,
            layers: df_ipc::proto::LayerMask {
                filename: false,
                content: true,
            },
            ..Default::default()
        },
        db: None,
    };
    let hits = query_lines(&socket, line_req).await;
    assert!(
        hits.iter().any(|h| h.path.ends_with("overlay.txt")),
        "overlay line hit missing: {hits:?}"
    );
    assert!(
        !hits.iter().any(|h| h.path.ends_with("cold.txt")),
        "cold.txt line hit should be tombstoned: {hits:?}"
    );

    server.abort();
}

/// Compaction (LSM): once the overlay reaches the threshold (here forced low via
/// `DEEPFIND_COMPACTION_THRESHOLD`), df-watch fires a full rebuild + clears the
/// overlay/WAL. The new files then come from the COLD layer (post-rebuild) and
/// the overlay WAL is truncated back to empty. Guards on DF_WATCH_LOCK (FSEvents).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn overlay_compaction_clears_and_rebuilds() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

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
    let wal_path = data.join("db/w/overlay.wal");
    std::env::set_var("DEEPFIND_WATCH", "1");
    std::env::set_var("DEEPFIND_COMPACTION_THRESHOLD", "2");
    let sock = socket.clone();
    let dbp = data.join("db/index.dfdb");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Create 3 new needle files → overlay grows past the threshold (2) → compaction.
    for i in 0..3 {
        std::fs::write(root.join(format!("new_{i}.txt")), b"needle").unwrap();
    }

    let req = |db: &str| SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some(db.into()),
    };

    // Poll until: (a) all 4 files present (a.txt + new_0..2), AND (b) the overlay
    // WAL was truncated (compaction ran). Both together prove compaction rebuilt
    // the cold layer and cleared the overlay.
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (_b, got) = query_and_collect(&socket, req("w")).await;
        let all_present = got.iter().any(|p| p.ends_with("a.txt"))
            && (0..3).all(|i| got.iter().any(|p| p.ends_with(&format!("new_{i}.txt"))));
        let wal_empty = std::fs::metadata(&wal_path)
            .map(|m| m.len() == 0)
            .unwrap_or(true);
        if all_present && wal_empty {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_COMPACTION_THRESHOLD");
    std::env::remove_var("DEEPFIND_WATCH");
    server.abort();
    assert!(
        converged,
        "compaction did not converge (rebuild + WAL clear)"
    );
}

/// Safety-net periodic rebuild: independent of df-watch (DEEPFIND_WATCH unset
/// here), a background thread rebuilds every rooted DB on a timer. Creating a
/// new file under the root is picked up by the next safety-net rescan — no
/// FSEvents involved, so this is deterministic (not subject to the df-watch
/// concurrency flake). Verifies the LSM "safety net" recovers missed changes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn safety_net_rebuild_picks_up_new_file() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

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
    // 1s safety-net interval; NO DEEPFIND_WATCH (isolate the safety-net path).
    std::env::set_var("DEEPFIND_SAFETY_NET_SECS", "1");
    let sock = socket.clone();
    let dbp = data.join("db/index.dfdb");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Create b.txt AFTER the initial build; the safety-net rescan must find it.
    std::fs::write(root.join("b.txt"), b"needle now").unwrap();

    let req = SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("w".into()),
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (_b, got) = query_and_collect(&socket, req.clone()).await;
        if got.iter().any(|p| p.ends_with("b.txt")) {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_SAFETY_NET_SECS");
    server.abort();
    assert!(converged, "safety-net rebuild did not pick up b.txt");
}

/// Regression: a registry reload mid-run (dbs.toml rewrite, e.g. `db add`) must
/// NOT orphan the overlay handle — df-watch captured the handle at spawn and
/// keeps updating it; after the reload, queries must still see new overlay
/// changes. Guards the `reuse_handles_from` fix. Guards on DF_WATCH_LOCK.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn registry_reload_does_not_orphan_overlay() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

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
    let dbp = data.join("db/index.dfdb");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(400)).await;

    let req = || SearchRequest {
        query: "needle".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("w".into()),
    };

    // 1. overlay works before the reload: add b.txt → found.
    std::fs::write(root.join("b.txt"), b"needle b").unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (_b, got) = query_and_collect(&socket, req()).await;
        if got.iter().any(|p| p.ends_with("b.txt")) {
            break;
        }
    }

    // 2. trigger a registry reload by rewriting dbs.toml (new mtime, same entries).
    let reg = df_index::Registry::load(data);
    reg.save().unwrap();
    // Let the registry watcher react (debounce + reload).
    tokio::time::sleep(Duration::from_millis(900)).await;

    // 3. overlay must STILL work after the reload: add c.txt → found (handle not
    //    orphaned). b.txt must still be present too.
    std::fs::write(root.join("c.txt"), b"needle c").unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (_b, got) = query_and_collect(&socket, req()).await;
        let has_c = got.iter().any(|p| p.ends_with("c.txt"));
        let has_b = got.iter().any(|p| p.ends_with("b.txt"));
        if has_c && has_b {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_WATCH");
    server.abort();
    assert!(
        converged,
        "overlay stopped working after registry reload (handle orphaned)"
    );
}

/// Regression: the safety-net periodic rebuild must reload the FILENAME layer
/// (the `DbSet`'s `DbReader`), not just the content shards. Before the fix,
/// `rebuild_and_swap` reloaded content shards but left the filename layer stale,
/// so a file that appeared after the last build was visible by content but NOT
/// by filename until a daemon restart. Deterministic (timer-driven; no FSEvents).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn safety_net_rebuild_reloads_filename_layer() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

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
    // 1s safety-net interval; NO DEEPFIND_WATCH (isolate the safety-net path).
    std::env::set_var("DEEPFIND_SAFETY_NET_SECS", "1");
    let sock = socket.clone();
    let dbp = data.join("db/index.dfdb");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Create a file whose NAME (not content) is the search key. Content stays
    // "needle" everywhere, so a "brandnew" hit can only come from the filename layer.
    std::fs::write(root.join("brandnew.xyz"), b"needle").unwrap();

    let req = SearchRequest {
        query: "brandnew".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("w".into()),
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (_b, got) = query_and_collect(&socket, req.clone()).await;
        if got.iter().any(|p| p.ends_with("brandnew.xyz")) {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_SAFETY_NET_SECS");
    server.abort();
    assert!(
        converged,
        "safety-net rebuild did not surface brandnew.xyz by FILENAME \
         (filename DbSet not reloaded, only content shards)"
    );
}

/// Regression: df-watch compaction (full rebuild + overlay clear) must reload the
/// FILENAME layer too. Before the fix, `compact_and_swap` reloaded content shards
/// and cleared the overlay but left the filename `DbSet` stale, so after a
/// compaction files added since the last build were invisible by filename until a
/// daemon restart. Guards on DF_WATCH_LOCK (FSEvents).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn compaction_reloads_filename_layer() {
    let _guard = DF_WATCH_LOCK.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let data = tmp.path();
    let root = data.join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a.txt"), b"needle here").unwrap();

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
    let wal_path = data.join("db/w/overlay.wal");
    std::env::set_var("DEEPFIND_WATCH", "1");
    std::env::set_var("DEEPFIND_COMPACTION_THRESHOLD", "2");
    let sock = socket.clone();
    let dbp = data.join("db/index.dfdb");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(Duration::from_millis(400)).await;

    // Add 3 files whose NAME is the search key (content is "needle" everywhere,
    // so the query discriminates the filename layer). 3 > threshold(2) → compaction.
    for i in 0..3 {
        std::fs::write(root.join(format!("fn_{i}.xyz")), b"needle").unwrap();
    }

    let req = SearchRequest {
        query: "fn_0".into(),
        scope: None,
        limit: None,
        opts: SearchOptions::default(),
        db: Some("w".into()),
    };

    // Poll until compaction ran (WAL truncated) AND fn_0 is findable by filename —
    // the latter requires the rebuilt filename layer to be reloaded into the DbSet.
    let deadline = std::time::Instant::now() + Duration::from_secs(25);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let wal_empty = std::fs::metadata(&wal_path)
            .map(|m| m.len() == 0)
            .unwrap_or(true);
        let (_b, got) = query_and_collect(&socket, req.clone()).await;
        if wal_empty && got.iter().any(|p| p.ends_with("fn_0.xyz")) {
            converged = true;
            break;
        }
    }
    std::env::remove_var("DEEPFIND_COMPACTION_THRESHOLD");
    std::env::remove_var("DEEPFIND_WATCH");
    server.abort();
    assert!(
        converged,
        "compaction ran (or timed out) but fn_0.xyz was not findable by FILENAME \
         afterward (filename DbSet not reloaded, only content shards)"
    );
}
