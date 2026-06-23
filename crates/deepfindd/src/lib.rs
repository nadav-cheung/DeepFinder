// SPDX-License-Identifier: MIT
//! deepfindd library — resident daemon: serves the filename DB + content shards
//! over a Unix socket. A query returns COMBINED filename+content matches, deduped
//! by path (a hit in both layers = MatchKind::Both).
//!
//! `serve()` opens the filename DB (pread, v1) + the content shard set (mmap,
//! v2) once at startup, binds the socket, and spawns a task per connection.
//! Blocking work runs on `spawn_blocking`. Results stream in `Batch` frames.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use df_content::ShardReader;
use df_core::candidate::candidates;
use df_core::db::DbReader;
use df_core::{in_scope, query_docids, LiteMeta};
use df_index::{FileSource, MmapSource};
use df_ipc::proto::{LineHit, MatchKind, ResponseFrame, SearchRequest};
use df_ipc::{decode_request, encode_frame, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::JoinSet;

/// Results per `Batch` frame.
const STREAM_CHUNK: usize = 512;
/// Grace window for in-flight connections on shutdown before aborting.
const DRAIN_TIMEOUT: Duration = Duration::from_secs(2);

/// Complete on SIGINT (Ctrl-C) or SIGTERM.
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        use tokio::signal::unix::{signal, SignalKind};
        let mut s = signal(SignalKind::terminate()).expect("install SIGTERM handler");
        s.recv().await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
}

/// The mmap'd content shard set, opened once at startup from the MANIFEST.
struct ContentShards {
    sources: Vec<MmapSource>,
}

/// Inputs to a content line-query (`-n` / `-C`). Bundled to keep `query_lines`
/// under clippy's argument-count limit.
struct LineQuery<'a> {
    folded: &'a [u8],
    needle: &'a [u8],
    case_sensitive: bool,
    re: Option<&'a regex::bytes::Regex>,
    scope: Option<&'a Path>,
    limit: Option<u32>,
    context: Option<u32>,
}

impl ContentShards {
    /// Open every shard listed in `content_dir/MANIFEST`. Empty if absent.
    fn open(content_dir: &Path) -> Self {
        let mut sources = Vec::new();
        if let Some(manifest) = df_index::Manifest::read(&content_dir.join("MANIFEST")) {
            for entry in &manifest.shards {
                let path = content_dir.join(&entry.file);
                if let Ok(src) = MmapSource::open(&path) {
                    sources.push(src);
                }
            }
        }
        Self { sources }
    }

    /// Content-regex query across all shards. `atom_folded` prefilters candidates
    /// (case-insensitive); `re` verifies authoritatively over the content bytes.
    fn query_regex(
        &self,
        atom_folded: &[u8],
        re: &regex::bytes::Regex,
        scope: Option<&Path>,
        per_shard_limit: Option<u32>,
    ) -> Vec<(String, LiteMeta, MatchKind)> {
        let mut out = Vec::new();
        for src in &self.sources {
            let r = match ShardReader::open(src.as_slice()) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let docids =
                df_content::regex_query::content_regex_docids(&r, atom_folded, re, per_shard_limit)
                    .unwrap_or_default();
            for d in docids {
                let path = match r.path(d) {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                if !in_scope(&path, scope) {
                    continue;
                }
                out.push((path, r.meta(d).unwrap_or_default(), MatchKind::Content));
            }
        }
        out
    }

    /// Content matches rendered as grep-style line hits (`-n` / `-C`). `re`
    /// selects regex vs literal matching; `context` adds surrounding lines.
    /// Pure compute over content bytes — the content never leaves the daemon.
    fn query_lines(&self, q: &LineQuery) -> Vec<LineHit> {
        let mut out = Vec::new();
        for src in &self.sources {
            let r = match ShardReader::open(src.as_slice()) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let docids = match q.re {
                Some(rx) => {
                    df_content::regex_query::content_regex_docids(&r, q.folded, rx, q.limit)
                        .unwrap_or_default()
                }
                None => candidates(&r, q.folded, q.needle, q.case_sensitive, q.limit)
                    .unwrap_or_default(),
            };
            for d in docids {
                let path = match r.path(d) {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                if !in_scope(&path, q.scope) {
                    continue;
                }
                let content = match r.content(d) {
                    Ok(c) => c,
                    Err(_) => continue,
                };
                // Offsets of every match in this file's content.
                let offsets: Vec<usize> = match q.re {
                    Some(rx) => rx.find_iter(content).map(|m| m.start()).collect(),
                    None => {
                        let vneedle: &[u8] = if q.case_sensitive { q.needle } else { q.folded };
                        df_content::lines::literal_match_offsets(content, vneedle, q.case_sensitive)
                    }
                };
                let mut seen: HashSet<u32> = HashSet::new();
                for off in offsets {
                    if let Some(n) = q.context {
                        let (first, block) = df_content::lines::context_block(content, off, n);
                        if seen.insert(first) {
                            out.push(LineHit {
                                path: path.clone(),
                                line_no: first,
                                text: block,
                            });
                        }
                    } else {
                        let no = df_content::lines::line_number(content, off);
                        if seen.insert(no) {
                            out.push(LineHit {
                                path: path.clone(),
                                line_no: no,
                                text: df_content::lines::line_text(content, off),
                            });
                        }
                    }
                }
            }
        }
        out
    }

    /// Run a content query across all shards. Returns (path, meta, Content) for
    /// each in-scope verified match. `ShardReader` is opened on demand per shard
    /// (avoids storing a borrowing reader next to its owning mmap).
    fn query(
        &self,
        folded: &[u8],
        needle: &[u8],
        case_sensitive: bool,
        scope: Option<&Path>,
        per_shard_limit: Option<u32>,
    ) -> Vec<(String, LiteMeta, MatchKind)> {
        let mut out = Vec::new();
        for src in &self.sources {
            let r = match ShardReader::open(src.as_slice()) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let docids =
                candidates(&r, folded, needle, case_sensitive, per_shard_limit).unwrap_or_default();
            for d in docids {
                let path = match r.path(d) {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                if !in_scope(&path, scope) {
                    continue;
                }
                let meta = r.meta(d).unwrap_or_default();
                out.push((path, meta, MatchKind::Content));
            }
        }
        out
    }
}

/// Open `db_path` (+ the content shard set beside it), bind `socket_path`, serve
/// until a shutdown signal, then drain + remove the socket.
pub async fn serve(socket_path: &Path, db_path: &Path) -> std::io::Result<()> {
    let src = FileSource::open(db_path)?;
    let reader = DbReader::open(src).map_err(std::io::Error::other)?;
    let db = Arc::new(reader);

    let content_dir = db_path
        .parent()
        .map(|p| p.join("content"))
        .unwrap_or_else(|| PathBuf::from("content"));
    let shards = Arc::new(ContentShards::open(&content_dir));

    tracing::info!(
        socket = ?socket_path,
        db = ?db_path,
        shards = shards.sources.len(),
        "deepfindd listening"
    );

    if let Some(dir) = socket_path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    let _ = tokio::fs::remove_file(socket_path).await; // clear stale socket
    let listener = UnixListener::bind(socket_path)?;

    let mut join_set: JoinSet<()> = JoinSet::new();
    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            _ = &mut shutdown => {
                tracing::info!("shutdown signal received, draining connections");
                break;
            }
            res = listener.accept() => {
                // Transient accept errors must not tear down the daemon.
                let (stream, _) = match res {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::warn!(error = %e, "accept failed; continuing");
                        continue;
                    }
                };
                let db = db.clone();
                let shards = shards.clone();
                join_set.spawn(async move {
                    if let Err(e) = handle_conn(stream, db, shards).await {
                        tracing::warn!("connection error: {e}");
                    }
                });
            }
        }
    }

    // Graceful drain: let in-flight queries finish up to DRAIN_TIMEOUT, then
    // abort stragglers (queries are short; this bounds shutdown latency).
    drop(listener);
    let _ = tokio::time::timeout(DRAIN_TIMEOUT, async {
        while join_set.join_next().await.is_some() {}
    })
    .await;
    join_set.shutdown().await;
    let _ = tokio::fs::remove_file(socket_path).await;
    tracing::info!("deepfindd stopped");
    Ok(())
}

async fn handle_conn(
    stream: UnixStream,
    db: Arc<DbReader<FileSource>>,
    shards: Arc<ContentShards>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut f = framed(stream);

    // Read exactly one request frame.
    let req_bytes: Bytes = match f.next().await {
        Some(Ok(b)) => b.freeze(),
        _ => return Ok(()),
    };
    let req: SearchRequest = decode_request(&req_bytes)?;

    let query_str = req.query.clone();
    let scope: Option<PathBuf> = req.scope.clone();
    let limit = req.limit;
    let opts = req.opts.clone();
    // When scoping, fetch all matches then filter+cap so `limit` counts in-scope.
    let eff_limit = if scope.is_some() { None } else { limit };

    // Resolve smart-case from the raw query/regex pattern once: any ASCII
    // uppercase ⇒ case-sensitive (overridden by explicit -i / -s in opts.case).
    let case_sensitive = opts.case.sensitive(&query_str);

    // Filename-regex mode (`--regex`): the query is a regex matched against
    // paths. Its longest literal atom drives candidate generation; the compiled
    // regex verifies. The content layer is skipped in regex mode. The regex is
    // case-insensitive unless smart-case / -s made the search case-sensitive.
    let re = match &opts.regex {
        Some(r) => {
            let pat = if case_sensitive {
                r.clone()
            } else {
                format!("(?i){r}")
            };
            Some(
                regex::Regex::new(&pat)
                    .map_err(|e| std::io::Error::other(format!("bad regex: {e}")))?,
            )
        }
        None => None,
    };
    let regex_mode = re.is_some();
    // Content regex uses the byte-oriented engine (content is raw bytes); the
    // filename regex above uses the str engine (paths are UTF-8). Same pattern +
    // smart-case `(?i)` conditioning.
    let re_content = match &opts.regex {
        Some(r) => {
            let pat = if case_sensitive {
                r.clone()
            } else {
                format!("(?i){r}")
            };
            Some(
                regex::bytes::Regex::new(&pat)
                    .map_err(|e| std::io::Error::other(format!("bad regex: {e}")))?,
            )
        }
        None => None,
    };
    let needle = match &opts.regex {
        Some(r) => df_ipc::filter::longest_literal_atom(r).unwrap_or_default(),
        None => query_str.clone(),
    };
    // In regex mode the atom is only a candidate prefilter (regex.is_match is
    // authoritative), so keep it case-insensitive to avoid false negatives. In
    // literal mode the resolved smart-case flag applies to both layers.
    let fn_case = if regex_mode { false } else { case_sensitive };

    // Engine work off the async pool: filename DocIDs + content matches.
    let db_q = db.clone();
    let shards_q = shards.clone();
    let folded = df_content::fold::fold(needle.to_lowercase().as_bytes());

    // Line-number / context mode (`-n` / `-C`): render content matches as
    // grep-style line hits and stream them as `Lines` frames, then return.
    if opts.line_numbers || opts.context.is_some() {
        let folded_l = folded.clone();
        let needle_l = needle.clone();
        let scope_l = scope.clone();
        let re_l = re_content.clone();
        let ctx = opts.context;
        let shards_l = shards.clone();
        let hits = tokio::task::spawn_blocking(move || {
            let q = LineQuery {
                folded: &folded_l,
                needle: needle_l.as_bytes(),
                case_sensitive,
                re: re_l.as_ref(),
                scope: scope_l.as_deref(),
                limit,
                context: ctx,
            };
            shards_l.query_lines(&q)
        })
        .await?;
        let total = hits.len() as u32;
        for chunk in hits.chunks(STREAM_CHUNK) {
            f.send(encode_frame(&ResponseFrame::Lines {
                hits: chunk.to_vec(),
            })?)
            .await?;
        }
        f.send(encode_frame(&ResponseFrame::Done { total })?)
            .await?;
        return Ok(());
    }

    let folded_c = folded.clone();
    let scope_c = scope.clone();
    let needle_c = needle.clone();
    let (fn_docids, content_matches) = tokio::task::spawn_blocking(move || {
        let fn_docids = query_docids(&db_q, &needle_c, fn_case, eff_limit).unwrap_or_default();
        let content = match re_content.as_ref() {
            // Regex mode: the longest-literal-atom prefilters candidates; the
            // compiled byte regex verifies over the mmap'd content bytes.
            Some(re) => shards_q.query_regex(&folded_c, re, scope_c.as_deref(), limit),
            None => shards_q.query(
                &folded_c,
                needle_c.as_bytes(),
                case_sensitive,
                scope_c.as_deref(),
                limit,
            ),
        };
        (fn_docids, content)
    })
    .await?;

    // Merge filename + content by path. Filename DocIDs resolved in chunks.
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    // With filters active, collect all matches then filter+truncate to `cap`;
    // without filters, cap the merge early (efficient).
    let merge_cap = if opts.extensions.is_empty()
        && opts.types.is_empty()
        && opts.excludes.is_empty()
        && opts.globs.is_empty()
        && opts.max_depth.is_none()
    {
        cap
    } else {
        usize::MAX
    };
    let mut merged: HashMap<String, (LiteMeta, MatchKind)> = HashMap::new();

    for chunk in fn_docids.chunks(STREAM_CHUNK) {
        if merged.len() >= merge_cap {
            break;
        }
        let chunk: Vec<u32> = chunk.to_vec();
        let db_r = db.clone();
        let scope_r = scope.clone();
        let batch = tokio::task::spawn_blocking(move || {
            let mut out = Vec::new();
            for &d in &chunk {
                let path = match db_r.doc_path(d) {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                if !in_scope(&path, scope_r.as_deref()) {
                    continue;
                }
                let meta = db_r.doc_meta(d).unwrap_or_default();
                out.push((path, meta));
            }
            out
        })
        .await?;
        for (path, meta) in batch {
            merge_in(&mut merged, path, meta, MatchKind::Filename, merge_cap);
        }
    }
    for (path, meta, kind) in content_matches {
        merge_in(&mut merged, path, meta, kind, merge_cap);
    }

    // Apply post-query filters (-e/-t/-E), then cap to `limit`.
    let mut entries: Vec<(String, LiteMeta, MatchKind)> = merged
        .into_iter()
        .filter(|(p, _)| df_ipc::filter::passes(p, &opts))
        .filter(|(p, (_, k))| {
            // The path-regex verify gates only FILENAME matches (Both already
            // passed it via the filename layer); content matches are verified by
            // the byte regex in `query_regex`, so their paths need not match.
            if matches!(k, MatchKind::Filename) {
                re.as_ref().is_none_or(|r| r.is_match(p))
            } else {
                true
            }
        })
        .map(|(p, (m, k))| (p, m, k))
        .collect();
    entries.truncate(cap);
    let mut total: u32 = 0;
    for chunk in entries.chunks(STREAM_CHUNK) {
        let mut paths = Vec::with_capacity(chunk.len());
        let mut meta = Vec::with_capacity(chunk.len());
        let mut kind = Vec::with_capacity(chunk.len());
        for (p, m, k) in chunk {
            paths.push(p.clone());
            meta.push(m.clone());
            kind.push(*k);
        }
        f.send(encode_frame(&ResponseFrame::Batch { paths, meta, kind })?)
            .await?;
        total += chunk.len() as u32;
    }
    f.send(encode_frame(&ResponseFrame::Done { total })?)
        .await?;
    Ok(())
}

/// Insert/merge a match into the dedup map. Filename + Content on same path → Both.
fn merge_in(
    map: &mut HashMap<String, (LiteMeta, MatchKind)>,
    path: String,
    meta: LiteMeta,
    kind: MatchKind,
    cap: usize,
) {
    if map.len() >= cap && !map.contains_key(&path) {
        return;
    }
    match map.get_mut(&path) {
        Some((_, existing)) => *existing = combine_kind(*existing, kind),
        None => {
            map.insert(path, (meta, kind));
        }
    }
}

fn combine_kind(a: MatchKind, b: MatchKind) -> MatchKind {
    use MatchKind as M;
    match (a, b) {
        (M::Filename, M::Content) | (M::Content, M::Filename) | (M::Both, _) | (_, M::Both) => {
            M::Both
        }
        _ => b,
    }
}
