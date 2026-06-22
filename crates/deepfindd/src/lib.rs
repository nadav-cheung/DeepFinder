// SPDX-License-Identifier: MIT
//! deepfindd library — resident daemon: serves the index DB over a Unix socket.
//!
//! `serve()` opens the DB once (shared via `Arc`), binds the socket, and spawns
//! a task per connection. Queries (blocking pread + substring) run on
//! `spawn_blocking` so the async runtime stays responsive. Results are streamed
//! in chunks (REVIEW §7.9 "stream hits, do not buffer"); per-file metadata is
//! resolved from the DB META section and an optional `scope` filters matches.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::Bytes;
use df_core::db::DbReader;
use df_core::{in_scope, query_docids, LiteMeta};
use df_index::FileSource;
use df_ipc::proto::{ResponseFrame, SearchRequest};
use df_ipc::{decode_request, encode_frame, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::{UnixListener, UnixStream};

/// Results per `Batch` frame (streamed chunking, REVIEW §7.9).
const STREAM_CHUNK: usize = 512;

/// Open `db_path`, bind `socket_path`, serve forever.
pub async fn serve(socket_path: &Path, db_path: &Path) -> std::io::Result<()> {
    let src = FileSource::open(db_path)?;
    let reader = DbReader::open(src).map_err(std::io::Error::other)?;
    let db = Arc::new(reader);

    tracing::info!(socket = ?socket_path, db = ?db_path, "deepfindd listening");

    if let Some(dir) = socket_path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    let _ = tokio::fs::remove_file(socket_path).await; // clear stale socket
    let listener = UnixListener::bind(socket_path)?;

    loop {
        let (stream, _) = listener.accept().await?;
        let db = db.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_conn(stream, db).await {
                tracing::warn!("connection error: {e}");
            }
        });
    }
}

async fn handle_conn(
    stream: UnixStream,
    db: Arc<DbReader<FileSource>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut f = framed(stream);

    // Read exactly one request frame.
    let req_bytes: Bytes = match f.next().await {
        Some(Ok(b)) => b.freeze(),
        _ => return Ok(()),
    };
    let req: SearchRequest = decode_request(&req_bytes)?;

    // Engine work runs off the async pool. When a scope is set we fetch all
    // matches (limit = None) so `limit` can refer to in-scope results after
    // filtering; without a scope the engine caps directly.
    let query_str = req.query.clone();
    let scope: Option<PathBuf> = req.scope.clone();
    let limit = req.limit;
    let eff_limit = if scope.is_some() { None } else { limit };
    let db_q = db.clone();
    let docids = tokio::task::spawn_blocking(move || query_docids(&db_q, &query_str, eff_limit))
        .await?
        .map_err(std::io::Error::other)?;

    // Stream resolved (path, meta) pairs in chunks. Each chunk's blocking pread
    // work runs on the pool; frames are sent between chunks.
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let mut total: u32 = 0;
    for chunk in docids.chunks(STREAM_CHUNK) {
        if total as usize >= cap {
            break;
        }
        let remaining = cap - total as usize;
        let db_r = db.clone();
        let scope_r = scope.clone();
        let chunk: Vec<u32> = chunk.to_vec();
        let batch = tokio::task::spawn_blocking(move || {
            resolve_chunk(&db_r, &chunk, scope_r.as_deref(), remaining)
        })
        .await?;
        if batch.is_empty() {
            continue;
        }
        let count = batch.len() as u32;
        let (paths, meta): (Vec<String>, Vec<LiteMeta>) = batch.into_iter().unzip();
        f.send(encode_frame(&ResponseFrame::Batch { paths, meta })?)
            .await?;
        total += count;
    }
    f.send(encode_frame(&ResponseFrame::Done { total })?).await?;
    Ok(())
}

/// Resolve a chunk of DocIDs to `(path, meta)` pairs, applying scope filtering
/// and the result cap. Docs that fail to resolve are skipped (logged).
fn resolve_chunk(
    db: &DbReader<FileSource>,
    docids: &[u32],
    scope: Option<&Path>,
    max: usize,
) -> Vec<(String, LiteMeta)> {
    let mut out = Vec::new();
    for &d in docids {
        if out.len() >= max {
            break;
        }
        let path = match db.doc_path(d) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(docid = d, "skip unresolvable doc: {e}");
                continue;
            }
        };
        if !in_scope(&path, scope) {
            continue;
        }
        let meta = db.doc_meta(d).unwrap_or_default();
        out.push((path, meta));
    }
    out
}
