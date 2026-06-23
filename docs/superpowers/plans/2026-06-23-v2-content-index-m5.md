# DeepFinder v2 — M5 Daemon ShardSet + Combined Results Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) tracking.

**Goal:** Wire the content index into the daemon: open the `.dfcs` shard set at startup, run the daemon's query against BOTH the filename DB and the content shards, merge + dedup by path (a match in both layers = `Both`), and stream `Batch` frames carrying a per-match `MatchKind`.

**Architecture:** `deepfindd::serve` opens the filename `DbReader` (v1) AND a `ContentShards` (the mmap'd shard set from `content_dir/MANIFEST`) at startup. `handle_conn` runs the filename query (`query_docids` + path/meta resolve) and a content query (per shard: on-demand `ShardReader::open` → `candidates` → path/meta resolve), merges into a path-keyed map with kind aggregation, applies `--scope` + `limit`, and streams `Batch { paths, meta, kind }`. `ShardReader` is opened on-demand per query to avoid the self-referential-lifetime problem of storing it alongside its owning `MmapSource`. Shard-level `--scope` pruning (dirTable) is deferred to M7; M5 filters scope at the resolved-path level (reuses `df_core::in_scope`).

**Tech Stack:** Rust ws; reuse `df_core::{query_docids, in_scope, LiteMeta}`, `df_content::{ShardReader, fold::fold}`, `df_core::candidate::candidates`, `df_index::{MmapSource, Manifest}`, `df_ipc` framing. New dep: deepfindd → df-content.

**Scope:** M5 only. M6 (CLI `--content`/`--filename` + `--direct` online-grep + status), M7 (madvise/bigram/1-char/shard-prune/ArcSwap live-swap) planned next. v2.0 full-rebuild model: the daemon loads shards once at startup; a rebuild = restart (live ArcSwap swap is M7).

---

## File structure (M5)

- **Modify** `crates/df-ipc/src/proto.rs` — add `MatchKind` enum + `kind` field to `ResponseFrame::Batch`.
- **Modify** `crates/df-ipc/src/lib.rs` — re-export `MatchKind`.
- **Modify** `crates/deepfindd/Cargo.toml` — add `df-content = { workspace = true }`.
- **Modify** `crates/deepfindd/src/lib.rs` — `ContentShards` open-at-startup; combined query + dedup + stream-with-kind.
- **Modify** `crates/deepfind/src/main.rs` — `daemon_search` reads `kind`; `cmd_search`/`print_results` show a marker with `-l`.
- **Modify** `crates/deepfindd/tests/serve.rs` — update `Batch` construction; add a combined-result test.

---

## Task 1 (M5a): `MatchKind` + `Batch.kind` across all sites

**Files:** `crates/df-ipc/src/proto.rs`, `crates/df-ipc/src/lib.rs`, `crates/deepfindd/src/lib.rs`, `crates/deepfind/src/main.rs`, `crates/deepfindd/tests/serve.rs`

- [ ] **Step 1 — `crates/df-ipc/src/proto.rs`:** add the enum and the field:
```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum MatchKind {
    Filename,
    Content,
    Both,
}
```
Change `ResponseFrame::Batch` to:
```rust
    Batch {
        paths: Vec<String>,
        meta: Vec<LiteMeta>,
        kind: Vec<MatchKind>,
    },
```
- [ ] **Step 2 — `crates/df-ipc/src/lib.rs`:** add `MatchKind` to the proto re-export (`pub use proto::{ResponseFrame, SearchOptions, SearchRequest, MatchKind};`).
- [ ] **Step 3 — update every `ResponseFrame::Batch { .. }` site:**
  - `crates/deepfindd/src/lib.rs` `handle_conn` / `resolve_chunk`: the existing `Batch { paths, meta }` constructions need `kind`. For M5a (this task) just make it compile: pass `kind: vec![MatchKind::Filename; paths.len()]` as a placeholder (the real kind wiring is M5b). Add `use df_ipc::proto::MatchKind;` if needed. Actually — to avoid a throwaway placeholder, M5a and M5b are tightly coupled; in this task add the field and set `kind` to `Filename` everywhere, then M5b fixes handle_conn to compute real kinds.
  - `crates/deepfindd/tests/serve.rs`: `query_and_collect` and the existing test's `ResponseFrame::Batch { paths, .. }` patterns already use `..` so they don't need changing — verify they still compile (they destructure with `..`).
  - `crates/deepfind/src/main.rs` `daemon_search`: the `ResponseFrame::Batch { paths, meta }` destructure becomes `{ paths, meta, kind }` (capture kind; ignore for now or carry for M5c). Use `kind: _` or bind it.
- [ ] **Step 4 — build + test + clippy + fmt:** `cargo build`, `cargo test 2>&1 | grep -E FAILED` (none), `cargo clippy --all-targets -- -D warnings`, `cargo fmt`.
- [ ] **Step 5 — commit:**
```bash
git add crates/df-ipc/src/proto.rs crates/df-ipc/src/lib.rs crates/deepfindd/src/lib.rs crates/deepfind/src/main.rs crates/deepfindd/tests/serve.rs
git commit -m "feat(ipc): MatchKind + Batch.kind field (filename placeholder; real kinds in M5b)"
```

---

## Task 2 (M5b): `ContentShards` + daemon combined query

**Files:** `crates/deepfindd/Cargo.toml`, `crates/deepfindd/src/lib.rs`

- [ ] **Step 1 — `crates/deepfindd/Cargo.toml` `[dependencies]`:** add `df-content = { workspace = true }`.
- [ ] **Step 2 — `crates/deepfindd/src/lib.rs`:** add a `ContentShards` type + combined-query in `handle_conn`. Replace the `serve` and `handle_conn`/`resolve_chunk` block with the combined version below. (Keep `shutdown_signal`, `STREAM_CHUNK`, `DRAIN_TIMEOUT`, the `serve` accept-loop + drain unchanged except opening the shards.)

Add after the imports:
```rust
use df_content::ShardReader;
use df_core::candidate::candidates;
use df_ipc::proto::MatchKind;
use std::collections::HashMap;
```
Add the `ContentShards` type + helper:
```rust
/// The mmap'd content shard set (opened once at daemon startup from the MANIFEST).
struct ContentShards {
    sources: Vec<df_index::MmapSource>,
}

impl ContentShards {
    /// Open all shards listed in `content_dir/MANIFEST`. Empty if no manifest/dir.
    fn open(content_dir: &Path) -> Self {
        let mut sources = Vec::new();
        if let Some(manifest) = df_index::Manifest::read(&content_dir.join("MANIFEST")) {
            for entry in &manifest.shards {
                let path = content_dir.join(&entry.file);
                if let Ok(src) = df_index::MmapSource::open(&path) {
                    sources.push(src);
                }
            }
        }
        Self { sources }
    }

    /// Run a content query across all shards. Returns (path, meta, Content) for
    /// each in-scope verified match. `scope`/`limit` applied per shard candidate
    /// set; final dedup + cap happens in the caller.
    fn query(
        &self,
        folded: &[u8],
        scope: Option<&Path>,
        per_shard_limit: Option<u32>,
    ) -> Vec<(String, LiteMeta, MatchKind)> {
        let mut out = Vec::new();
        for src in &self.sources {
            let r = match ShardReader::open(src.as_slice()) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let docids = candidates(&r, folded, per_shard_limit).unwrap_or_default();
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
```
Change `serve` to also open the shards and thread them through. Update `serve`'s signature is unchanged (`serve(socket_path, db_path)`); derive `content_dir = db_path.parent().unwrap().join("content")` and open `ContentShards`. Pass `Arc<ContentShards>` into each connection task. The existing `handle_conn(stream, db)` becomes `handle_conn(stream, db, shards)`.

Rewrite `handle_conn` to merge filename + content:
```rust
async fn handle_conn(
    stream: UnixStream,
    db: Arc<DbReader<FileSource>>,
    shards: Arc<ContentShards>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut f = framed(stream);
    let req_bytes: Bytes = match f.next().await {
        Some(Ok(b)) => b.freeze(),
        _ => return Ok(()),
    };
    let req: SearchRequest = decode_request(&req_bytes)?;

    let query_str = req.query.clone();
    let scope: Option<PathBuf> = req.scope.clone();
    let limit = req.limit;
    // Engine work off the async pool.
    let eff_limit = if scope.is_some() { None } else { limit };
    let db_q = db.clone();
    let folded = df_content::fold::fold(query_str.to_lowercase().as_bytes());
    let folded_for_content = folded.clone();
    let scope_for_content = scope.clone();
    let shards_q = shards.clone();
    let (fn_docids, content_matches) = tokio::task::spawn_blocking(move || {
        let fn_docids = query_docids(&db_q, &query_str, eff_limit).unwrap_or_default();
        let content = shards_q.query(&folded_for_content, scope_for_content.as_deref(), limit);
        (fn_docids, content)
    })
    .await?;

    // Merge: filename (resolve path+meta+Filename) + content (already resolved).
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let mut merged: HashMap<String, (LiteMeta, MatchKind)> = HashMap::new();

    // filename layer: resolve in chunks off the pool.
    for chunk in fn_docids.chunks(STREAM_CHUNK) {
        if merged.len() >= cap {
            break;
        }
        let db_r = db.clone();
        let scope_r = scope.clone();
        let batch = tokio::task::spawn_blocking(move || {
            let mut out = Vec::new();
            for &d in chunk {
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
            merge_in(&mut merged, path, meta, MatchKind::Filename, cap);
        }
    }
    // content layer.
    for (path, meta, kind) in content_matches {
        merge_in(&mut merged, path, meta, kind, cap);
    }

    // Stream merged results.
    let mut total: u32 = 0;
    let mut entries: Vec<(String, LiteMeta, MatchKind)> =
        merged.into_iter().map(|(p, (m, k))| (p, m, k)).collect();
    entries.truncate(cap);
    for chunk in entries.chunks(STREAM_CHUNK) {
        let (paths, meta_kind): (Vec<String>, Vec<(LiteMeta, MatchKind)>) =
            chunk.iter().map(|(p, m, k)| (p.clone(), (*m, *k))).unzip();
        let (meta, kind) = meta_kind.into_iter().unzip();
        f.send(encode_frame(&ResponseFrame::Batch { paths, meta, kind })?).await?;
        total += chunk.len() as u32;
    }
    f.send(encode_frame(&ResponseFrame::Done { total })?).await?;
    Ok(())
}

/// Insert/merge a match into the dedup map. Filename + Content on the same path → Both.
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
        Some((_, existing)) => {
            *existing = combine_kind(*existing, kind);
        }
        None => {
            map.insert(path, (meta, kind));
        }
    }
}

fn combine_kind(a: MatchKind, b: MatchKind) -> MatchKind {
    use MatchKind::*;
    match (a, b) {
        (Filename, Content) | (Content, Filename) | (Both, _) | (_, Both) => Both,
        _ => b,
    }
}
```
Remove the old `resolve_chunk` function (no longer used). Update `serve` to open `ContentShards` and pass `Arc<ContentShards>` into each spawned `handle_conn`. Keep the accept-loop + drain + shutdown logic unchanged.
- [ ] **Step 3 — build + test + clippy + fmt:** `cargo build`, `cargo test 2>&1 | grep -E FAILED` (the existing serve test must still pass — it queries filename-only over a small tree with NO content dir, so `ContentShards::open` returns empty and behavior is filename-only), `cargo clippy --all-targets -- -D warnings`, `cargo fmt`.
- [ ] **Step 4 — commit:**
```bash
git add crates/deepfindd/Cargo.toml crates/deepfindd/src/lib.rs
git commit -m "feat(daemon): open content shards at startup; combined filename∪content query + dedup"
```

---

## Task 3 (M5c): CLI kind marker + combined-result daemon test + wrap

**Files:** `crates/deepfind/src/main.rs`, `crates/deepfindd/tests/serve.rs`

- [ ] **Step 1 — `crates/deepfind/src/main.rs`:** `daemon_search` already (from M5a) captures `kind` from the Batch frame; carry it through as `Vec<(String, LiteMeta, MatchKind)>`. Update `print_results` to render a marker with `-l`:
```rust
fn print_results(results: Vec<(String, LiteMeta, MatchKind)>, long: bool) {
    for (path, meta, kind) in results {
        if long {
            let dir = if meta.is_dir { "/" } else { "" };
            let km = match kind { MatchKind::Filename => "[f]", MatchKind::Content => "[c]", MatchKind::Both => "[b]" };
            println!("{km}\t{}\t{}{}", humansize(meta.size), path, dir);
        } else {
            println!("{path}");
        }
    }
}
```
(Thread `MatchKind` through `daemon_search`/`direct_scan` return types; for `direct_scan` use `MatchKind::Filename` as a placeholder — real online-grep is M6.)
- [ ] **Step 2 — `crates/deepfindd/tests/serve.rs`:** add a combined-result test that builds BOTH the filename DB and content shards (via `build_content_index`) over a temp tree, starts the daemon, and asserts a query returns matches with the right `kind`:
```rust
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn combined_filename_and_content_results() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("alpha.rs"), b"fn alpha() {}").unwrap();
    std::fs::write(tmp.path().join("other.txt"), b"nothing here").unwrap();
    let db_path = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    let opts = df_index::ContentBuildOptions::default();
    let _ = df_index::build_content_index(tmp.path(), &db_path, &content_dir, &opts).unwrap();
    let socket = tmp.path().join("daemon.sock");
    let sock = socket.clone();
    let db = db_path.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &db).await });

    let req = SearchRequest {
        query: "alpha".into(), scope: None, limit: None, opts: SearchOptions::default(),
    };
    let stream = connect_wait(&socket).await;
    let mut f = framed(stream);
    f.send(encode_request(&req).unwrap()).await.unwrap();
    // alpha.rs matches by BOTH filename (path contains "alpha") and content.
    let mut got_kinds: Vec<MatchKind> = Vec::new();
    let mut got_paths: Vec<String> = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame.unwrap()) {
            Ok(ResponseFrame::Batch { paths, kind, .. }) => { got_paths.extend(paths); got_kinds.extend(kind); }
            Ok(ResponseFrame::Done { .. }) => break,
            other => panic!("{other:?}"),
        }
    }
    assert!(got_paths.iter().any(|p| p.ends_with("alpha.rs")));
    // alpha.rs matched both layers ⇒ at least one Both.
    assert!(got_kinds.iter().any(|k| *k == MatchKind::Both), "no Both kind: {:?}", got_kinds);

    server.abort();
}
```
Add the imports (`use df_ipc::proto::{..., MatchKind};` and `df_index::ContentBuildOptions`).
- [ ] **Step 3 — build + test + clippy + fmt:** `cargo test 2>&1 | tail -5` (all green incl. new test), `cargo clippy --all-targets -- -D warnings`, `cargo fmt`, `cargo fmt --check`.
- [ ] **Step 4 — commit:**
```bash
git add crates/deepfind/src/main.rs crates/deepfindd/tests/serve.rs
git commit -m "feat(cli): MatchKind markers (-l); test combined filename+content daemon results"
```
- [ ] **Step 5 — M5 wrap:** confirm whole-workspace green; empty sweep commit if needed.

---

## Self-review

**Spec coverage (M5, spec §10/§12):**
- Daemon opens shard set at startup → Task 2 (`ContentShards::open`). ✓
- Combined filename∪content query + dedup by path (Both) → Task 2 (`handle_conn` + `merge_in`/`combine_kind`). ✓
- `--scope` filter → Task 2 (path-level via `in_scope`; shard-level dirTable prune is M7). ✓
- `match_kind` in Batch → Task 1. ✓
- Stream Batch with kind → Task 2. ✓
- CLI marker → Task 3. ✓

**Deferred:** ArcSwap live-swap-on-rebuild (M7; v2.0 = restart on rebuild), shard-level `--scope` prune via dirTable (M7), `--direct` online content grep (M6), `--content`/`--filename` restrict flags (M6).

**Risks:**
- Self-referential lifetime avoided by on-demand `ShardReader::open` per query (cheap: footer+TOC parse, no posting decode). ✓
- The existing serve test has no content dir → `ContentShards::open` returns empty → filename-only behavior preserved (test must still pass). ✓
- Filename query still uses `eff_limit` (None when scope set) so `--scope` + limit compose correctly for the filename half; content half passes `limit` per-shard then global cap after dedup. ✓
- `combine_kind` correctness: Filename∩Content → Both; idempotent for repeated same-kind. ✓

---

## Execution handoff

Plan saved to `docs/superpowers/plans/2026-06-23-v2-content-index-m5.md`. Execute via subagent-driven-development, 3 task groups (M5a proto+field, M5b ContentShards+combined query, M5c CLI+test+wrap), spec+quality review each, final holistic M5 review. M6–M7 planned after M5's daemon combined-query API is concrete.
