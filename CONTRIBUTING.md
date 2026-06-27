# Contributing to DeepFind

DeepFind is a macOS local file search tool (filename + content search). It is a Rust workspace: a hybrid plocate-style filename index (pread) + zoekt-style content shards (mmap) behind one trigram candidate engine, with a resident daemon and a thin CLI over a Unix socket.

Thanks for your interest in contributing! This guide captures the project's conventions so changes land clean and green.

## Build gates (all must pass before commit)

```
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Note: clippy needs the `--` before `-D warnings` so the flag is passed to clippy rather than cargo. All three must pass on `main`.

## Run

```
cargo build --workspace --release
deepfind index --root <path>
deepfind daemon            # run in the background
deepfind search <query>
```

Daemon down? The CLI auto-falls back to a `--direct` online scan.

## Workflow

- **Trunk-based** — commit directly to `main`; don't branch.
- **Conventional Commits**, e.g. `feat(cli):`, `fix(daemon):`, `docs:`, `test(filter):`, `refactor:`.

## TDD

Write the failing test first, watch it fail, then implement, then watch it pass. A change isn't done until the test goes red → green.

## Hard constraints

These are load-bearing invariants — violating them causes bugs or false negatives:

- **`df-core` is pure — ZERO I/O.** Engine/codec logic operates on `DbSource` / `CandidateSource` traits only. Never add file or network I/O there (this is what keeps it unit-testable).
- **Candidate generation is always case-insensitive (folded bytes) and a superset.** Case (`-s` / `-i` / smart-case) and regex apply ONLY at the `cs_verify` step, never at the trigram/posting stage. Violating this causes false negatives.

## Test gotchas (macOS)

- The macOS filesystem is **case-insensitive**: test files differing only in case (`Foo.txt` / `foo.txt`) collide — put them in separate subdirs.
- Never point tests at the global `~/.deep-find/`. Use `tempfile::tempdir` plus a temp socket (see the pattern in `crates/deepfindd/tests/serve.rs`).

## Shell

zsh expands unquoted globs — always quote them: `--glob='*.rs'`, not `--glob=*.rs`.

## More

Full architecture: `docs/architecture.md`. End-state tech choices: `docs/tech-selection.md`.
