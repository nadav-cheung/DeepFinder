# Changelog

All notable changes to DeepFinder (Rust edition) are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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

[0.1.0]: https://github.com/nadav-cheung/DeepFinder/releases/tag/v0.1.0
