// SPDX-License-Identifier: MIT
//! deepfindd library — resident daemon: serves the index DB over a Unix socket.
//!
//! `serve()` opens the DB once (shared via `Arc`), binds the socket, and spawns
//! a task per connection. Queries (blocking pread + substring) run on
//! `spawn_blocking` so the async runtime stays responsive.

use std::path::Path;
use std::sync::Arc;

use bytes::Bytes;
use df_core::db::DbReader;
use df_core::query::query;
use df_index::FileSource;
use df_ipc::proto::{ResponseFrame, SearchRequest};
use df_ipc::{decode_request, encode_frame, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::{UnixListener, UnixStream};

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

    // Run the blocking query off the async worker pool.
    let db = db.clone();
    let query_str = req.query.clone();
    let limit = req.limit;
    let paths = tokio::task::spawn_blocking(move || query(&db, &query_str, limit))
        .await?
        .map_err(std::io::Error::other)?;

    let total = paths.len() as u32;
    // Slice: single batch (streamed chunking comes later).
    f.send(encode_frame(&ResponseFrame::Batch {
        paths,
        meta: vec![],
    })?)
    .await?;
    f.send(encode_frame(&ResponseFrame::Done { total })?)
        .await?;
    Ok(())
}
