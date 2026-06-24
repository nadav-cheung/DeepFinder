# DeepFinder

A fast local file search engine for macOS — **filename + content** search in one
tool. Filename search is inspired by [Everything](https://www.voidtools.com/) /
[plocate](https://plocate.sesse.net/); content search by
[ripgrep](https://github.com/BurntSushi/ripgrep) /
[zoekt](https://github.com/sourcegraph/zoekt).

> **Status: Rust rewrite shipped.** Dual-layer trigram index — plocate-style
> filename layer (pread) + zoekt-style content shards (mmap) — behind one shared
> candidate engine, served by a resident daemon over a Unix socket to a thin CLI.
> The non-UI scope is feature-complete (Phases A–F delivered, 136 tests green).
> GUI / interactive TUI are deferred.
>
> Full architecture: [`docs/architecture.md`](docs/architecture.md);
> end-state choices: [`docs/tech-selection.md`](docs/tech-selection.md).

## What it does

- **Filename + content in one query** — results merged and de-duped by path.
- **Match modes** — literal substring (default), `--regex`, smart-case (default)
  with `-i`/`-s`.
- **Filters** — `-t/--type` (code/docs/config/web/archive/media), `-e/--extension`,
  `-E/--exclude`, `-g/--glob`, `-d/--max-depth`, `--scope`, `--limit`,
  `--max-results`, `--sort {default|path|kind|none}`.
- **Content** — `-n/--line-number` + `-C/--context` (grep parity), `--content` /
  `--filename` layer select.
- **Expression language** — `--expr` (`-name/-path/-size/-newer` + boolean + parens).
- **Multi-DB** — `deepfind db add/remove/list`; `search --db <name>`.
- **Process model** — resident daemon + thin CLI; daemon down → CLI auto-falls
  back to `--direct` online scan.
- **Incremental** — `df-watch` (notify/FSEvents watcher) hot-swaps shards live
  (env `DEEPFIND_WATCH`).

## Architecture (6-crate workspace, acyclic)

- **`df-core`** — trigram index DB format + TurboPFor codec + query engine
  (pure library, **zero I/O**)
- **`df-content`** — zoekt-style content shard builder/reader + ASCII fold
- **`df-index`** — `ignore` parallel traversal → atomic single-file DB + shards;
  multi-DB registry; `df-watch` watcher
- **`df-ipc`** — Unix socket protocol (length-framed, streamed) + filters + bfs parser
- **`deepfindd`** — resident daemon (pread filename + mmap content, ArcSwap hot-swap)
- **`deepfind`** — thin CLI (daemon client + `--direct` fallback + exec/highlight)

## Build gates (all green before commit)

```sh
cargo build --workspace --release
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --check
```

## Install (macOS)

**Homebrew** (installs to the standard path `/opt/homebrew/bin`):
```sh
brew install nadav-cheung/tap/deepfind
```

**Or one-line script:**
```sh
curl -LsSf https://github.com/nadav-cheung/DeepFinder/releases/latest/download/deepfind-installer.sh | sh
```

**Start the background daemon** (registers `$HOME`; the daemon background-indexes it on start, live-updates on file changes, starts at login):
```sh
deepfind install          # registers $HOME + installs a launchd agent
deepfind status           # shows index freshness: indexing → fresh
deepfind search "needle"
deepfind uninstall        # stops the daemon + removes the launchd agent
```
Update later with `brew upgrade deepfind` — launchd auto-restarts the new binary.

## License

MIT.
