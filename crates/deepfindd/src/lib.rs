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

use arc_swap::ArcSwap;
use bytes::Bytes;
use df_content::{Overlay, ShardReader, WalRecord};
use df_core::candidate::candidates;
use df_core::db::DbReader;
use df_core::{in_scope, query_docids, LiteMeta};
use df_index::{replay_overlay, FileSource, MmapSource, OverlayStore};
use df_ipc::proto::{IndexRequest, LineHit, MatchKind, Request, ResponseFrame};
use df_ipc::{decode_request, encode_frame, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::JoinSet;

mod singleton;

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

/// The mmap'd content shard set, opened once at startup from the MANIFEST. The
/// set lives behind an [`ArcSwap`]: a rebuild builds NEW shard files and calls
/// [`ContentShards::reload`], which atomically swaps the snapshot. In-flight
/// queries hold an `Arc` clone of the old snapshot (via [`Self::snapshot`]); on
/// Unix the atomic-rename-over preserves the old inode, so reading through the
/// old mmap stays valid — no SIGBUS — until the old `Arc` drops.
struct ContentShards {
    content_dir: PathBuf,
    shards: arc_swap::ArcSwap<Vec<Arc<MmapSource>>>,
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

/// Load the shard mmap set listed in `content_dir/MANIFEST`.
fn load_shard_set(content_dir: &Path) -> Vec<Arc<MmapSource>> {
    let mut set = Vec::new();
    if let Some(manifest) = df_index::Manifest::read(&content_dir.join("MANIFEST")) {
        for entry in &manifest.shards {
            let path = content_dir.join(&entry.file);
            if let Ok(src) = MmapSource::open(&path) {
                set.push(Arc::new(src));
            }
        }
    }
    set
}

impl ContentShards {
    /// Open every shard listed in `content_dir/MANIFEST`. Empty if absent.
    fn open(content_dir: &Path) -> Self {
        Self {
            content_dir: content_dir.to_path_buf(),
            shards: arc_swap::ArcSwap::from_pointee(load_shard_set(content_dir)),
        }
    }

    /// A stable `Arc` snapshot of the current shard set. Hold this for the whole
    /// query so the mmaps stay mapped (the set can be swapped concurrently).
    fn snapshot(&self) -> Arc<Vec<Arc<MmapSource>>> {
        self.shards.load_full()
    }

    /// The content-dir path (used by the df-watch watcher to rebuild).
    pub(crate) fn content_dir(&self) -> &Path {
        &self.content_dir
    }

    /// Re-read the shard set from disk and atomically swap it in. Old shards stay
    /// mapped (via any outstanding snapshot `Arc`) until their queries finish.
    fn reload(&self) {
        self.shards
            .store(Arc::new(load_shard_set(&self.content_dir)));
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
        let snap = self.snapshot();
        for src in snap.iter() {
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
        let snap = self.snapshot();
        for src in snap.iter() {
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
        let snap = self.snapshot();
        for src in snap.iter() {
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

/// Rebuild a DB's content index from `root` and atomically hot-swap its shards.
/// The df-watch watcher calls this on change events; `--force` rebuild uses the
/// same path. Because it goes through [`ContentShards::reload`] (ArcSwap), the
/// daemon keeps serving the OLD snapshot while the rebuild runs and until every
/// in-flight query on it finishes — no offline window, no SIGBUS.
/// Rebuild the cold index + hot-swap the shards WITHOUT touching the overlay
/// (the safety-net periodic rebuild uses this — it refreshes the cold layer but
/// keeps overlay changes that arrived during the rebuild). Compaction uses
/// [`compact_and_swap`] instead (rebuild + clear).
pub(crate) fn rebuild_and_swap(
    root: &Path,
    db_path: &Path,
    content_dir: &Path,
    shards: &ContentShards,
    dbset: &Arc<ArcSwap<DbSet>>,
    default_db_path: &Path,
) -> std::io::Result<()> {
    // Acquire the build marker so this df-watch rebuild can't race an on-demand
    // or startup build — two builds writing the same shard names would corrupt
    // each other's output. If a build is in flight, skip this cycle; the
    // in-flight build is fresher and df-watch will catch the next change event.
    let Some(_guard) = index_job::try_acquire(db_path) else {
        tracing::info!(root = ?root, "df-watch: build in flight; skipping this rebuild");
        return Ok(());
    };
    index_job::tracked_build(root, db_path, content_dir, &Default::default())
        .map_err(|e| std::io::Error::other(format!("rebuild: {e}")))?;
    shards.reload();
    // Reload the filename layer (DbReader) from the rebuilt index, reusing the
    // live shard + overlay handles so a running df-watch watcher isn't orphaned.
    // Without this the filename layer stays stale (content shards alone reload).
    reload_dbset_reusing_handles(dbset, default_db_path);
    Ok(())
}

/// Reload the filename layer of the live `DbSet` from disk after a compaction or
/// safety-net rebuild, while reusing each entry's existing `shards` + `overlay`
/// handles — so a df-watch watcher that captured those handles at spawn keeps
/// updating the very handles queries read (no orphan). Mirrors the full reload
/// `spawn_build` does, but preserves the hot handles via `reuse_handles_from`.
fn reload_dbset_reusing_handles(dbset: &Arc<ArcSwap<DbSet>>, default_db_path: &Path) {
    let old = dbset.load_full();
    let mut fresh = DbSet::open(default_db_path);
    fresh.reuse_handles_from(&old);
    dbset.store(Arc::new(fresh));
}

/// Default safety-net rebuild interval (once per day). Override with
/// `DEEPFIND_SAFETY_NET_SECS` (for tuning / tests).
const SAFETY_NET_SECS: u64 = 24 * 60 * 60;

/// Background thread that periodically rebuilds every rooted DB via
/// [`rebuild_and_swap`] — the LSM "safety net" that recovers from missed changes
/// without relying on df-watch/FSEvents. Runs for the daemon's lifetime.
fn spawn_safety_net(dbset: Arc<ArcSwap<DbSet>>, default_db_path: PathBuf) {
    std::thread::spawn(move || loop {
        let interval = std::env::var("DEEPFIND_SAFETY_NET_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|&s| s > 0)
            .unwrap_or(SAFETY_NET_SECS);
        std::thread::sleep(Duration::from_secs(interval));
        let snap = dbset.load_full();
        let mut rebuilt = 0;
        for e in &snap.entries {
            if let Some(root) = &e.root {
                if let Err(e) = rebuild_and_swap(
                    root,
                    &e.db_path,
                    e.shards.content_dir(),
                    &e.shards,
                    &dbset,
                    &default_db_path,
                ) {
                    tracing::warn!(error = %e, root = ?root, "safety-net rebuild failed");
                } else {
                    rebuilt += 1;
                }
            }
        }
        if rebuilt > 0 {
            tracing::info!(rebuilt, "safety-net rebuild cycle complete");
        }
    });
}

/// Compaction: a full rebuild that subsumes the overlay, then clear the overlay
/// and truncate its WAL. Acquires the build marker and skips if a build is
/// already in flight (the in-flight build is fresher; the overlay keeps
/// absorbing until next time), so it can't race an on-demand/startup build
/// writing the same shard names.
pub(crate) fn compact_and_swap(
    root: &Path,
    db_path: &Path,
    content_dir: &Path,
    shards: &ContentShards,
    overlay: &OverlayHandle,
    dbset: &Arc<ArcSwap<DbSet>>,
    default_db_path: &Path,
) {
    let Some(_guard) = index_job::try_acquire(db_path) else {
        tracing::info!(root = ?root, "compaction: build in flight; skipping");
        return;
    };
    match index_job::tracked_build(root, db_path, content_dir, &Default::default()) {
        Ok(_) => {
            shards.reload();
            overlay.clear();
            // Reload the filename layer from the rebuilt index (content shards
            // alone were reloaded above), reusing the live shard + overlay handles
            // so df-watch isn't orphaned. Without this, filename hits stay stale.
            reload_dbset_reusing_handles(dbset, default_db_path);
            tracing::info!(root = ?root, "compaction complete; overlay cleared");
        }
        Err(e) => tracing::warn!(error = %e, root = ?root, "compaction rebuild failed"),
    }
}

/// The hot overlay for one DB: an [`ArcSwap`]'d [`Overlay`] (queries take a
/// snapshot via [`Self::snapshot`]) backed by a persisted WAL ([`OverlayStore`])
/// that the df-watch loop appends to. Mirrors the `ContentShards` pattern so an
/// overlay update is atomic w.r.t. in-flight queries. `store` is `None` only if
/// the WAL could not be opened (degraded: in-memory overlay, not persisted).
struct OverlayHandle {
    data: ArcSwap<Overlay>,
    store: Option<OverlayStore>,
}

impl OverlayHandle {
    /// Open the WAL at `wal_path`, replay it into an overlay, and hold the store
    /// for future appends. Best-effort: WAL open failure degrades to read-only.
    fn open(wal_path: &Path) -> Self {
        let recs = replay_overlay(wal_path).unwrap_or_default();
        let mut o = Overlay::default();
        o.apply_records(&recs);
        if !recs.is_empty() {
            tracing::info!(wal = ?wal_path, recs = recs.len(), "overlay replayed");
        }
        let store = match OverlayStore::open(wal_path) {
            Ok(s) => Some(s),
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    wal = ?wal_path,
                    "overlay WAL open failed; overlay is in-memory only"
                );
                None
            }
        };
        Self {
            data: ArcSwap::from_pointee(o),
            store,
        }
    }

    /// A stable snapshot for the duration of one query (mirrors shard snapshot).
    fn snapshot(&self) -> Arc<Overlay> {
        self.data.load_full()
    }

    /// Current entry count (compaction trigger).
    fn len(&self) -> usize {
        self.data.load_full().len()
    }

    /// Append `recs` to the WAL (fsynced) and publish a new overlay snapshot
    /// (clone → apply → ArcSwap::store). Publishes once per batch, not per event.
    /// If the WAL is missing (degraded mode) the in-memory overlay still updates.
    fn record_and_apply(&self, recs: &[WalRecord]) {
        if let Some(store) = &self.store {
            for r in recs {
                if let Err(e) = store.append(r) {
                    tracing::warn!(error = %e, "overlay WAL append failed");
                }
            }
            if let Err(e) = store.sync() {
                tracing::warn!(error = %e, "overlay WAL sync failed");
            }
        }
        let mut next = (*self.data.load_full()).clone();
        next.apply_records(recs);
        self.data.store(Arc::new(next));
    }

    /// Compaction: the rebuild subsumed the overlay — drop it + truncate the WAL.
    fn clear(&self) {
        if let Some(store) = &self.store {
            if let Err(e) = store.truncate() {
                tracing::warn!(error = %e, "overlay WAL truncate failed");
            }
        }
        self.data.store(Arc::new(Overlay::default()));
    }
}

/// One loaded DB: the filename reader + its content shards, named. `root` is the
/// indexed source (from the registry) — present for registered DBs, used by the
/// df-watch incremental watcher; `None` for the default DB (no incremental).
struct DbEntry {
    name: String,
    root: Option<PathBuf>,
    pub(crate) db_path: PathBuf,
    db: Arc<DbReader<FileSource>>,
    pub(crate) shards: Arc<ContentShards>,
    pub(crate) overlay: Arc<OverlayHandle>,
}

/// The set of DBs a daemon serves: the default DB (the one `serve` was handed)
/// plus every registered named DB. A query loops the selected entries and merges
/// by path (cross-DB dedup is path-keyed, so no global docid mapping is needed).
pub(crate) struct DbSet {
    entries: Vec<DbEntry>,
}

impl DbSet {
    /// Open the default DB at `db_path` plus every DB in the registry beside it.
    /// The registry dir is two levels up from `db_path` (the `data/db/index.dfdb`
    /// layout ⇒ `data/`); absent or unreadable DBs are skipped.
    pub(crate) fn open(db_path: &Path) -> Self {
        let mut entries = Vec::new();

        // Default DB.
        if let Some(e) = open_entry("default", db_path, None) {
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
            if let Some(e) = open_entry(&rec.name, &rec.db_path, Some(rec.root.clone())) {
                entries.push(e);
            }
        }

        Self { entries }
    }

    /// Reuse the live `shards` + `overlay` handles from `old` for entries that
    /// survived a registry reload (matched by `db_path`). A registry reload is
    /// for `dbs.toml` changes (db add/remove), NOT an index rebuild — the index
    /// files didn't change, so the existing handles (which df-watch captured at
    /// spawn and keeps updating) must be preserved, or df-watch would be left
    /// updating orphaned handles that queries no longer read.
    pub(crate) fn reuse_handles_from(&mut self, old: &DbSet) {
        for e in &mut self.entries {
            if let Some(o) = old.entries.iter().find(|o| o.db_path == e.db_path) {
                e.shards = o.shards.clone();
                e.overlay = o.overlay.clone();
            }
        }
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
/// `root` is the indexed source (for the df-watch watcher), if known.
fn open_entry(name: &str, db_path: &Path, root: Option<PathBuf>) -> Option<DbEntry> {
    let src = FileSource::open(db_path).ok()?;
    let db = DbReader::open(src).ok()?;
    let content_dir = db_path
        .parent()
        .map(|p| p.join("content"))
        .unwrap_or_else(|| PathBuf::from("content"));
    let shards = Arc::new(ContentShards::open(&content_dir));
    // Overlay WAL lives beside the index DB (sibling of `index.dfdb`), so it is
    // under the data dir and filtered by df-watch's self-write guard.
    let wal_path = db_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("overlay.wal");
    let overlay = Arc::new(OverlayHandle::open(&wal_path));
    Some(DbEntry {
        name: name.to_string(),
        root,
        db_path: db_path.to_path_buf(),
        db: Arc::new(db),
        shards,
        overlay,
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

/// Render the hot overlay's content matches as grep-style [`LineHit`]s (`-n` /
/// `-C`), mirroring `ContentShards::query_lines` over the overlay's in-memory
/// docs. Skips tombstoned, out-of-scope, and non-content-indexed docs.
fn overlay_line_hits(ov: &Overlay, q: &LineQuery) -> Vec<LineHit> {
    let cap = q.limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let mut out = Vec::new();
    let vneedle: &[u8] = if q.case_sensitive { q.needle } else { q.folded };
    for d in 0..ov.len() as u32 {
        if out.len() >= cap {
            break;
        }
        let Some(path) = ov.path(d).map(str::to_owned) else {
            continue;
        };
        if ov.tombstones().contains(path.as_str()) || !in_scope(&path, q.scope) {
            continue;
        }
        let Some(content) = ov.content(d) else {
            continue;
        };
        let offsets: Vec<usize> = match q.re {
            Some(rx) => rx.find_iter(content).map(|m| m.start()).collect(),
            None => df_content::lines::literal_match_offsets(content, vneedle, q.case_sensitive),
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
    out
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

    // Hot overlay (LSM read): first drop stale cold-layer hits for any path the
    // overlay shadows (upserted OR tombstoned — the cold version is stale), then
    // add the overlay's current results. The overlay is queried independently
    // and merged by path, exactly like the filename/content cold layers above.
    {
        let ov = entry.overlay.snapshot();
        if ov.shadows_anything() {
            merged.retain(|p, _| !ov.suppresses(p));
        }
        if ctx.want_fn {
            let basename = ctx.path_mode == df_ipc::proto::PathMode::Basename;
            for (path, meta) in ov.filename_query(ctx.needle, ctx.fn_case, basename, ctx.limit) {
                if !in_scope(&path, ctx.scope) {
                    continue;
                }
                override_in(&mut merged, path, meta, MatchKind::Filename, merge_cap);
            }
        }
        if ctx.want_ct {
            for (path, meta) in match ctx.re_content {
                Some(re) => ov.content_regex_hits(re, ctx.limit),
                None => ov.content_query(
                    ctx.folded,
                    ctx.needle.as_bytes(),
                    ctx.case_sensitive,
                    ctx.limit,
                ),
            } {
                if !in_scope(&path, ctx.scope) {
                    continue;
                }
                override_in(&mut merged, path, meta, MatchKind::Content, merge_cap);
            }
        }
    }

    merged
}

/// Open `db_path` (+ the content shard set beside it), bind `socket_path`, serve
/// until a shutdown signal, then drain + remove the socket.
pub async fn serve(socket_path: &Path, db_path: &Path) -> std::io::Result<()> {
    // Single-instance guard: hold an exclusive flock on <socket dir>/daemon.lock
    // for the daemon's lifetime. A second `deepfind daemon` (e.g. a manual start
    // racing launchd's KeepAlive respawn) bails here instead of binding a second
    // socket and fighting the live daemon over index writes. The kernel releases
    // the lock automatically if this process crashes, so there is never a stale
    // lock to clean up (unlike the socket file below).
    let _singleton = match singleton::acquire(&singleton::lock_path(socket_path)) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "deepfindd already running (singleton lock held)",
            ));
        }
        Err(e) => return Err(e),
    };

    // The DbSet lives behind an ArcSwap so it can be atomically replaced later
    // (background index builds → hot-swap, P2.2/P2.3). Connections take a
    // per-request snapshot via `load_full()`; here we take one for the startup
    // empty-check and df-watch spawn block.
    let dbset: Arc<ArcSwap<DbSet>> = Arc::new(ArcSwap::from_pointee(DbSet::open(db_path)));
    let initial = dbset.load_full();
    if initial.entries.is_empty() {
        tracing::warn!(db = ?db_path, "no index yet; serving empty until a background build swaps one in");
    }

    tracing::info!(
        socket = ?socket_path,
        db = ?db_path,
        dbs = initial.entries.len(),
        "deepfindd listening"
    );

    // df-watch (env-gated): for each registered DB with a known root, spawn an
    // incremental watcher that folds changes into the overlay (+ compaction).
    if std::env::var("DEEPFIND_WATCH").is_ok() {
        let max_file_size = df_index::ContentBuildOptions::default().max_file_size;
        for e in &initial.entries {
            if let Some(root) = &e.root {
                watch::spawn(
                    root.clone(),
                    e.db_path.clone(),
                    e.shards.content_dir().to_path_buf(),
                    e.shards.clone(),
                    e.overlay.clone(),
                    max_file_size,
                    dbset.clone(),
                    db_path.to_path_buf(),
                );
            }
        }
    }

    // Recover `.indexing` markers left by a previous daemon killed mid-build: at
    // startup no build is in flight in this process, so any marker on disk is
    // stale (otherwise `deepfind status` would report `indexing` forever).
    if let Some(db_dir) = db_path.parent() {
        index_job::sweep_stale_markers(db_dir);
    }

    // Background initial-index for registered DBs that have a root but no index
    // yet. Driven by the REGISTRY (not `initial.entries`, which by construction
    // excludes DBs whose index file is missing — the very case we're handling).
    let registry_dir = db_path
        .parent()
        .and_then(Path::parent)
        .unwrap_or_else(|| Path::new("."));
    for rec in &df_index::Registry::load(registry_dir).records {
        index_job::spawn_if_missing(
            rec.root.clone(),
            rec.db_path.clone(),
            rec.content_dir.clone(),
            dbset.clone(),
            db_path.to_path_buf(),
        );
    }

    // Registry watcher: reloads the DbSet when dbs.toml changes (e.g. `db add`),
    // so newly registered DBs are served without a daemon restart.
    registry_watcher::spawn(
        dbset.clone(),
        db_path.to_path_buf(),
        registry_dir.to_path_buf(),
    );

    // Safety-net periodic rebuild: independently of df-watch, rebuild every
    // rooted DB on a long interval to catch anything missed (daemon downtime,
    // lost/coalesced FSEvents, WAL corruption). Uses `rebuild_and_swap` (NOT
    // compaction) so the overlay is preserved — only the cold layer is refreshed.
    spawn_safety_net(dbset.clone(), db_path.to_path_buf());

    if let Some(dir) = socket_path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    // Safe under the singleton lock: no other daemon can be running, so any
    // socket file left here is stale (a previous crash), not a live peer's.
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
                let default_db_path = db_path.to_path_buf();
                join_set.spawn(async move {
                    if let Err(e) = handle_conn(stream, dbset, default_db_path).await {
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

/// Resolve an [`IndexRequest`] to a `(root, db_path, content_dir)` and kick off
/// a background build via [`index_job::spawn_build`]. Returns `(accepted,
/// message)`: `accepted = false` means a build was already in flight, or the
/// named DB is unknown. Pure resolve + spawn — all socket I/O stays in
/// [`handle_conn`].
fn handle_index_request(
    req: IndexRequest,
    dbset: &Arc<ArcSwap<DbSet>>,
    default_db_path: &Path,
) -> (bool, String) {
    let reg = df_index::Registry::load(&df_ipc::data_dir());
    let (root, db_path, content_dir): (PathBuf, PathBuf, PathBuf) = match req.db.as_deref() {
        Some(name) => match reg.records.iter().find(|r| r.name == name) {
            Some(r) => (r.root.clone(), r.db_path.clone(), r.content_dir.clone()),
            None => return (false, format!("no registered DB named '{name}'")),
        },
        None => {
            let root = req.root.unwrap_or_else(df_ipc::home);
            let db_path = default_db_path.to_path_buf();
            let content_dir = default_db_path
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join("content");
            (root, db_path, content_dir)
        }
    };
    let max_file_size = if req.max_file_size == 0 {
        df_index::ContentBuildOptions::default().max_file_size
    } else {
        req.max_file_size
    };
    let opts = df_index::ContentBuildOptions {
        max_file_size,
        extra_skip: req.skip,
        one_file_system: req.one_file_system,
        hidden: req.hidden,
    };
    let accepted = index_job::spawn_build(
        root,
        db_path,
        content_dir,
        opts,
        dbset.clone(),
        default_db_path.to_path_buf(),
    );
    let message = if accepted {
        "indexing in background; run 'deepfind status' for progress".to_string()
    } else {
        "already indexing".to_string()
    };
    (accepted, message)
}

async fn handle_conn(
    stream: UnixStream,
    dbset: Arc<ArcSwap<DbSet>>,
    default_db_path: PathBuf,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Snapshot the current DbSet once per connection. The rest of the function
    // operates on this `Arc<DbSet>` exactly as before — a hot-swap that lands
    // mid-connection does not affect this snapshot.
    let snapshot: Arc<DbSet> = dbset.load_full();
    let mut f = framed(stream);

    // Read exactly one request frame.
    let req_bytes: Bytes = match f.next().await {
        Some(Ok(b)) => b.freeze(),
        _ => return Ok(()),
    };
    let req: Request = decode_request(&req_bytes)?;
    let req = match req {
        Request::Search(s) => s,
        Request::Index(ir) => {
            let (accepted, message) = handle_index_request(ir, &dbset, &default_db_path);
            f.send(encode_frame(&ResponseFrame::IndexAck {
                accepted,
                message,
            })?)
            .await?;
            return Ok(());
        }
    };

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
    let selected: Vec<String> = snapshot
        .select(req.db.as_deref())
        .into_iter()
        .map(|e| e.name.clone())
        .collect();

    // If --db was specified but no registered DB matched, return an error
    // instead of silently producing empty results.
    if let Some(ref name) = req.db {
        if selected.is_empty() {
            let available: Vec<&str> = snapshot.entries.iter().map(|e| e.name.as_str()).collect();
            let msg = if available.is_empty() {
                "no registered DBs found; run 'deepfind db add <name> <root>' first".to_string()
            } else {
                format!(
                    "no registered DB named '{}'; available: {}",
                    name,
                    available.join(", ")
                )
            };
            f.send(encode_frame(&ResponseFrame::Error { message: msg })?)
                .await?;
            return Ok(());
        }
    }

    // Line-number / context mode (`-n` / `-C`): render content matches as
    // grep-style line hits and stream them as `Lines` frames, then return.
    if opts.line_numbers || opts.context.is_some() {
        let folded_l = folded.clone();
        let needle_l = needle.clone();
        let scope_l = scope.clone();
        let re_l = re_content.clone();
        let ctx = opts.context;
        let dbset_l = snapshot.clone();
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
                let ov = entry.overlay.snapshot();
                // Drop stale cold-layer line hits for any shadowed path before
                // adding the overlay's current hits (overlay_line_hits skips
                // tombstoned docs itself).
                if ov.shadows_anything() {
                    all.retain(|h| !ov.suppresses(&h.path));
                }
                all.extend(overlay_line_hits(&ov, &q));
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
    let dbset_q = snapshot.clone();
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

    // `--expr` (bfs): compile once, pre-resolve `-newer FILE` mtimes, then filter.
    let bfs_expr = opts
        .expr
        .as_deref()
        .and_then(|s| df_ipc::bfs::parse(s).ok());
    let mut newer_cache: HashMap<String, Option<i64>> = HashMap::new();
    if let Some(e) = &bfs_expr {
        for f in df_ipc::bfs::newer_files(e) {
            newer_cache.insert(f.clone(), file_mtime_secs(&f));
        }
    }

    // Apply post-query filters (-e/-t/-E/-expr), then cap to `limit`.
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
        .filter(|(p, (m, _))| match &bfs_expr {
            Some(e) => df_ipc::bfs::eval(e, p, m, &|file| newer_cache.get(file).copied().flatten()),
            None => true,
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

/// A file's mtime in seconds (for `-newer FILE`), or `None` if unstatable.
fn file_mtime_secs(path: &str) -> Option<i64> {
    use std::time::UNIX_EPOCH;
    std::fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

/// Overlay override: like [`merge_in`] but the incoming entry WINS (fresh meta),
/// combining `MatchKind` with any existing entry. Used by the hot overlay so a
/// changed file's current version supersedes the stale cold-layer hit on the
/// same path.
fn override_in(
    map: &mut HashMap<String, (LiteMeta, MatchKind)>,
    path: String,
    meta: LiteMeta,
    kind: MatchKind,
    cap: usize,
) {
    match map.get_mut(&path) {
        Some((m, k)) => {
            *m = meta;
            *k = combine_kind(*k, kind);
        }
        None => {
            if map.len() < cap {
                map.insert(path, (meta, kind));
            }
        }
    }
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

pub mod index_job;

pub(crate) mod watch {
    //! df-watch: a notify (FSEvents on macOS) watcher over a registered DB's
    //! root. Each change is folded into the hot overlay (WAL + in-memory
    //! ArcSwap), so mutations show up in queries without a full rebuild. When
    //! the overlay grows past [`COMPACTION_THRESHOLD`], a compaction rebuilds
    //! the cold shards and clears the overlay (LSM tiered model).

    use std::path::{Path, PathBuf};
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::time::Duration;

    use arc_swap::ArcSwap;
    use notify::{EventKind, RecursiveMode, Watcher};

    use crate::{compact_and_swap, ContentShards, DbSet, OverlayHandle, WalRecord};

    /// Coalesce event bursts before applying them to the overlay.
    const DEBOUNCE: Duration = Duration::from_millis(300);

    /// Overlay entry count at which a compaction (full rebuild) fires and clears
    /// it. Bounds memory + query-merge cost between compactions. Override with
    /// `DEEPFIND_COMPACTION_THRESHOLD` (for tuning / tests).
    fn compaction_threshold() -> usize {
        std::env::var("DEEPFIND_COMPACTION_THRESHOLD")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|&n| n > 0)
            .unwrap_or(2000)
    }

    /// Spawn a background watcher over `root`. On changes (debounced), fold the
    /// affected paths into `overlay`; compact when it grows too large. Runs for
    /// the daemon's lifetime; log-only on errors.
    #[allow(clippy::too_many_arguments)] // threads live handles + reload ctx straight through to `run`
    pub fn spawn(
        root: PathBuf,
        db_path: PathBuf,
        content_dir: PathBuf,
        shards: Arc<ContentShards>,
        overlay: Arc<OverlayHandle>,
        max_file_size: u64,
        dbset: Arc<ArcSwap<DbSet>>,
        default_db_path: PathBuf,
    ) {
        std::thread::spawn(move || {
            run(
                &root,
                &db_path,
                &content_dir,
                shards,
                overlay,
                max_file_size,
                dbset,
                default_db_path,
            )
        });
    }

    #[allow(clippy::too_many_arguments)] // matches `spawn`; same straight-through thread
    fn run(
        root: &Path,
        db_path: &Path,
        content_dir: &Path,
        shards: Arc<ContentShards>,
        overlay: Arc<OverlayHandle>,
        max_file_size: u64,
        dbset: Arc<ArcSwap<DbSet>>,
        default_db_path: PathBuf,
    ) {
        let (tx, rx) = mpsc::channel::<PathBuf>();
        // The index's own writes live under `~/.deep-finder`. Canonicalize so the
        // prefix match is robust against a symlinked `$HOME`; fall back to the
        // lexical path if canonicalization fails.
        let data_dir = df_ipc::data_dir()
            .canonicalize()
            .unwrap_or_else(|_| df_ipc::data_dir());
        // notify (FSEvents) reports CANONICAL event paths, but the cold shard
        // stores paths rooted at the LEXICAL build root (e.g. macOS `/var/…`
        // vs `/private/var/…`). Normalize event paths back to the lexical root so
        // overlay paths match the cold layer for suppression/override.
        let canon_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
        let mut watcher =
            match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                if let Ok(ev) = res {
                    // React only to real user changes: ignore pure reads, and ignore
                    // the daemon's own writes under the data dir — otherwise a watched
                    // root that contains `~/.deep-finder` feeds back forever
                    // (overlay write → event → overlay write → …).
                    if !matches!(ev.kind, EventKind::Access(_))
                        && !is_self_write(&ev.paths, &data_dir)
                    {
                        for p in ev.paths {
                            let _ = tx.send(p);
                        }
                    }
                }
            }) {
                Ok(w) => w,
                Err(e) => {
                    tracing::warn!(error = %e, root = ?root, "df-watch: watcher init failed");
                    return;
                }
            };
        if let Err(e) = watcher.watch(root, RecursiveMode::Recursive) {
            tracing::warn!(error = %e, root = ?root, "df-watch: watch failed");
            return;
        }
        tracing::info!(root = ?root, "df-watch: watching");
        // Debounce + overlay-update loop. `watcher` (and the sender it owns) stay
        // alive for the loop's duration; the loop exits only if the channel closes.
        while let Ok(first) = rx.recv() {
            let mut batch: Vec<PathBuf> = vec![first];
            while let Ok(p) = rx.try_recv() {
                batch.push(p);
            }
            std::thread::sleep(DEBOUNCE);
            while let Ok(p) = rx.try_recv() {
                batch.push(p);
            }
            let recs: Vec<WalRecord> = batch
                .iter()
                .map(|p| build_record(&lexify(p, root, &canon_root), max_file_size))
                .collect();
            overlay.record_and_apply(&recs);
            tracing::info!(root = ?root, paths = batch.len(), "df-watch: overlay updated");
            if overlay.len() >= compaction_threshold() {
                tracing::info!(root = ?root, n = overlay.len(), "df-watch: compaction threshold");
                compact_and_swap(
                    root,
                    db_path,
                    content_dir,
                    &shards,
                    &overlay,
                    &dbset,
                    &default_db_path,
                );
            }
        }
        drop(watcher);
    }

    /// Re-root a canonical event path onto the lexical build root (see `run`).
    /// If the event path isn't under `canon_root`, return it unchanged.
    fn lexify(event: &Path, lexical_root: &Path, canon_root: &Path) -> PathBuf {
        match event.strip_prefix(canon_root) {
            Ok(rel) => lexical_root.join(rel),
            Err(_) => event.to_path_buf(),
        }
    }

    /// Build the WAL record for one changed path: `Delete` if it no longer
    /// exists, else `Upsert` (content `None` for dirs / binary / oversized —
    /// filename-layer only, matching the build path's text gate).
    fn build_record(path: &Path, max_file_size: u64) -> WalRecord {
        let pstr = path.to_string_lossy().into_owned();
        let meta = match std::fs::metadata(path) {
            Ok(m) => m,
            Err(_) => return WalRecord::Delete { path: pstr },
        };
        let is_dir = meta.is_dir();
        let size = meta.len() as i64;
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let content = if is_dir {
            None
        } else {
            match df_index::content_build::classify(path, max_file_size) {
                df_index::content_build::ContentDecision::Text(b) => Some(b),
                _ => None,
            }
        };
        WalRecord::Upsert {
            path: pstr,
            meta: df_core::LiteMeta {
                is_dir,
                size,
                mtime,
            },
            content,
        }
    }

    /// True if any event path is inside the index data dir (`~/.deep-finder`) —
    /// the daemon's own overlay/log/socket writes. Such events must NOT feed the
    /// overlay: a watched root that *contains* the data dir would otherwise feed
    /// back into itself (overlay write → event → overlay write → …), looping.
    fn is_self_write(paths: &[PathBuf], data_dir: &Path) -> bool {
        paths.iter().any(|p| p.starts_with(data_dir))
    }

    #[cfg(test)]
    mod is_self_write_tests {
        use super::*;

        #[test]
        fn ignores_paths_inside_data_dir() {
            let data_dir = PathBuf::from("/root/.deep-finder");
            let shard = data_dir.join("db/w/content/shard-00000.dfcs");
            let dir_itself = PathBuf::from("/root/.deep-finder");
            assert!(is_self_write(&[shard], &data_dir));
            assert!(is_self_write(&[dir_itself], &data_dir)); // the dir itself counts
        }

        #[test]
        fn keeps_user_files_outside_data_dir() {
            // root contains the data dir, but the changed file is a real user file.
            let data_dir = PathBuf::from("/root/.deep-finder");
            assert!(!is_self_write(
                &[PathBuf::from("/root/trip.txt")],
                &data_dir
            ));
        }

        #[test]
        fn any_path_inside_flags_it() {
            let data_dir = PathBuf::from("/root/.deep-finder");
            assert!(is_self_write(
                &[
                    PathBuf::from("/root/a.txt"),
                    data_dir.join("logs/daemon.err.log")
                ],
                &data_dir,
            ));
        }

        #[test]
        fn empty_is_not_self_write() {
            assert!(!is_self_write(&[], Path::new("/root/.deep-finder")));
        }
    }
}

pub(crate) mod registry_watcher {
    //! Watches `dbs.toml` for changes. When the registry is modified (e.g. via
    //! `db add`), the watcher reloads the full DbSet from disk and atomically
    //! swaps it — no daemon restart needed. Newly registered DBs whose index is
    //! missing get a background build via `index_job::spawn_if_missing`.

    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::time::Duration;

    use arc_swap::ArcSwap;
    use notify::{EventKind, RecursiveMode, Watcher};

    use crate::{index_job, DbSet};

    const DEBOUNCE: Duration = Duration::from_millis(300);

    /// Spawn a background watcher on `<data_dir>/dbs.toml`. When the file changes
    /// (debounced), re-opens the full DbSet and atomically swaps it, then triggers
    /// background builds for any newly registered DBs that lack an index.
    pub fn spawn(dbset: Arc<ArcSwap<DbSet>>, default_db_path: PathBuf, data_dir: PathBuf) {
        std::thread::spawn(move || run(dbset, default_db_path, data_dir));
    }

    fn run(dbset: Arc<ArcSwap<DbSet>>, default_db_path: PathBuf, data_dir: PathBuf) {
        let dbs_toml = data_dir.join("dbs.toml");

        let (tx, rx) = mpsc::channel::<()>();
        let mut watcher =
            match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                if let Ok(ev) = res {
                    if !matches!(ev.kind, EventKind::Access(_)) {
                        let _ = tx.send(());
                    }
                }
            }) {
                Ok(w) => w,
                Err(e) => {
                    tracing::warn!(error = %e, "registry-watch: watcher init failed");
                    return;
                }
            };

        // Watch the containing directory (not the file directly) because editors
        // and `atomic_write` often replace the file via rename, which FSEvents
        // reports as a directory-level event.
        if let Err(e) = watcher.watch(&data_dir, RecursiveMode::NonRecursive) {
            tracing::warn!(error = %e, "registry-watch: watch failed");
            return;
        }
        tracing::info!(dir = ?data_dir, "registry-watch: watching dbs.toml");

        let mut last_mtime = None;
        while rx.recv().is_ok() {
            // Debounce: drain the burst, then wait.
            while rx.try_recv().is_ok() {}
            std::thread::sleep(DEBOUNCE);
            while rx.try_recv().is_ok() {}

            // Only react if dbs.toml exists — directory watcher fires for every
            // file in the data dir (socket, logs, etc.), not just dbs.toml.
            if !dbs_toml.exists() {
                continue;
            }

            // Skip if the mtime hasn't changed since last reload.
            let Ok(meta) = std::fs::metadata(&dbs_toml) else {
                continue;
            };
            let Ok(modified) = meta.modified() else {
                continue;
            };
            if last_mtime == Some(modified) {
                continue;
            }
            last_mtime = Some(modified);

            tracing::info!("registry-watch: reloading DbSet");
            let mut fresh = DbSet::open(&default_db_path);
            // Preserve live shard + overlay handles for surviving DBs so df-watch
            // (which captured them at spawn) keeps updating the handles queries read.
            let old = dbset.load_full();
            fresh.reuse_handles_from(&old);
            // Spawn background builds for any registered DBs still missing an index.
            for rec in &df_index::Registry::load(&data_dir).records {
                index_job::spawn_if_missing(
                    rec.root.clone(),
                    rec.db_path.clone(),
                    rec.content_dir.clone(),
                    dbset.clone(),
                    default_db_path.clone(),
                );
            }
            dbset.store(Arc::new(fresh));
        }
        drop(watcher);
    }
}

#[cfg(test)]
mod shard_hotswap_tests {
    //! F1: ArcSwap shard hot-swap is SIGBUS-safe. On Unix, `build_content_index`
    //! replaces a shard via atomic rename-over, which preserves the OLD inode; an
    //! outstanding snapshot's mmap maps that old inode, so it keeps reading valid
    //! bytes after the swap — no SIGBUS.

    use super::*;

    #[test]
    fn hot_swap_keeps_old_snapshot_valid() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let db = root.join("index.dfdb");
        let content_dir = root.join("content");

        std::fs::write(root.join("a.txt"), b"old content here").unwrap();
        df_index::build_content_index(root, &db, &content_dir, &Default::default()).unwrap();

        let cs = ContentShards::open(&content_dir);
        let snap_old = cs.snapshot();
        assert!(!snap_old.is_empty(), "expected at least one shard");
        let old_bytes = snap_old[0].as_slice().to_vec();

        // Rebuild with different content (atomic rename-over the shard file).
        std::fs::write(root.join("a.txt"), b"completely new and different content").unwrap();
        std::fs::write(root.join("b.txt"), b"another file").unwrap();
        df_index::build_content_index(root, &db, &content_dir, &Default::default()).unwrap();
        cs.reload();
        let snap_new = cs.snapshot();

        // The old snapshot still maps the pre-swap inode → unchanged, valid bytes.
        assert_eq!(snap_old[0].as_slice(), old_bytes.as_slice());
        // The new snapshot reflects the rebuild (different bytes).
        assert_ne!(snap_old[0].as_slice(), snap_new[0].as_slice());
    }
}

/// F4: after a rebuild+hot-swap, the daemon serves UPDATED content through the
/// normal query path (equivalent to a fresh `--force` rebuild — it IS one, just
/// triggered incrementally and swapped in without restart).
#[test]
fn rebuild_and_swap_serves_updated_content() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let db = root.join("index.dfdb");
    let content_dir = root.join("content");

    std::fs::write(root.join("a.txt"), b"needle here").unwrap();
    df_index::build_content_index(root, &db, &content_dir, &Default::default()).unwrap();
    let cs = ContentShards::open(&content_dir);
    let dbset: Arc<ArcSwap<DbSet>> = Arc::new(ArcSwap::from_pointee(DbSet::open(&db)));

    let folded = df_content::fold::fold(b"needle");
    let before: Vec<String> = cs
        .query(&folded, b"needle", false, None, None)
        .into_iter()
        .map(|(p, _, _)| p)
        .collect();
    assert!(before.iter().any(|p| p.ends_with("a.txt")));

    // Mutate: a.txt drops the needle; a new file gains it.
    std::fs::write(root.join("a.txt"), b"nothing relevant").unwrap();
    std::fs::write(root.join("b.txt"), b"needle now here").unwrap();
    rebuild_and_swap(root, &db, &content_dir, &cs, &dbset, &db).unwrap();

    let after: Vec<String> = cs
        .query(&folded, b"needle", false, None, None)
        .into_iter()
        .map(|(p, _, _)| p)
        .collect();
    assert!(
        after.iter().any(|p| p.ends_with("b.txt")),
        "after: {after:?}"
    );
    assert!(
        !after.iter().any(|p| p.ends_with("a.txt")),
        "after: {after:?}"
    );
}
