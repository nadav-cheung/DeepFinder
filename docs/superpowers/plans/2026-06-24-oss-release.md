# OSS 1.0 Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship DeepFinder (Rust) as open-source 1.0 — single `deepfind` binary, automated background indexing of `$HOME`, Homebrew + curl|sh distribution via cargo-dist, universal macOS binary.

**Architecture:** Phase 1 collapses `deepfindd` to a lib (daemon runs via `deepfind daemon`). Phase 2 makes the daemon's `DbSet` hot-swappable (`Arc<ArcSwap<DbSet>>`) so it background-builds missing indexes on startup and reports freshness — mirroring the existing shard ArcSwap. Phases 3–5 do version/tags, cargo-dist + OSS files, and the release cut.

**Tech Stack:** Rust 2021 (resolver 2), tokio, arc-swap, notify, df-index (`build_content_index`/`Registry`), cargo-dist, GitHub Actions, Homebrew.

**Spec:** `docs/superpowers/specs/2026-06-24-oss-release-design.md`

---

## File Structure

**Phase 1 (binary merge):**
- Delete: `crates/deepfindd/src/main.rs`
- Modify: `crates/deepfindd/Cargo.toml` (drop `[[bin]]`), `crates/deepfind/src/main.rs` (`cmd_daemon` tracing), `crates/deepfind/src/launchd.rs` (plist → `deepfind daemon`; drop `resolve_daemon_bin`)

**Phase 2 (background indexing):**
- Modify: `crates/deepfindd/src/lib.rs` (`serve`/`handle_conn`/`DbSet` ArcSwap; background build), `crates/deepfind/src/main.rs` (`cmd_status` freshness; `cmd_install` auto-register `$HOME`)
- New module: `crates/deepfindd/src/index_job.rs` (background build task + marker file)

**Phase 3 (version/tags):** `Cargo.toml`, new `CHANGELOG.md`, delete old tags

**Phase 4 (cargo-dist + OSS):** `Cargo.toml` (`[workspace.metadata.dist]`, `[profile.dist]`), new `.github/workflows/release.yml`, new `CONTRIBUTING.md`, new `CODE_OF_CONDUCT.md`, `README.md`, `.github/workflows/ci.yml`

**Phase 5 (release):** tag + verify

---

## Phase 1 — Binary merge (single `deepfind`)

### Task 1.1: Make `deepfindd` a lib-only crate

**Files:**
- Delete: `crates/deepfindd/src/main.rs`
- Modify: `crates/deepfindd/Cargo.toml`

- [ ] **Step 1: Remove the `[[bin]]` target from `crates/deepfindd/Cargo.toml`**

Delete lines 12–14 (the `[[bin]]` block). The file keeps `[lib]` (lines 8–10). Result: `deepfindd` is a library crate only.

- [ ] **Step 2: Delete `crates/deepfindd/src/main.rs`** (the standalone daemon binary — its tracing init moves to `deepfind` in Task 1.2).

- [ ] **Step 3: Verify the workspace still builds (deepfind still links deepfindd lib)**

Run: `cargo build --workspace`
Expected: succeeds; `target/release/deepfindd` is no longer produced. `cargo build -p deepfind` succeeds.

- [ ] **Step 4: Commit**

```bash
git add crates/deepfindd/Cargo.toml crates/deepfindd/src/main.rs
git commit -m "refactor(daemon): drop standalone deepfindd binary; crate is lib-only (binary model B)"
```

### Task 1.2: `cmd_daemon` takes over tracing init

**Files:**
- Modify: `crates/deepfind/src/main.rs` (`cmd_daemon`, ~line 465)

- [ ] **Step 1: Add tracing init at the top of `cmd_daemon`**

Current `cmd_daemon` (in `crates/deepfind/src/main.rs`) starts directly with `deepfindd::serve(...)`. Prepend the tracing init that used to live in `deepfindd/src/main.rs`:

```rust
async fn cmd_daemon() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    if let Err(e) = deepfindd::serve(&default_socket(), &default_db()).await {
        // … existing error handling …
    }
}
```
Keep the existing body after `.init();` unchanged. (`tracing_subscriber` is already a deepfind dependency.)

- [ ] **Step 2: Verify `deepfind daemon` emits logs**

Run:
```sh
cargo build -p deepfind --release
HOME=$(mktemp -d) RUST_LOG=info ./target/release/deepfind daemon & PID=$!
sleep 1; kill $PID 2>/dev/null
```
Expected: stderr contains `deepfindd listening` (proves tracing is initialized via `deepfind daemon`).

- [ ] **Step 3: Commit**

```bash
git add crates/deepfind/src/main.rs
git commit -m "feat(cli): 'deepfind daemon' initializes tracing (was deepfindd main)"
```

### Task 1.3: launchd plist runs `deepfind daemon` (TDD)

**Files:**
- Modify: `crates/deepfind/src/launchd.rs`

- [ ] **Step 1: Rewrite the failing tests** in `crates/deepfind/src/launchd.rs` `#[cfg(test)] mod tests`:

Replace the `resolve_daemon_bin_*` tests (deleted) and update `render_plist`/`install` assertions so the plist references the **single `deepfind` binary with a `daemon` arg** instead of a sibling `deepfindd`. Key assertions:

```rust
#[test]
fn render_plist_runs_deepfind_daemon_subcommand() {
    let home = PathBuf::from("/Users/example");
    let exe = PathBuf::from("/Users/example/.cargo/bin/deepfind");
    let xml = render_plist(&exe, &home, false);
    assert!(xml.contains("<string>/Users/example/.cargo/bin/deepfind</string>"));
    assert!(xml.contains("<string>daemon</string>"));
    assert!(xml.contains("<key>RunAtLoad</key>"));
    assert!(xml.contains("<key>KeepAlive</key>"));
    assert!(!xml.contains("DEEPFIND_WATCH"));
}

#[test]
fn render_plist_with_watch_includes_env() {
    let home = PathBuf::from("/Users/example");
    let exe = PathBuf::from("/Users/example/.cargo/bin/deepfind");
    let xml = render_plist(&exe, &home, true);
    assert!(xml.contains("DEEPFIND_WATCH"));
}

#[test]
fn install_writes_plist_running_deepfind_daemon() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let exe = home.join(".cargo/bin/deepfind"); // no sibling deepfindd needed anymore
    std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
    std::fs::write(&exe, b"x").unwrap();
    install(&home, &exe, true, false).unwrap();
    let content = std::fs::read_to_string(plist_path(&home)).unwrap();
    assert!(content.contains("/deepfind</string>"));
    assert!(content.contains("<string>daemon</string>"));
}
```
Drop the `resolve_daemon_bin_*` tests and the old `install_errors_when_daemon_binary_missing` test (no sibling resolution now). Keep the `plist_path_*`, `uninstall_*` tests.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p deepfind launchd`
Expected: FAIL — `render_plist`/`install` still reference the old `bin`/sibling model.

- [ ] **Step 3: Update `launchd.rs` implementation**

- Delete `resolve_daemon_bin`.
- Change `render_plist` signature from `(bin, home, watch)` → `(exe, home, watch)` and emit `ProgramArguments` = `[exe, "daemon"]`:

```rust
pub fn render_plist(exe: &Path, home: &Path, watch: bool) -> String {
    let out = home.join(".deep-finder/logs/daemon.out.log");
    let err = home.join(".deep-finder/logs/daemon.err.log");
    let env = if watch {
        "\t<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>DEEPFIND_WATCH</key>\n\t\t<string>1</string>\n\t</dict>\n"
    } else { "" };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key>\n\t<string>{LABEL}</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>{exe}</string>\n\t\t<string>daemon</string>\n\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<true/>\n\t<key>ProcessType</key>\n\t<string>Background</string>\n{env}\t<key>StandardOutPath</key>\n\t<string>{out}</string>\n\t<key>StandardErrorPath</key>\n\t<string>{err}</string>\n</dict>\n</plist>\n",
        exe = exe.display(), out = out.display(), err = err.display(),
    )
}
```

- Change `install` to take the `deepfind` exe directly (no sibling lookup):

```rust
pub fn install(home: &Path, exe: &Path, watch: bool, load: bool) -> Result<(), String> {
    let path = plist_path(home);
    std::fs::create_dir_all(path.parent().unwrap_or(home))
        .map_err(|e| format!("create LaunchAgents dir: {e}"))?;
    std::fs::create_dir_all(home.join(".deep-finder/logs"))
        .map_err(|e| format!("create log dir: {e}"))?;
    std::fs::write(&path, render_plist(exe, home, watch))
        .map_err(|e| format!("write plist: {e}"))?;
    if load {
        let status = std::process::Command::new("launchctl")
            .args(["load", &path.to_string_lossy()])
            .status().map_err(|e| format!("spawn launchctl load: {e}"))?;
        if !status.success() {
            return Err(format!("launchctl load failed (exit {:?})", status.code()));
        }
    }
    Ok(())
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p deepfind launchd`
Expected: PASS.

- [ ] **Step 5: Three gates + real-machine launchd smoke test**

```sh
cargo fmt && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
HOME=$(mktemp -d) ./target/release/deepfind install --no-watch
ls $HOME/Library/LaunchAgents/cn.com.nadav.deepfind.plist   # exists
HOME=$(mktemp -d) ./target/release/deepfind uninstall
```

- [ ] **Step 6: Commit**

```bash
git add crates/deepfind/src/launchd.rs
git commit -m "refactor(cli): launchd agent runs 'deepfind daemon' (single binary)"
```

---

## Phase 2 — Automated background indexing

### Task 2.1: Make `DbSet` hot-swappable via ArcSwap

**Files:**
- Modify: `crates/deepfindd/src/lib.rs` (`serve`, `handle_conn`)

- [ ] **Step 1: Change `serve` to hold `Arc<ArcSwap<DbSet>>` and pass a snapshot to `handle_conn`**

In `serve` (~line 430), replace:
```rust
let dbset = Arc::new(DbSet::open(db_path));
```
with:
```rust
let dbset: Arc<ArcSwap<DbSet>> = Arc::new(ArcSwap::from_pointee(DbSet::open(db_path)));
```
In the accept loop, the spawn closure currently clones `let dbset = dbset.clone();` then `handle_conn(stream, dbset)`. Keep passing `Arc<ArcSwap<DbSet>>`. At the top of `handle_conn`, take one snapshot:
```rust
async fn handle_conn(
    stream: UnixStream,
    dbset: Arc<ArcSwap<DbSet>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let dbset: Arc<DbSet> = dbset.load_full();   // snapshot for this connection
    // …rest unchanged; dbset is now Arc<DbSet> as before…
```
(The df-watch `watch::spawn` calls in `serve` reference `&dbset.entries` — change to `dbset.load().entries` / snapshot before the loop, since watchers are spawned once at startup from the initial set.)

- [ ] **Step 2: Verify existing tests stay green**

Run: `cargo test -p deepfindd`
Expected: all green (the snapshot makes per-connection behavior identical to before).

- [ ] **Step 3: Commit**

```bash
git add crates/deepfindd/src/lib.rs
git commit -m "refactor(daemon): hold DbSet behind ArcSwap (prep for hot-swap)"
```

### Task 2.2: Daemon starts even with no index (no hard error)

**Files:**
- Modify: `crates/deepfindd/src/lib.rs` (`serve`)

- [ ] **Step 1: Write the failing integration test** in `crates/deepfindd/tests/serve.rs`:

```rust
/// With no index present, serve() still binds + answers (empty result), so the
/// background builder (Task 2.3) can populate it without a restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn serve_starts_with_no_index() {
    let tmp = tempfile::tempdir().unwrap();
    let socket = tmp.path().join("daemon.sock");
    let db = tmp.path().join("db/index.dfdb"); // intentionally NOT built
    let sock = socket.clone();
    let dbp = db.clone();
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    let req = SearchRequest { query: "x".into(), scope: None, limit: None, opts: SearchOptions::default(), db: None };
    let (_b, got) = query_and_collect(&socket, req).await; // must NOT error / hang
    assert!(got.is_empty());
    server.abort();
}
```

- [ ] **Step 2: Run test — verify it fails**

Run: `cargo test -p deepfindd serve_starts_with_no_index`
Expected: FAIL — `serve` returns `Err("no index DB found …")`.

- [ ] **Step 3: Make `serve` tolerate an empty initial dbset**

In `serve`, replace the hard-error block:
```rust
if dbset.entries.is_empty() {
    return Err(... "no index DB found" ...);
}
```
with a log + continue:
```rust
let initial = dbset.load_full();
if initial.entries.is_empty() {
    tracing::warn!(db = ?db_path, "no index yet; serving empty until background build swaps one in");
}
```
(Keep the "deepfindd listening" log using `initial.entries.len()`.)

- [ ] **Step 4: Run test — verify it passes; re-run full suite**

Run: `cargo test -p deepfindd`
Expected: PASS, all green.

- [ ] **Step 5: Commit**

```bash
git add crates/deepfindd/src/lib.rs crates/deepfindd/tests/serve.rs
git commit -m "feat(daemon): serve with no index (await background build)"
```

### Task 2.3: Background build of missing registered-DB indexes

**Files:**
- New: `crates/deepfindd/src/index_job.rs`
- Modify: `crates/deepfindd/src/lib.rs` (`mod index_job;`, `serve` spawns it)

- [ ] **Step 1: Write the failing integration test** in `crates/deepfindd/tests/serve.rs`:

```rust
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

    // A default DB (so the layout is valid) but the WATCHED DB "w" has NO index yet.
    let w_db = data.join("db/w/index.dfdb");
    let mut reg = df_index::Registry::load(data);
    reg.upsert(df_index::DbRecord {
        name: "w".into(), root: root.clone(),
        db_path: w_db.clone(), content_dir: data.join("db/w/content"),
    });
    reg.save().unwrap();

    let socket = data.join("daemon.sock");
    let sock = socket.clone();
    // The "default" DB path passed to serve() must not exist either, so the only
    // index is the one "w" the background job builds.
    let dbp = data.join("db/index.dfdb");
    let server = tokio::spawn(async move { deepfindd::serve(&sock, &dbp).await });

    // Poll until the background build swaps "w" in.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let mut converged = false;
    while std::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let req = SearchRequest { query: "needle".into(), scope: None, limit: None, opts: SearchOptions::default(), db: Some("w".into()) };
        let (_b, got) = query_and_collect(&socket, req).await;
        if got.iter().any(|p| p.ends_with("a.txt")) { converged = true; break; }
    }
    server.abort();
    assert!(converged, "background build did not populate the index");
}
```

- [ ] **Step 2: Run test — verify it fails**

Run: `cargo test -p deepfindd background_build_populates_missing_index`
Expected: FAIL / never converges (no background build exists).

- [ ] **Step 3: Implement `crates/deepfindd/src/index_job.rs`**

```rust
//! Background initial-index builder. For a registered DB whose index is missing
//! at daemon startup, build it off the hot path, then hot-swap the DbSet so
//! queries see it — no restart, no offline window.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use arc_swap::ArcSwap;
use crate::DbSet;

/// Marker file written while a build is in flight (so `deepfind status` can
/// report `indexing`). Lives beside the DB's index.dfdb.
fn marker(db_path: &Path) -> PathBuf {
    db_path.with_extension("indexing")
}

/// Build `root` → `db_path`/`content_dir` in the background, then reload the
/// whole DbSet from disk and atomically swap it in. Errors are logged; the
/// daemon keeps serving whatever it had.
pub fn spawn_if_missing(
    root: PathBuf, db_path: PathBuf, content_dir: PathBuf,
    dbset: Arc<ArcSwap<DbSet>>, default_db_path: PathBuf,
) {
    if db_path.is_file() {
        return; // already indexed
    }
    std::thread::spawn(move || {
        let _ = std::fs::write(marker(&db_path), b"");
        tracing::info!(root = ?root, "background-indexing");
        let res = df_index::build_content_index(
            &root, &db_path, &content_dir, &Default::default(),
        );
        let _ = std::fs::remove_file(marker(&db_path));
        match res {
            Ok(_) => {
                dbset.store(Arc::new(DbSet::open(&default_db_path)));
                tracing::info!(root = ?root, "background-indexing complete; DbSet hot-swapped");
            }
            Err(e) => tracing::warn!(error = %e, root = ?root, "background-indexing failed"),
        }
    });
}

/// True while a build for `db_path` is in flight (used by status).
pub fn is_indexing(db_path: &Path) -> bool {
    marker(db_path).exists()
}
```

- [ ] **Step 4: Wire it into `serve`** — in `crates/deepfindd/src/lib.rs` add `pub mod index_job;` near `mod watch;` (the `is_indexing` helper is also called cross-crate by `deepfind status` in Task 2.5, hence `pub`), and after the df-watch spawn block, spawn background builds for registered DBs missing an index:

```rust
// Background initial-index for registered DBs that have a root but no index yet.
for e in &dbset.load().entries {
    if let Some(root) = &e.root {
        index_job::spawn_if_missing(
            root.clone(), e.db_path.clone(),
            e.shards.content_dir().to_path_buf(),
            dbset.clone(), db_path.to_path_buf(),
        );
    }
}
```
(Make `DbSet` and its `entries` field `pub(crate)` if not already, so `index_job` can read them.)

- [ ] **Step 5: Run test — verify it passes**

Run: `cargo test -p deepfindd background_build_populates_missing_index`
Expected: PASS (converges within the deadline).

- [ ] **Step 6: Commit**

```bash
git add crates/deepfindd/src/index_job.rs crates/deepfindd/src/lib.rs crates/deepfindd/tests/serve.rs
git commit -m "feat(daemon): background-build missing registered-DB indexes on startup"
```

### Task 2.4: `deepfind install` auto-registers `$HOME`

**Files:**
- Modify: `crates/deepfind/src/main.rs` (`cmd_install`)

- [ ] **Step 1: Write the failing test** (unit, in `main.rs` `#[cfg(test)]` or via a small extracted helper). Add a pure helper `ensure_default_root(home: &Path) -> Option<(String, PathBuf)>` returning `Some(("home", home))` only when no DB is registered yet, and test it against a temp `HOME` with/without `dbs.toml`.

```rust
#[test]
fn ensure_default_root_home_when_no_dbs() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    assert_eq!(ensure_default_root(&home), Some(("home".into(), home.clone())));
    // after registering one, it returns None
    let mut reg = df_index::Registry::load(&home.join(".deep-finder"));
    reg.upsert(df_index::DbRecord { name: "x".into(), root: home.clone(), db_path: home.join("x.dfdb"), content_dir: home.join("xc") });
    reg.save().unwrap();
    assert_eq!(ensure_default_root(&home), None);
}
```
(`ensure_default_root` reads `<home>/.deep-finder/dbs.toml` via `Registry::load`; returns `Some(("home", home))` iff it has zero records.)

- [ ] **Step 2: Run test — verify it fails** (`ensure_default_root` undefined).

- [ ] **Step 3: Implement `ensure_default_root` + call it in `cmd_install`**

```rust
fn ensure_default_root(home: &Path) -> Option<(String, PathBuf)> {
    let reg = df_index::Registry::load(&home.join(".deep-finder"));
    if reg.records.is_empty() {
        Some(("home".into(), home.to_path_buf()))
    } else {
        None
    }
}
```
In `cmd_install`, before installing the agent, if `let Some((name, root)) = ensure_default_root(&home())`, register it (reuse the `db add` code path: build is NOT done here — the daemon's background job does it). Print: `"Auto-registered DB 'home' → <root> (daemon will index it on start)"`.

- [ ] **Step 4: Run test — verify it passes.** Then real-machine smoke:
```sh
HOME=$(mktemp -d) ./target/release/deepfind install --no-watch
cat $HOME/.deep-finder/dbs.toml   # contains a 'home' record pointing at the temp HOME
```

- [ ] **Step 5: Commit**

```bash
git add crates/deepfind/src/main.rs
git commit -m "feat(cli): 'deepfind install' auto-registers \$HOME when no DB exists"
```

### Task 2.5: `deepfind status` reports index freshness

**Files:**
- Modify: `crates/deepfind/src/main.rs` (`cmd_status`)

- [ ] **Step 1: Write the failing test** for a pure helper `index_state(db_path: &Path) -> &'static str` returning `"missing" | "indexing" | "fresh" | "stale"`:

```rust
#[test]
fn index_state_missing_when_no_file() {
    let tmp = tempfile::tempdir().unwrap();
    assert_eq!(index_state(&tmp.path().join("index.dfdb")), "missing");
}
#[test]
fn index_state_indexing_when_marker_present() {
    let tmp = tempfile::tempdir().unwrap();
    let db = tmp.path().join("index.dfdb");
    std::fs::write(&db, b"x").unwrap();
    std::fs::write(db.with_extension("indexing"), b"").unwrap();
    assert_eq!(index_state(&db), "indexing");
}
```
(`fresh` = mtime within e.g. 24h; `stale` = older. Tests cover missing + indexing; fresh/stale are time-based, assert via mtime manipulation.)

- [ ] **Step 2: Run test — verify it fails** (`index_state` undefined).

- [ ] **Step 3: Implement `index_state`** using `deepfindd::index_job::is_indexing` + `std::fs::metadata(db_path).modified()` vs a 24h threshold, then extend `cmd_status` to print, per registered DB, its `index_state`.

- [ ] **Step 4: Run test — verify it passes;** full suite green.

- [ ] **Step 5: Commit**

```bash
git add crates/deepfind/src/main.rs crates/deepfindd/src/index_job.rs
git commit -m "feat(cli): 'deepfind status' reports per-DB index freshness (indexing/fresh/stale/missing)"
```

---

## Phase 3 — Version & tags

### Task 3.1: Bump version to 1.0.0 + CHANGELOG

**Files:**
- Modify: `Cargo.toml` (line 13: `version = "0.1.0"` → `"1.0.0"`)
- New: `CHANGELOG.md`

- [ ] **Step 1: Bump workspace version** in `Cargo.toml`: `version = "1.0.0"`.

- [ ] **Step 2: Create `CHANGELOG.md`** (Keep a Changelog format). `## [1.0.0] - 2026-06-24` summarizing the Rust rewrite: filename+content trigram search, daemon+CLI, smart-case/regex/boolean/`--expr`, multi-DB, `-n/-C`, ArcSwap hot-swap + df-watch, launchd install/uninstall, automated background indexing of `$HOME`.

- [ ] **Step 3: Verify**

```sh
cargo build --workspace && ./target/debug/deepfind --version   # prints 1.0.0
```

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock CHANGELOG.md
git commit -m "release: v1.0.0 (first public Rust release) + CHANGELOG"
```

### Task 3.2: Retire Swift-era tags

- [ ] **Step 1: Confirm none are referenced** — `git tag -l 'v0.*' 'v1.0.0' 'v1.1.0' 'v0.0.1-beta'`; grep `.github/` and `docs/` for these tag strings (expect none in Rust docs).

- [ ] **Step 2: Delete locally + on the remote**

```sh
for t in v0.0.1-beta v0.1.0 v0.2.0 v0.3.0 v0.4.0 v0.5.0 v0.6.0 v0.7.0 v1.0.0 v1.1.0; do
  git tag -d "$t"; git push origin :refs/tags/"$t"
done
```

- [ ] **Step 3: Verify** — `git tag -l` shows nothing (clean slate for the `v1.0.0` release tag in Phase 5).

- [ ] **Step 4: Commit** (record the decision in decisions.md):

```bash
# append a decisions.md entry: retired Swift-era tags v0.* / v1.0.0 / v1.1.0 (pointed at deleted Swift code)
git add docs/decisions.md
git commit -m "docs(decisions): retire Swift-era tags (v0.0.1-beta … v1.1.0) for clean Rust v1.0.0"
```

---

## Phase 4 — cargo-dist + OSS readiness

### Task 4.1: cargo-dist config

**Files:**
- Modify: `Cargo.toml` (add `[profile.dist]` + `[workspace.metadata.dist]`)

- [ ] **Step 1: Add the dist config** to `Cargo.toml`:

```toml
[profile.dist]
inherits = "release"
lto = "thin"

[workspace.metadata.dist]
cargo-dist-version = "0.28.0"   # pin; bump per `dist init` output
ci = ["github"]
installers = ["homebrew", "shell"]
targets = ["universal-apple-darwin"]
tap = "nadav-cheung/homebrew-tap"
publish-jobs = ["homebrew"]
install-path = ["~/.local/bin"]
pr-run-mode = "plan"
```
(Confirm the exact `cargo-dist-version` against the current dist release when running `dist init`.)

- [ ] **Step 2: Run `dist init`** to generate `.github/workflows/release.yml` from this config, committing the generated workflow.

```sh
cargo dist init            # accepts the config above; generates release.yml
cargo dist plan            # must report no errors
```

- [ ] **Step 3: Commit**

```bash
git add Cargo.toml .github/workflows/release.yml
git commit -m "build(dist): cargo-dist config (universal-apple-darwin, homebrew+shell, tap)"
```

### Task 4.2: Create the homebrew-tap repo + publish token (manual, documented)

- [ ] **Step 1:** Create an empty public repo `github.com/nadav-cheung/homebrew-tap`.
- [ ] **Step 2:** Add a GitHub secret to `nadav-cheung/DeepFinder` for tap publishing (cargo-dist's `HOMEBREW_TAP_GITHUB_TOKEN`, or install the dist GitHub App) — follow `dist init`'s printed instructions.
- [ ] **Step 3:** Record the setup in `docs/decisions.md` (one entry: tap repo + token, date).

### Task 4.3: OSS files (CONTRIBUTING, CoC)

**Files:**
- New: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`

- [ ] **Step 1: `CONTRIBUTING.md`** — build gates (`cargo fmt --check` · `cargo clippy --workspace --all-targets -- -D warnings` · `cargo test --workspace`), trunk-based (commit to `main`), Conventional Commits, TDD, macOS test gotchas (case-insensitive FS; tempdir + temp socket), `df-core` purity invariant. Draw from `CLAUDE.md`.

- [ ] **Step 2: `CODE_OF_CONDUCT.md`** — Contributor Covenant 2.1 (standard text from `https://www.contributor-covenant.org/version/2/1/code_of_conduct/`), contact = the maintainer email/GitHub.

- [ ] **Step 3: Commit**

```bash
git add CONTRIBUTING.md CODE_OF_CONDUCT.md
git commit -m "docs: CONTRIBUTING + Code of Conduct for OSS"
```

### Task 4.4: README install section + ci.yml fix

**Files:**
- Modify: `README.md`, `.github/workflows/ci.yml`

- [ ] **Step 1: Replace the README "Run" section** with an install section:

```markdown
## Install (macOS)

**Homebrew** (standard path `/opt/homebrew/bin`):
```sh
brew install nadav-cheung/tap/deepfind
```

**Or one-line script:**
```sh
curl -LsSf https://github.com/nadav-cheung/DeepFinder/releases/latest/download/deepfind-installer.sh | sh
```

**Start the background daemon** (auto-indexes `$HOME`, live-updates, starts at login):
```sh
deepfind install          # registers $HOME + installs a launchd agent
deepfind status           # shows indexing → fresh
deepfind search "needle"
```
Update later with `brew upgrade deepfind` (launchd auto-restarts the new binary).

## Build from source
`cargo build --workspace --release` … (keep existing gates)
```

- [ ] **Step 2: Fix `ci.yml`** — `cargo test --all` → `cargo test --workspace`; `cargo clippy --all-targets -- -D warnings` (already correct).

- [ ] **Step 3: Commit**

```bash
git add README.md .github/workflows/ci.yml
git commit -m "docs(readme): install section (brew + curl|sh + 'deepfind install'); ci: --workspace"
```

---

## Phase 5 — Release

### Task 5.1: Pre-release verification

- [ ] **Step 1: Three gates green**

```sh
cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

- [ ] **Step 2: Universal-binary dry run**

```sh
cargo dist build --tag v1.0.0-rc1 --artifacts=all
# verify the produced macOS archive's binary is universal:
lipo -info target/dist/*/deepfind    # expected: arm64 + x86_64
```
Expected: dist builds one `universal-apple-darwin` archive containing a single universal `deepfind` binary; `dist plan` clean.

- [ ] **Step 3: Commit any remaining changes; ensure working tree clean** (except the pre-existing unrelated `.claude/` + `CLAUDE.md` edits, which are not part of this release).

### Task 5.2: Cut v1.0.0 + verify end-to-end

- [ ] **Step 1: Tag + push**

```sh
git tag v1.0.0
git push origin main
git push origin v1.0.0
```

- [ ] **Step 2: Wait for the `release.yml` run** — confirm it creates the GitHub Release (universal archive + `deepfind-installer.sh` + checksums) and pushes the formula to `nadav-cheung/homebrew-tap`.

- [ ] **Step 3: Real-machine end-to-end** (clean test account or temp `HOME`):

```sh
brew install nadav-cheung/tap/deepfind          # /opt/homebrew/bin/deepfind
deepfind --version                               # 1.0.0
deepfind install                                 # registers $HOME + launchd agent
deepfind status                                  # indexing … → fresh
deepfind search "README"                         # served by daemon
# update path:
brew upgrade deepfind                            # launchd KeepAlive restarts new binary
deepfind uninstall                               # clean removal
```

- [ ] **Step 4: Final commit** — record the release in `CHANGELOG.md` (date) + `docs/decisions.md` (release notes link).

```bash
git add CHANGELOG.md docs/decisions.md
git commit -m "release: v1.0.0 shipped (universal macOS binary, brew + curl|sh)"
```

---

## Self-Review (run before execution)

- **Spec coverage:** Phase 1 = binary model B ✓; Phase 2 = ArcSwap<DbSet> + background build + status + $HOME auto-register ✓; Phase 3 = 1.0.0 + retire tags + CHANGELOG ✓; Phase 4 = cargo-dist (universal/homebrew/shell/tap) + CONTRIBUTING/CoC + README + ci ✓; Phase 5 = tag + verify ✓. All 5 spec phases mapped.
- **Type consistency:** `render_plist(exe, home, watch)`, `install(home, exe, watch, load)`, `Arc<ArcSwap<DbSet>>` + `load_full()`, `index_job::spawn_if_missing(root, db_path, content_dir, dbset, default_db_path)`, `index_state(db_path) -> &'static str` — used consistently across tasks.
- **Placeholders:** none; every code/command step is concrete. (`cargo-dist-version` to be confirmed at `dist init` — flagged inline, not a placeholder.)
