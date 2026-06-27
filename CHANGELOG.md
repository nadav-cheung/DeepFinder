# Changelog

All notable changes to DeepFind (Rust edition) are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

_Nothing yet._

## [0.1.6] - 2026-06-27

### Fixed
- **Filename layer stale after compaction / safety-net rebuild:** `compact_and_swap` and `rebuild_and_swap` reloaded the content shards after a rebuild but not the filename `DbSet`, so filename search results stayed stale until a daemon restart (deleted files still appeared by name; newly-added files were invisible by name). Content search was unaffected. Both rebuild paths now reload the filename layer via the existing `DbSet::open` + handle-reuse hot-swap (mirroring `spawn_build`), without orphaning the df-watch watcher.

## [0.1.5] - 2026-06-26

### Added
- **True incremental indexing (LSM hot overlay):** file changes under a watched DB are now folded into a persisted hot overlay (write-ahead log) and surfaced in queries within ~1s — instead of triggering a full-root rescan + hot-swap on every change. Queries merge the cold shard/filename layers with the overlay (overlay overrides stale cold hits; tombstones remove deleted paths). The overlay is replayed from its WAL on daemon restart, so changes survive crashes.
- **Compaction:** when the overlay grows past a threshold (default 2000 entries; tunable via `DEEPFIND_COMPACTION_THRESHOLD`), df-watch runs a full rebuild that subsumes the overlay and clears it (reusing the existing ArcSwap hot-swap), bounding memory + query-merge cost between compactions.
- **Safety-net periodic rebuild:** the daemon now rebuilds every rooted DB once per day (tunable via `DEEPFIND_SAFETY_NET_SECS`) to recover from anything missed (daemon downtime, coalesced/lost FSEvents, WAL corruption), independently of df-watch.
- **Single-instance daemon guard:** an advisory `flock` on `<data_dir>/daemon.lock` serializes daemon startup — a second `deepfind daemon` (e.g. a manual start racing launchd's KeepAlive respawn) bails instead of fighting the live daemon over the socket/index. The kernel releases the lock automatically on crash, so there's never a stale lock to clean up.

### Fixed
- A registry reload (e.g. `db add`, or the socket/lock creation at startup) no longer orphans the df-watch overlay handle: surviving DBs reuse their existing shard + overlay handles across the reload, so df-watch keeps updating the handles queries read.
- df-watch now normalizes macOS canonical event paths (`/private/var/…`) back to the lexical build-root form, so overlay paths match the cold shard for suppression/override.

## [0.1.4] - 2026-06-26

### Changed
- df-watch's automatic incremental rescans now report live progress (files · MB · shards) in `deepfind status`, identical to on-demand `deepfind index` builds — both paths share one progress-reporting build path (`index_job::tracked_build`). Previously df-watch rescans showed a bare `indexing` with no numbers.

## [0.1.3] - 2026-06-26

### Added
- **Background index builds (P2.3):** `deepfind index` now submits a background build to the daemon over the socket and returns immediately, instead of blocking in the foreground. Live build progress (files scanned · MB · shards) is reported by `deepfind status` while indexing. `--foreground` forces the old in-process build; the CLI falls back to it automatically when the daemon is unreachable. New IPC: `enum Request { Search, Index }` + `IndexRequest` / `ResponseFrame::IndexAck`. In-flight searches are never interrupted — the build hot-swaps the `DbSet` via `ArcSwap` (each connection pins a snapshot).

### Fixed
- df-watch's incremental rebuild now takes the same build-marker guard as on-demand/ startup builds, so a df-watch rebuild can no longer race a concurrent `deepfind index` and interleave (corrupt) shard writes.
- A daemon killed mid-build no longer leaves a stuck `.indexing` marker; stale markers are swept at startup so `deepfind status` recovers instead of reporting `indexing` forever.

## [0.1.2] - 2026-06-25

### Added
- Full Disk Access detection: `deepfind doctor` runs an FDA self-check (✅ / ❌ / ❓), prints the exact binary path + `launchctl kickstart` restart command, and — on a TTY — auto-opens System Settings → Full Disk Access. `deepfind status` now reports the FDA state; the daemon warns once at startup if FDA is missing (protected `~/Library` dirs would otherwise be skipped silently).

## [0.1.1] - 2026-06-25

### Fixed
- `--expr` help text now explains the `=` syntax to avoid shell word-splitting.
- Daemon now returns an error when `--db <name>` specifies a non-existent DB (instead of silently returning empty results).
- Daemon now watches `dbs.toml` for changes (registry watcher), so manually editing the registry or `db add` are picked up without a daemon restart.

## [0.1.0] - 2026-06-25

First public release of the Rust rewrite. Pre-1.0: usable, but the CLI/behavior may still change.

### Added
- Hybrid search engine: plocate-style filename index (pread) + zoekt-style content shards (mmap) behind one trigram candidate engine.
- Resident daemon + thin CLI over a Unix socket; CLI auto-falls back to `--direct` online scan when the daemon is down.
- Match modes: literal substring (default), `--regex`, smart-case (default) with `-i`/`-s`.
- Filters: `-t/--type`, `-e/--extension`, `-E/--exclude`, `-g/--glob`, `-d/--max-depth`, `--scope`, `--limit`, `--max-results`, `--sort`.
- Content: `-n/--line-number` + `-C/--context` (grep parity); `--content`/`--filename` layer select.
- bfs/find expression language: `--expr` (`-name/-path/-size/-newer` + boolean + parens).
- Multi-DB: `deepfind db add/remove/list`; `search --db <name>`.
- `deepfind install`/`uninstall`: a user launchd agent so the daemon auto-starts at login (KeepAlive); auto-registers `$HOME` and the daemon background-indexes it on start.
- df-watch: notify/FSEvents watcher with SIGBUS-safe ArcSwap shard hot-swap (env `DEEPFIND_WATCH`).
- `deepfind status` reports daemon reachability + per-DB index freshness (indexing/fresh/stale/missing).

### Changed
- N/A (first Rust release).

[0.1.6]: https://github.com/nadav-cheung/DeepFind/releases/tag/v0.1.6
[0.1.2]: https://github.com/nadav-cheung/DeepFind/releases/tag/v0.1.2
[0.1.1]: https://github.com/nadav-cheung/DeepFind/releases/tag/v0.1.1
[0.1.0]: https://github.com/nadav-cheung/DeepFind/releases/tag/v0.1.0
