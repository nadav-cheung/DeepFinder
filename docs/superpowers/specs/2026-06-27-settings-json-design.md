# Design — `settings.json` config with an `ignore` list

> **Date:** 2026-06-27 · **Status:** Design (pending implementation)
> **Companion:** [architecture.md](../../architecture.md), [decisions.md](../../decisions.md)
> **In one sentence:** add a global `~/.deep-find/settings.json` whose first field is an `ignore` list (gitignore-glob patterns of files/folders to skip), applied at every index build and `--direct` scan, managed by a new `deepfind config` subcommand.

---

## 1. Goal & context

DeepFind already prunes a few hardcoded directory names (`DEFAULT_SKIP`: `.git`, `node_modules`, …) and lets the user pass `--skip NAME` per build. There is no persistent, user-editable, whole-disk ignore list, and `--direct` online scan applies **no** skip at all (an asymmetry). Users want to permanently exclude paths/patterns from being scanned or indexed (e.g. `**/.venv`, `*.log`, `/Users/x/Secret`) without retyping flags.

This adds a JSON config file with an `ignore` field, plus a CLI to manage it. The file is designed extensibly — `ignore` is the first of several future settings — but only `ignore` is implemented now (YAGNI).

## 2. Decisions (locked with the user)

1. **Scope = global.** One `~/.deep-find/settings.json`; its `ignore` list applies to **every** registered-DB index build, every df-watch rebuild, and `--direct` scans. (Not per-DB, not per-root.)
2. **Match = gitignore globs.** Entries are `ignore`-crate gitignore patterns, so they match both files and folders, by name, glob, or absolute path (`node_modules`, `*.log`, `**/dist`, `/Users/x/Secret`).
3. **Union semantics.** The settings `ignore` is unioned with the existing filters — the `ignore` walker's `standard_filters` (`.gitignore`/global-gitignore) **and** the existing `extra_skip` directory-name pruning. All three apply; none replaces another.
4. **No hot-reload.** Ignore is consumed at walk time, so a settings change takes effect on the next build / next `--direct` scan / next df-watch event. No file watcher (unlike `dbs.toml`); ignore does not affect live queries, so a watcher would add complexity for no benefit.
5. **`deepfind config` subcommand** mirrors the existing `db add/remove/list` UX (see §6).

## 3. File location & schema

Path: `~/.deep-find/settings.json` (i.e. `df_ipc::data_dir().join("settings.json")`).

```json
{
  "ignore": ["node_modules", "**/.venv", "*.log", "*.min.js", "/Users/x/Secret"]
}
```

- `serde` + `serde_json`, **all fields `#[serde(default)]`** (forward/backward compatible — unknown future keys are ignored on read, missing keys default; same convention as `SearchOptions`).
- Absent / unreadable / malformed file ⇒ `Settings::default()` (empty `ignore`) + a `tracing::warn!`; a build/scan never fails over a bad config.
- Top-level object, extensible: future scalar settings are additional top-level keys.

## 4. Where it applies (data flow)

| Consumer | How it reads `ignore` |
|---|---|
| **Index build** (`build_content_index` / `build_index_report`, df-index) | patterns arrive in `ContentBuildOptions.ignore_patterns`; the build compiles them into an `ignore::gitignore` matcher applied as a walker `filter` |
| **`--direct` scan** (`direct_scan`, deepfind) | loads `Settings::load(data_dir)` itself and applies the matcher to its `WalkBuilder` (today it applies no skip — this closes that gap) |
| **df-watch overlay** (`watch::run`, deepfindd) | a change event whose path matches the matcher is **skipped** (not upserted); already-indexed-but-now-ignored files are dropped at the next compaction / safety-net rebuild |
| **IPC wire** (`IndexRequest`) | **unchanged** — the daemon loads settings itself at build time; `ignore` is not carried over the socket |

All daemon build paths funnel through `index_job::tracked_build`, so **settings are loaded once there** and merged into the build `opts` before building — covering on-demand, startup, compaction, and safety-net builds uniformly.

## 5. Components & crate placement

- **New module `df-index::settings`** (next to `registry.rs`, the existing config-file loader; df-index already does TOML/atomic-write I/O — it is **not** the zero-I/O crate, that's `df-core`):
  - `struct Settings { #[serde(default)] ignore: Vec<String> }`
  - `Settings::load(data_dir: &Path) -> Settings` — read + deserialize; default+warn on missing/unreadable/malformed.
  - `Settings::save(data_dir: &Path, &Settings)` — serialize + `atomic_write` (tmp→fsync→rename; same helper `registry.rs` uses).
  - `settings_path(data_dir) -> PathBuf` — `data_dir.join("settings.json")`.
  - No new workspace dependency: `serde`/`serde_json`/`ignore`/`atomic_write` are all already in-tree. (`serde_json` is added to `df-index`'s `Cargo.toml` if not already a dep — verify at implementation.)
- **`ContentBuildOptions`** gains one field: `pub ignore_patterns: Vec<String>` (default empty). The build compiles these into an in-memory `ignore::gitignore::Gitignore` (via `GitignoreBuilder`, rooted at the build `root` so relative patterns resolve correctly) and skips matching entries in the walker. `build_content_index` is the production path (filename + content in **one** walk), so a single filter covers both layers. The standalone filename-only `build_index_report(root, out_db, extra_skip, hidden)` — if still exercised — receives the patterns via its signature, threaded the same way as `extra_skip`.
- **Daemon** (`index_job::tracked_build`): load `Settings::load(&df_ipc::data_dir())` once, set `opts.ignore_patterns` before calling `build_content_index_with_progress`.
- **CLI** (`deepfind/src/main.rs`): `direct_scan` and the in-process `--foreground` build load settings and set `opts.ignore_patterns`.

The `df-core` zero-I/O hard constraint is preserved (no I/O added there).

## 6. `deepfind config` subcommand

Mirrors `db add/remove/list`. Subcommands:

```
deepfind config show                       # print the full settings.json (pretty JSON)
deepfind config ignore add <PATTERN>       # append a pattern (dedup; no-op if present); save
deepfind config ignore remove <PATTERN>    # remove a pattern (exact match); save
deepfind config ignore list                # print patterns, one per line
```

- `add`/`remove` do `Settings::load` → mutate `ignore` (dedup on add) → `Settings::save` (atomic). Idempotent.
- `show`/`list` are read-only.
- Nesting (`config ignore …`) keeps the namespace extensible for future settings without refactoring later.
- clap shape: `Config { Show, Ignore { Add, Remove, List } }`, mirroring the existing `Db { Add, Remove, List }` enum.

## 7. Mechanism

Patterns are compiled once per walk into an `ignore::gitignore::Gitignore` (in-memory — no temp ignore files written) and consulted from the walker's `filter` closure. Exact `ignore` crate API (`GitignoreBuilder`/`Gitignore::matched`) is verified against current crate docs at implementation time. Existing `extra_skip` name-pruning is left in place (union); unifying it onto the gitignore matcher is explicitly **out of scope** (a separate refactor).

## 8. Error handling

- Missing file → defaults (silent — a fresh install has no settings).
- Unreadable file → defaults + `warn!`.
- Malformed JSON → defaults + `warn!` naming the file (never abort a build/scan).
- A bad glob pattern → warn + skip that one pattern (the rest still apply).
- `config ignore add/remove` save failures surface a CLI error (non-zero exit).

## 9. Testing

- **Unit (`df-index::settings`):** load-from-valid, default-on-missing, default+warn-on-malformed, serde forward-compat (unknown key ignored), save→load roundtrip, `ignore add` dedup, `ignore remove` exact-match.
- **Build test (`df-index`):** a tree containing a file and a folder matching `ignore` patterns is built; assert neither appears in the resulting index (filename or content).
- **`--direct` test (`deepfind`):** an ignored file/folder is absent from `direct_scan` output.
- **df-watch test (`deepfindd`):** a change event on an ignored path is **not** folded into the overlay.
- **`config` CLI test:** `config ignore add`/`remove`/`list`/`show` roundtrip against a tempdir-backed `data_dir` (inject the dir — never touch the real `~/.deep-find/`, per CLAUDE.md test rules).

## 10. Out of scope / future

- Unifying `extra_skip` (name pruning) onto the gitignore matcher.
- Hot-reload / a settings file watcher.
- Additional settings fields (the schema is extensible; add per-feature later).
- Per-DB or per-root ignore (`.deepfindignore` in roots) — not needed; global + `.gitignore` covers the cases.
