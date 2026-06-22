// SPDX-License-Identifier: MIT
//! End-to-end test: build a DB, start the daemon, query over the socket.

use std::path::Path;
use std::time::Duration;

use df_index::build_index;
use df_ipc::proto::{ResponseFrame, SearchOptions, SearchRequest};
use df_ipc::{decode_frame, encode_request, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::UnixStream;

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
    };
    f.send(encode_request(&req).unwrap()).await.unwrap();

    let mut got: Vec<String> = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Batch { paths, .. }) => got.extend(paths),
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
    };
    let (_batches, got) = query_and_collect(&socket, req).await;
    assert!(got.iter().any(|p| p.ends_with("match_a.txt")));
    assert!(!got.iter().any(|p| p.ends_with("match_b.txt")));

    server.abort();
}
