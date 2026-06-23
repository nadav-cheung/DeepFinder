# CLAUDE.md — DeepFinder

macOS local file search (filename + content). Rust workspace; hybrid plocate-style filename index (pread) + zoekt-style content shards (mmap) behind one trigram candidate engine; resident daemon + thin CLI over Unix socket. Full architecture: `docs/architecture.md`; end-state choices: `docs/tech-selection.md`.

## Build gates (all must pass before commit)
`cargo fmt --check` · `cargo clippy --workspace --all-targets -D warnings` · `cargo test --workspace`

## Workflow
- Trunk-based solo repo — **commit directly to `main`** (don't branch). Conventional commits: `feat(cli):`, `docs:`, `test(filter):`, `fix(filter):`.
- TDD: write the failing test first, watch it fail, then implement.

## Hard constraints
- **`df-core` is pure — ZERO I/O.** Engine/codec logic operates on `DbSource` / `CandidateSource` traits only; never add file or network I/O there (keeps it unit-testable).

## Test gotchas
- macOS FS is case-insensitive: test files differing only in case (`Foo.txt`/`foo.txt`) collide — put them in separate subdirs.
- Never point tests at the global `~/.deep-finder/`. Use `tempfile::tempdir` + a temp socket (pattern in `crates/deepfindd/tests/serve.rs`).

## Shell
- zsh expands unquoted globs — always quote: `--include='*.rs'`, not `--include=*.rs`.
