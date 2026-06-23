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

/// One loaded DB: the filename reader + its content shards, named.
struct DbEntry {
    name: String,
    db: Arc<DbReader<FileSource>>,
    shards: Arc<ContentShards>,
}

/// The set of DBs a daemon serves: the default DB (the one `serve` was handed)
/// plus every registered named DB. A query loops the selected entries and merges
/// by path (cross-DB dedup is path-keyed, so no global docid mapping is needed).
struct DbSet {
    entries: Vec<DbEntry>,
}

impl DbSet {
    /// Open the default DB at `db_path` plus every DB in the registry beside it.
    /// The registry dir is two levels up from `db_path` (the `data/db/index.dfdb`
    /// layout ⇒ `data/`); absent or unreadable DBs are skipped.
    fn open(db_path: &Path) -> Self {
        let mut entries = Vec::new();

        // Default DB.
        if let Some(e) = open_entry("default", db_path) {
            entries.push(e);
        }

        // Registered named DBs. Registry lives at <data_dir>/dbs.toml, where
        // <data_dir> is two levels above the default db file.
        let registry_dir = db_path
            .parent()
            .and_then(Path::parent)
            .unwrap_or_else(|| Path::new("."));
        let reg = df_index::Registry::load(registry_dir);
        for rec in &reg.records {
            if let Some(e) = open_entry(&rec.name, &rec.db_path) {
                entries.push(e);
            }
        }

        Self { entries }
    }

    /// Entries to query: all of them, or just the named one if `name` is set.
    fn select<'a>(&'a self, name: Option<&str>) -> Vec<&'a DbEntry> {
        match name {
            Some(n) => self.entries.iter().filter(|e| e.name == n).collect(),
            None => self.entries.iter().collect(),
        }
    }

    /// Entries whose name is in `names` (used to resume a selection inside a
    /// `spawn_blocking` that owns its own `Arc<DbSet>` borrow).
    fn select_named<'a>(&'a self, names: &[String]) -> Vec<&'a DbEntry> {
        self.entries
            .iter()
            .filter(|e| names.contains(&e.name))
            .collect()
    }
}

/// Open one DB entry by its `index.dfdb` path (content shards beside it). `None`
/// if the DB is missing/unreadable (e.g. registry points at a not-yet-built DB).
fn open_entry(name: &str, db_path: &Path) -> Option<DbEntry> {
    let src = FileSource::open(db_path).ok()?;
    let db = DbReader::open(src).ok()?;
    let content_dir = db_path
        .parent()
        .map(|p| p.join("content"))
        .unwrap_or_else(|| PathBuf::from("content"));
    let shards = Arc::new(ContentShards::open(&content_dir));
    Some(DbEntry {
        name: name.to_string(),
        db: Arc::new(db),
        shards,
    })
}

/// Shared, read-only query context for one search (carried across DB entries).
struct QueryCtx<'a> {
    folded: &'a [u8],
    needle: &'a str,
    case_sensitive: bool,
    fn_case: bool,
    re_content: Option<&'a regex::bytes::Regex>,
    scope: Option<&'a Path>,
    eff_limit: Option<u32>,
    limit: Option<u32>,
    want_fn: bool,
    want_ct: bool,
    path_mode: df_ipc::proto::PathMode,
}

/// Filename + content query for ONE DB entry, merged by path. The building block
/// the multi-DB loop calls per entry; handle_conn merges the per-entry maps.
fn query_entry(
    ctx: &QueryCtx,
    entry: &DbEntry,
    merge_cap: usize,
) -> HashMap<String, (LiteMeta, MatchKind)> {
    let mut merged: HashMap<String, (LiteMeta, MatchKind)> = HashMap::new();

    // Filename layer.
    if ctx.want_fn {
        let fn_docids =
            query_docids(&entry.db, ctx.needle, ctx.fn_case, ctx.eff_limit).unwrap_or_default();
        for d in fn_docids {
            if merged.len() >= merge_cap {
                break;
            }
            let path = match entry.db.doc_path(d) {
                Ok(p) => p,
                Err(_) => continue,
            };
            if !in_scope(&path, ctx.scope) {
                continue;
            }
            if ctx.path_mode == df_ipc::proto::PathMode::Basename {
                let bn = path.rsplit('/').next().unwrap_or(&path);
                let hit = if ctx.fn_case {
                    bn.contains(ctx.needle)
                } else {
                    bn.to_lowercase().contains(&ctx.needle.to_lowercase())
                };
                if !hit {
                    continue;
                }
            }
            let meta = entry.db.doc_meta(d).unwrap_or_default();
            merge_in(&mut merged, path, meta, MatchKind::Filename, merge_cap);
        }
    }

    // Content layer.
    if ctx.want_ct {
        let content = match ctx.re_content {
            Some(re) => entry
                .shards
                .query_regex(ctx.folded, re, ctx.scope, ctx.limit),
            None => entry.shards.query(
                ctx.folded,
                ctx.needle.as_bytes(),
                ctx.case_sensitive,
                ctx.scope,
                ctx.limit,
            ),
        };
        for (path, meta, kind) in content {
            merge_in(&mut merged, path, meta, kind, merge_cap);
        }
    }

    merged
}

/// Open `db_path` (+ the content shard set beside it), bind `socket_path`, serve
/// until a shutdown signal, then drain + remove the socket.
pub async fn serve(socket_path: &Path, db_path: &Path) -> std::io::Result<()> {
    let dbset = Arc::new(DbSet::open(db_path));
    if dbset.entries.is_empty() {
        return Err(std::io::Error::other(format!(
            "no index DB found at {} (run 'deepfind index')",
            db_path.display()
        )));
    }

    tracing::info!(
        socket = ?socket_path,
        db = ?db_path,
        dbs = dbset.entries.len(),
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
                let dbset = dbset.clone();
                join_set.spawn(async move {
                    if let Err(e) = handle_conn(stream, dbset).await {
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
    dbset: Arc<DbSet>,
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

    let folded = df_content::fold::fold(needle.to_lowercase().as_bytes());
    let want_fn = opts.layers.filename;
    let want_ct = opts.layers.content;

    // Select the DB entry/entries to query (`--db <name>` or all).
    let selected: Vec<String> = dbset
        .select(req.db.as_deref())
        .into_iter()
        .map(|e| e.name.clone())
        .collect();

    // Line-number / context mode (`-n` / `-C`): render content matches as
    // grep-style line hits and stream them as `Lines` frames, then return.
    if opts.line_numbers || opts.context.is_some() {
        let folded_l = folded.clone();
        let needle_l = needle.clone();
        let scope_l = scope.clone();
        let re_l = re_content.clone();
        let ctx = opts.context;
        let dbset_l = dbset.clone();
        let selected_l = selected.clone();
        let hits = tokio::task::spawn_blocking(move || {
            let mut all = Vec::new();
            for entry in dbset_l.select_named(&selected_l) {
                let q = LineQuery {
                    folded: &folded_l,
                    needle: needle_l.as_bytes(),
                    case_sensitive,
                    re: re_l.as_ref(),
                    scope: scope_l.as_deref(),
                    limit,
                    context: ctx,
                };
                all.extend(entry.shards.query_lines(&q));
            }
            all
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

    // Path-batch mode: query each selected DB entry, merge by path across DBs.
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

    let folded_q = folded.clone();
    let needle_q = needle.clone();
    let scope_q = scope.clone();
    let re_content_q = re_content.clone();
    let path_mode_q = opts.path_mode;
    let dbset_q = dbset.clone();
    let selected_q = selected.clone();
    let merged = tokio::task::spawn_blocking(move || {
        let ctx = QueryCtx {
            folded: &folded_q,
            needle: &needle_q,
            case_sensitive,
            fn_case,
            re_content: re_content_q.as_ref(),
            scope: scope_q.as_deref(),
            eff_limit,
            limit,
            want_fn,
            want_ct,
            path_mode: path_mode_q,
        };
        let mut merged: HashMap<String, (LiteMeta, MatchKind)> = HashMap::new();
        for entry in dbset_q.select_named(&selected_q) {
            let per = query_entry(&ctx, entry, merge_cap);
            for (path, (meta, kind)) in per {
                merge_in(&mut merged, path, meta, kind, merge_cap);
            }
        }
        merged
    })
    .await?;

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
    sort_entries(&mut entries, opts.sort);
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

/// Order `entries` per `mode`. `Default` = (kind weight, path depth, path) —
/// best matches first, deterministic and reproducible.
fn sort_entries(entries: &mut [(String, LiteMeta, MatchKind)], mode: df_ipc::proto::SortMode) {
    use df_ipc::proto::SortMode as S;
    match mode {
        S::None => {}
        S::Path => entries.sort_by(|a, b| a.0.cmp(&b.0)),
        S::Kind => entries.sort_by_key(|(_, _, k)| kind_weight(*k)),
        S::Default => entries.sort_by(|a, b| {
            kind_weight(a.2)
                .cmp(&kind_weight(b.2))
                .then_with(|| depth_of(&a.0).cmp(&depth_of(&b.0)))
                .then_with(|| a.0.cmp(&b.0))
        }),
    }
}

/// Best-match-first weight: Both (0) < Content (1) < Filename (2).
fn kind_weight(k: MatchKind) -> u8 {
    match k {
        MatchKind::Both => 0,
        MatchKind::Content => 1,
        MatchKind::Filename => 2,
    }
}

/// Path depth = separator count from the index root (leading `./` stripped).
fn depth_of(path: &str) -> u32 {
    let p = path.strip_prefix("./").unwrap_or(path);
    p.matches('/').count() as u32
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
