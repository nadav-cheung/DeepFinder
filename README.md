# DeepFinder

A fast local file search engine for macOS, inspired by [Everything](https://www.voidtools.com/) on Windows.

> **Status: Rust rewrite in progress.** The search + index + CLI are being rebuilt
> from scratch in Rust (clean slate). Design spec:
> [`docs/superpowers/specs/2026-06-22-rust-search-index-cli-design.md`](docs/superpowers/specs/2026-06-22-rust-search-index-cli-design.md).

## Architecture (v1)

- **`df-core`** — trigram index DB format + TurboPFor codec + query algorithm (pure library, no I/O)
- **`df-index`** — indexer: `ignore` parallel traversal → single-file DB (atomic write)
- **`df-ipc`** — Unix socket protocol (length-framed, streamed results)
- **`deepfindd`** — resident daemon (pread, low-RSS query)
- **`deepfind`** — thin CLI (daemon client + `--direct` online fallback)

File-level trigram index, plocate-style single-file DB, TurboPFor-compressed posting
lists, Robin Hood trigram table, boolean (AND/OR/NOT) queries.

## Build

```sh
cargo build --release
cargo test --all
```

## License

MIT.
