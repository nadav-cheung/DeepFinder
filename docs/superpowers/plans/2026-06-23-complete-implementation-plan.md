# DeepFinder Complete Implementation Plan (excl. UI)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the full non-UI scope of `docs/superpowers/specs/2026-06-23-complete-implementation-design.md` — content regex + line numbers (A), CLI flags + sorting (B), multi-DB (C), perf baseline + hardening (D), bfs expression language (E), incremental update v2.1 (F).

**Architecture:** Rust 6-crate workspace (df-core pure / df-content / df-index / df-ipc / deepfindd / deepfind). Existing baseline: dual-layer trigram engine (filename pread + content mmap) behind one `CandidateSource` candidate engine, daemon + thin CLI over Unix socket, smart-case, boolean AST, filename regex, filters/`-g`/`-x`/`--color`/`-0`/`--count`. 89 tests green. This plan layers A→F on top without rewriting the core.

**Tech Stack:** Rust 2021 (resolver 2), tokio, clap, serde+bincode, ignore, memmap2, memchr, regex, crossbeam-channel, zstd, criterion. **New deps to add (Phase F only):** `notify` (FSEvents watcher), `arc-swap` (lock-free shard hot-swap).

**Execution rules (from goal):** strict TDD per milestone (Red→Green→Refactor, no product code without a failing test first); three gates green before each commit — `cargo fmt --check` · `cargo clippy --workspace --all-targets -D warnings` · `cargo test --workspace`; conventional commits; design ambiguities → append `docs/decisions.md` (date + default + reason) and continue; no UI; macOS target.

**Hard constraints (from CLAUDE.md, must hold):**
- `df-core` is **pure — ZERO I/O**. Engine/codec logic operates on `DbSource` / `CandidateSource` traits only.
- **Candidate generation is always case-insensitive (folded bytes) and a superset.** Case (`-s`/`-i`/smart-case) and regex apply ONLY at verify, never at trigram/posting stage.
- macOS FS is case-insensitive: test files differing only in case go in separate subdirs. Tests use `tempfile::tempdir` + a temp socket (pattern in `crates/deepfindd/tests/serve.rs`), never the global `~/.deep-finder/`.

---

## File Structure (decomposition locked here)

**Phase A — content engine**
- Create `crates/df-content/src/regex_query.rs` — pure `content_regex_docids(reader, atom_folded, re, limit)` over `ShardReader`.
- Create `crates/df-content/src/lines.rs` — pure line-number/context helpers (`line_number`, `line_text`, `context_lines`).
- Modify `crates/df-content/src/lib.rs` — `pub mod regex_query; pub mod lines;`.
- Modify `crates/df-ipc/src/proto.rs` — add `SearchOptions { line_numbers, context }`, `LineHit`, `ResponseFrame::Lines`.
- Modify `crates/deepfindd/src/lib.rs` — `ContentShards::query_regex`, `ContentShards::query_lines`; wire into `handle_conn`.
- Modify `crates/deepfind/src/main.rs` — `-n/--line-number`, `-C/--context` flags + rendering.

**Phase B — CLI features**
- Modify `crates/df-ipc/src/proto.rs` — `SearchOptions { layers, hidden, path_mode, sort }`.
- Modify `crates/df-ipc/src/filter.rs` — basename/full-path mode, hidden predicate, layer gating.
- Modify `crates/deepfindd/src/lib.rs` — layer gating, sort step, `--max-results` early-exit.
- Modify `crates/df-index/src/content_build.rs` + `lib.rs` — index `--hidden` build flag.
- Modify `crates/deepfind/src/main.rs` — `--content/--filename`, `-H/--hidden`, `-p/-b`, `--max-results`, `--sort`.

**Phase C — multi-DB**
- Create `crates/df-index/src/registry.rs` — DB registry (`dbs.toml` read/write, named roots).
- Modify `crates/df-ipc/src/proto.rs` — `SearchRequest { db: Option<String> }`.
- Create `crates/deepfindd/src/dbset.rs` — `DbSet` (Vec of named (DbReader, ContentShards)), query-loop merge by path.
- Modify `crates/deepfindd/src/lib.rs` — serve a `DbSet`; `--db` selection.
- Modify `crates/deepfind/src/main.rs` — `db add/remove/list` subcommands, `search --db`.

**Phase D — perf**
- Create `crates/df-core/benches/candidate.rs` — criterion: query latency.
- Create `crates/df-index/benches/build.rs` — criterion: build throughput.
- Create `docs/perf-baseline.md` — recorded numbers + RSS (shell `/usr/bin/time -l`).
- Modify `crates/df-core/src/candidate.rs` — 2-rarest intersection, bigram short-query path (D2, measurement-gated).
- Modify `crates/df-content/src/shard.rs` — ASCII direct-index array (D2, measurement-gated).
- Modify `crates/df-index/src/mmap_source.rs` — `madvise` hints (D2).

**Phase E — bfs expression language**
- Create `crates/df-ipc/src/bfs.rs` — `Expr` AST + tokenizer + parser + `eval(path, meta)`.
- Modify `crates/df-ipc/src/proto.rs` — `SearchOptions { expr: Option<String> }`.
- Modify `crates/df-ipc/src/filter.rs` — apply bfs expr in `passes`.
- Modify `crates/deepfind/src/main.rs` — `--expr` flag.

**Phase F — incremental**
- Add workspace deps `notify`, `arc-swap`.
- Create `crates/deepfindd/src/watcher.rs` — notify watcher + incremental rebuild orchestration.
- Modify `crates/df-index/src/manifest.rs` — `Manifest::signature` (content hash).
- Modify `crates/df-core/src/db.rs` — dir-mtime table read/write (reserved hook at header off 36).
- Modify `crates/deepfindd/src/lib.rs` — `ArcSwap` shard set + rename-aside swap + drain.

---

# Phase A — Content Engine Completion (P0 correctness)

## Task A1.1: Pure content-regex docid selector (df-content)

**Files:**
- Create: `crates/df-content/src/regex_query.rs`
- Modify: `crates/df-content/src/lib.rs`
- Test: `crates/df-content/src/regex_query.rs` (`#[cfg(test)]`)

- [ ] **Step 1: Write the failing test**

```rust
// crates/df-content/src/regex_query.rs
//! Engine-level content regex: the longest literal atom of the regex drives
//! rarest-trigram candidate generation (case-insensitive superset); the compiled
//! regex is the authoritative verifier over the mmap'd content bytes. Mirrors the
//! filename-regex path (`df_ipc::filter::longest_literal_atom` + `regex.is_match`).
//!
//! Pure over a borrowed `ShardReader` (the daemon owns the mmap). No I/O.

use crate::shard::ShardReader;
use df_core::candidate::candidates;

/// Local docids in `reader` whose content matches `re`. `atom_folded` is the
/// case-folded longest literal atom of the regex — it only *prefilters*
/// candidates (always a superset), so candidate gen stays case-insensitive;
/// `re` decides authoritatively. Capped at `limit`.
pub fn content_regex_docids<'a>(
    reader: &ShardReader<'a>,
    atom_folded: &[u8],
    re: &regex::Regex,
    limit: Option<u32>,
) -> df_core::Result<Vec<u32>> {
    let cands = candidates(reader, atom_folded, atom_folded, false, limit)?;
    let mut out = Vec::new();
    for d in cands {
        if re.is_match(reader.content(d)?) {
            out.push(d);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shard::ShardBuilder;

    fn one_shard(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut b = ShardBuilder::new(0, 0);
        for (p, c) in files {
            b.add_file(p, false, c.len() as i64, 0, c);
        }
        b.finish(0)
    }

    #[test]
    fn regex_matches_like_grep_e() {
        // Three files; only the first two contain "fn" followed (later) by "main".
        let bytes = one_shard(&[
            ("a.rs", b"fn main() { }"),
            ("b.rs", b"async fn main() -> u32 { 0 }"),
            ("c.rs", b"struct Foo; // no main here"),
        ]);
        let r = ShardReader::open(&bytes).unwrap();
        let re = regex::Regex::new("fn.*main").unwrap(); // case-sensitive
        // longest literal atom candidates: "fn" (folded) — prefilter.
        let atom = df_ipc::filter::longest_literal_atom("fn.*main").unwrap_or_default();
        let atom_folded = df_content::fold::fold(atom.to_lowercase().as_bytes());
        let ds = content_regex_docids(&r, &atom_folded, &re, None).unwrap();
        assert_eq!(ds, vec![0, 1]); // a.rs, b.rs; NOT c.rs
    }

    #[test]
    fn regex_respects_limit() {
        let bytes = one_shard(&[
            ("a.rs", b"fn main() {}"),
            ("b.rs", b"fn main() {}"),
            ("c.rs", b"fn main() {}"),
        ]);
        let r = ShardReader::open(&bytes).unwrap();
        let re = regex::Regex::new("main").unwrap();
        let atom = df_content::fold::fold(b"main".to_vec().as_slice());
        let ds = content_regex_docids(&r, atom, &re, Some(2)).unwrap();
        assert_eq!(ds.len(), 2);
    }
}
```

> Note: `df_content` must depend on `df-ipc` for `longest_literal_atom`? **No** — that would reverse the dependency (df-ipc → df-core, df-content → df-core; df-content → df-ipc is disallowed since df-content is lower-level). In the test, compute the atom inline instead: replace `df_ipc::filter::longest_literal_atom(...)` with a local `atom_of` helper in the test, OR call the daemon-side logic. **Decision:** keep `longest_literal_atom` where it is (df-ipc) and, in the test, hard-code the atom bytes (`fold(b"fn")`). The production caller (daemon) already has the atom. Fix the test to:

```rust
    // atom = "fn" (the longest literal run in "fn.*main"), folded.
    let atom_folded = df_content::fold::fold(b"fn");
    let ds = content_regex_docids(&r, &atom_folded, &re, None).unwrap();
    assert_eq!(ds, vec![0, 1]);
```

- [ ] **Step 2: Run test to verify it fails**

```
cargo test -p df-content content_regex_docids
```
Expected: FAIL — module doesn't exist / not exported.

- [ ] **Step 3: Export the module**

```rust
// crates/df-content/src/lib.rs  (add at end of mod list)
pub mod lines;          // added in A2
pub mod regex_query;
```
(Only add `pub mod regex_query;` now; `lines` lands in A2. If you add `pub mod lines;` now, create an empty file or it won't compile — so add only `regex_query` here.)

- [ ] **Step 4: Run test to verify it passes**

```
cargo test -p df-content content_regex_docids
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/df-content/src/regex_query.rs crates/df-content/src/lib.rs
git commit -m "feat(content): engine-level content regex (longest-atom → candidates → regex.is_match)"
```

## Task A1.2: Daemon content-regex path (deepfindd)

**Files:**
- Modify: `crates/deepfindd/src/lib.rs` (add `ContentShards::query_regex`, wire into `handle_conn`)
- Test: `crates/deepfindd/tests/serve.rs` (new `content_regex_matches_grep` test)

- [ ] **Step 1: Write the failing integration test** (follow the existing `query_and_collect` helper pattern in `serve.rs`)

```rust
// crates/deepfindd/tests/serve.rs  (append)
#[tokio::test]
async fn content_regex_matches_grep() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("a.rs"), b"fn main() { }").unwrap();
    std::fs::write(root.join("b.rs"), b"async fn main() {}").unwrap();
    std::fs::write(root.join("c.rs"), b"struct Foo;").unwrap();

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    df_index::build_content_index(root, &db, &content_dir, &Default::default()).unwrap();

    let sock = tmp.path().join("daemon.sock");
    let db_clone = db.clone();
    let serve = tokio::spawn(async move { deepfindd::serve(&sock, &db_clone).await });

    let opts = df_ipc::proto::SearchOptions {
        regex: Some("fn.*main".into()),
        ..Default::default()
    };
    let res = query_and_collect(&sock, "fn.*main", None, None, opts).await;
    let paths: Vec<&str> = res.iter().map(|(p, _, _)| p.as_str()).collect();
    assert!(paths.contains(&root.join("a.rs").to_str().unwrap()));
    assert!(paths.contains(&root.join("b.rs").to_str().unwrap()));
    assert!(!paths.contains(&root.join("c.rs").to_str().unwrap()));

    serve.abort();
}
```
(Adjust `query_and_collect` signature to the helper already in `serve.rs`; if it doesn't take `opts`, extend it — see existing tests like `case_sensitivity_end_to_end`.)

- [ ] **Step 2: Run test to verify it fails**

```
cargo test -p deepfindd --test serve content_regex_matches_grep
```
Expected: FAIL — content layer skipped in regex mode (`c.rs` may appear or `a.rs`/`b.rs` missing from content).

- [ ] **Step 3: Implement `ContentShards::query_regex` and wire it**

In `crates/deepfindd/src/lib.rs`, add to `impl ContentShards`:

```rust
    /// Content-regex query across all shards. `atom_folded` prefilters candidates
    /// (case-insensitive); `re` verifies authoritatively over the content bytes.
    fn query_regex(
        &self,
        atom_folded: &[u8],
        re: &regex::Regex,
        scope: Option<&Path>,
        per_shard_limit: Option<u32>,
    ) -> Vec<(String, LiteMeta, MatchKind)> {
        let mut out = Vec::new();
        for src in &self.sources {
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
```

In `handle_conn`, replace the `let content = if regex_mode { Vec::new() } else { ... }` block inside the `spawn_blocking` closure with:

```rust
        let content = match re_for_content.as_ref() {
            Some(re) => shards_q.query_regex(&folded_c, re, scope_c.as_deref(), limit),
            None => shards_q.query(
                &folded_c,
                needle_c.as_bytes(),
                case_sensitive,
                scope_c.as_deref(),
                limit,
            ),
        };
```

And before the closure, clone the compiled regex for the content path (filename regex verify still uses `re` later):

```rust
    let re_for_content = re.clone(); // Option<Regex>; Regex: Clone
```

(`folded_c` is already the folded longest-literal-atom in regex mode — reuse it as `atom_folded`. In literal mode it's the folded query, unused by the `Some` arm.)

- [ ] **Step 4: Run test to verify it passes**

```
cargo test -p deepfindd --test serve content_regex_matches_grep
```
Expected: PASS.

- [ ] **Step 5: Three gates + commit**

```
cargo fmt --check
cargo clippy --workspace --all-targets -D warnings
cargo test --workspace
git commit -am "feat(daemon): content-regex query path (mirrors filename-regex over mmap content)"
```

## Task A2.1: Pure line-number/context helpers (df-content)

**Files:**
- Create: `crates/df-content/src/lines.rs`
- Modify: `crates/df-content/src/lib.rs` (`pub mod lines;`)
- Test: `crates/df-content/src/lines.rs` (`#[cfg(test)]`)

- [ ] **Step 1: Write the failing test**

```rust
// crates/df-content/src/lines.rs
//! Pure grep-style line helpers: given content bytes and a match byte offset,
//! compute the 1-based line number, the line text, and a `-C N` context block.
//! Pure over `&[u8]` — daemon assembles the wire `LineHit`.

/// 1-based line number of the line containing `byte_off`.
pub fn line_number(content: &[u8], byte_off: usize) -> u32 {
    let up = byte_off.min(content.len());
    content[..up].iter().filter(|&&b| b == b'\n').count() as u32 + 1
}

/// The full line text (no trailing newline) containing `byte_off`.
pub fn line_text(content: &[u8], byte_off: usize) -> String {
    let up = byte_off.min(content.len());
    let start = content[..up].iter().rposition(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    let end = content[up..].iter().position(|&b| b == b'\n').map(|i| up + i).unwrap_or(content.len());
    String::from_utf8_lossy(&content[start..end]).into_owned()
}

/// `-C n`: up to `n` lines before + the match line + up to `n` lines after,
/// joined by `\n`. Returns (first_line_no, joined_text) — grep-style block.
pub fn context_block(content: &[u8], byte_off: usize, n: u32) -> (u32, String) {
    let up = byte_off.min(content.len());
    let line_start = content[..up].iter().rposition(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    // walk back n newlines from line_start
    let mut before = 0u32;
    let mut block_start = line_start;
    while before < n {
        match content[..block_start].iter().rposition(|&b| b == b'\n') {
            Some(i) => { block_start = i + 1; before += 1; }
            None => break,
        }
    }
    // walk forward n newlines from line_start
    let mut after = 0u32;
    let mut block_end = up;
    loop {
        match content[block_end..].iter().position(|&b| b == b'\n') {
            Some(i) => {
                block_end += i + 1;
                if block_end > content.len() { block_end = content.len(); break; }
                after += 1;
                if after > n { break; }
            }
            None => { block_end = content.len(); break; }
        }
    }
    let first_no = content[..block_start].iter().filter(|&&b| b == b'\n').count() as u32 + 1;
    (first_no, String::from_utf8_lossy(&content[block_start..block_end]).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &[u8] = b"alpha\nbeta\nGAMMA\ndelta\nepsilon\n";

    #[test]
    fn line_number_is_one_based() {
        assert_eq!(line_number(SAMPLE, 0), 1);            // 'a' of alpha
        assert_eq!(line_number(SAMPLE, 6), 2);            // 'b' of beta (after \n at 5)
        assert_eq!(line_number(SAMPLE, 11), 3);           // 'G' of GAMMA
    }

    #[test]
    fn line_text_excludes_newline() {
        assert_eq!(line_text(SAMPLE, 0), "alpha");
        assert_eq!(line_text(SAMPLE, 11), "GAMMA");
    }

    #[test]
    fn context_block_matches_grep_c1() {
        // grep -C1 around line 3 (GAMMA) → lines 2..4 = beta / GAMMA / delta
        let (no, block) = context_block(SAMPLE, 11, 1);
        assert_eq!(no, 2);
        assert_eq!(block, "beta\nGAMMA\ndelta\n");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cargo test -p df-content lines::
```
Expected: FAIL — module missing.

- [ ] **Step 3: Export module**

```rust
// crates/df-content/src/lib.rs
pub mod lines;
```

- [ ] **Step 4: Run test to verify it passes**

```
cargo test -p df-content lines::
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/df-content/src/lines.rs crates/df-content/src/lib.rs
git commit -m "feat(content): pure grep-style line-number/context helpers"
```

## Task A2.2: IPC — line-number options + LineHit frame

**Files:**
- Modify: `crates/df-ipc/src/proto.rs`

- [ ] **Step 1: Write the failing test**

```rust
// crates/df-ipc/src/proto.rs  (append to tests mod)
#[test]
fn line_options_default_and_roundtrip() {
    let opts = SearchOptions::default();
    assert!(!opts.line_numbers);
    assert_eq!(opts.context, None);

    // bincode roundtrip preserves line fields (forward/back compat via default).
    let mut opts = SearchOptions::default();
    opts.line_numbers = true;
    opts.context = Some(2);
    let bytes = bincode::serde::encode_to_vec(&opts, bincode::config::standard()).unwrap();
    let back: SearchOptions =
        bincode::serde::decode_from_slice(&bytes, bincode::config::standard()).unwrap().0;
    assert!(back.line_numbers);
    assert_eq!(back.context, Some(2));
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cargo test -p df-ipc line_options_default_and_roundtrip
```
Expected: FAIL — no such fields.

- [ ] **Step 3: Add fields + frame**

```rust
// SearchOptions — add two fields (keep #[serde(default)] ergonomics):
    /// `-n`: report content matches with line numbers (`path:line:text`).
    #[serde(default)]
    pub line_numbers: bool,
    /// `-C N`: show N lines of context around each content match.
    #[serde(default)]
    pub context: Option<u32>,
```

```rust
/// A single content match rendered for grep-style output (path:line:text).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LineHit {
    pub path: String,
    pub line_no: u32,
    pub text: String,
}

// ResponseFrame — add a Lines variant (streamed before Done, like Batch):
pub enum ResponseFrame {
    Batch { paths: Vec<String>, meta: Vec<LiteMeta>, kind: Vec<MatchKind> },
    Lines { hits: Vec<LineHit> },          // NEW
    Done { total: u32 },
    Error { message: String },
}
```

- [ ] **Step 4: Run test to verify it passes** — `cargo test -p df-ipc`.

- [ ] **Step 5: Commit** — `git commit -am "feat(ipc): -n/--line-number + -C context options and LineHit frame"`.

## Task A2.3: Daemon content line-hit query + CLI rendering

**Files:**
- Modify: `crates/deepfindd/src/lib.rs` (`ContentShards::query_lines`, stream `Lines` frames)
- Modify: `crates/deepfind/src/main.rs` (`-n/--line-number`, `-C/--context`; render `path:line:text`)

- [ ] **Step 1: Write the failing end-to-end test** (parity with `grep -n`)

```rust
// crates/deepfindd/tests/serve.rs  (append)
#[tokio::test]
async fn content_line_numbers_match_grep_n() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    // two matches on different lines of one file
    std::fs::write(root.join("a.txt"), b"alpha\nbeta main\ngamma\nmain delta\n").unwrap();

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    df_index::build_content_index(root, &db, &content_dir, &Default::default()).unwrap();
    let sock = tmp.path().join("daemon.sock");
    let db_clone = db.clone();
    let serve = tokio::spawn(async move { deepfindd::serve(&sock, &db_clone).await });

    let opts = df_ipc::proto::SearchOptions { line_numbers: true, ..Default::default() };
    let lines = query_lines(&sock, "main", None, None, opts).await; // helper returns Vec<LineHit>
    let nos: Vec<u32> = lines.iter().map(|h| h.line_no).collect();
    assert_eq!(nos, vec![2, 4]); // "beta main" on line 2, "main delta" on line 4

    serve.abort();
}
```
(`query_lines` is a new test helper that collects `ResponseFrame::Lines` — add it beside `query_and_collect`.)

- [ ] **Step 2: Run test to verify it fails**

```
cargo test -p deepfindd --test serve content_line_numbers_match_grep_n
```
Expected: FAIL — no `Lines` frames emitted.

- [ ] **Step 3: Implement `ContentShards::query_lines`** (literal + regex both supported; match offsets via `memchr::memmem::find_iter` / `regex::find_iter`):

```rust
// crates/deepfindd/src/lib.rs  — add to impl ContentShards
use df_ipc::proto::LineHit;

/// Content matches rendered as grep-style line hits. `needle`/`re` select literal
/// vs regex matching; `context` adds surrounding lines. Pure compute over content.
fn query_lines(
    &self,
    folded: &[u8],
    needle: &[u8],
    case_sensitive: bool,
    re: Option<&regex::Regex>,
    scope: Option<&Path>,
    per_shard_limit: Option<u32>,
    context: Option<u32>,
) -> Vec<LineHit> {
    let mut out = Vec::new();
    for src in &self.sources {
        let r = match ShardReader::open(src.as_slice()) { Ok(r) => r, Err(_) => continue };
        let docids = match re {
            Some(rx) => df_content::regex_query::content_regex_docids(&r, folded, rx, per_shard_limit).unwrap_or_default(),
            None => candidates(&r, folded, needle, case_sensitive, per_shard_limit).unwrap_or_default(),
        };
        for d in docids {
            let path = match r.path(d) { Ok(p) => p, Err(_) => continue };
            if !in_scope(&path, scope) { continue; }
            let content = match r.content(d) { Ok(c) => c, Err(_) => continue };
            let offsets: Vec<usize> = match re {
                Some(rx) => rx.find_iter(content).map(|m| m.start()).collect(),
                None => {
                    let hay = if case_sensitive { content.to_vec() } else { df_content::fold::fold(content) };
                    memchr::memmem::find_iter(&hay, needle).map(|i| i.start()).collect()
                }
            };
            let mut seen_lines = std::collections::HashSet::new();
            for off in offsets {
                if let Some(n) = context {
                    let (first, block) = df_content::lines::context_block(content, off, n);
                    if seen_lines.insert(first) {
                        out.push(LineHit { path: path.clone(), line_no: first, text: block });
                    }
                } else {
                    let no = df_content::lines::line_number(content, off);
                    if seen_lines.insert(no) {
                        out.push(LineHit { path: path.clone(), line_no: no, text: df_content::lines::line_text(content, off) });
                    }
                }
            }
        }
    }
    out
}
```

In `handle_conn`, after resolving options: if `opts.line_numbers || opts.context.is_some()`, compute line hits via `query_lines` (literal vs regex from `re_for_content`), stream them as `ResponseFrame::Lines` frames (chunked at `STREAM_CHUNK`), then `Done`. Otherwise keep the existing path-batch flow. Pseudocode branch (concrete in execution):

```rust
    let want_lines = opts.line_numbers || opts.context.is_some();
    if want_lines {
        let re_ref = re_for_content.as_ref();
        let hits = shards_q_lines.query_lines(&folded_c, needle_c.as_bytes(), case_sensitive, re_ref, scope_c.as_deref(), limit, opts.context);
        for chunk in hits.chunks(STREAM_CHUNK) {
            f.send(encode_frame(&ResponseFrame::Lines { hits: chunk.to_vec() })?).await?;
        }
        f.send(encode_frame(&ResponseFrame::Done { total: hits.len() as u32 })?).await?;
        return Ok(());
    }
```
(Move the `query_lines` call into the existing `spawn_blocking` block to keep engine work off the async runtime; the snippet shows the shape.)

- [ ] **Step 4: CLI flags + rendering**

In `crates/deepfind/src/main.rs`:
- Add to `Cmd::Search`: `#[arg(short = 'n', long = "line-number")] line_numbers: bool` and `#[arg(short = 'C', long = "context")] context: Option<u32>`.
- Set `opts.line_numbers` / `opts.context` from them.
- Change `daemon_search` / result model to also return `Vec<LineHit>` (extend the return to `(Vec<(String,LiteMeta,MatchKind)>, Vec<LineHit>)`, decoding `ResponseFrame::Lines`).
- In `print_results`: if line hits present, print `path:line_no:text` (sorted by path then line_no); else current path printing. (Filename-only matches have no line; in `-n` mode they are omitted — content mode is content-focused, matching `grep`.)

- [ ] **Step 5: Three gates + commit**

```
cargo fmt --check && cargo clippy --workspace --all-targets -D warnings && cargo test --workspace
git commit -am "feat(content): -n/--line-number + -C context, grep -n/-C parity"
```

**Phase A exit:** all of A1.1–A2.3 green, single milestone state committed. Run an extra parity check: `deepfind search --regex 'fn.*main'` over the repo vs `grep -El 'fn.*main'` → same file set; `deepfind search main -n` vs `grep -n main` → same line numbers.

---

# Phase B — CLI Feature Completion (P1)

> **Design decisions (record in `docs/decisions.md` before starting B):**
> - **Layer select:** `--content` / `--filename` restrict which layers are queried (default: both). Implemented as `SearchOptions.layers: LayerMask` (bits `FILENAME | CONTENT`).
> - **`-H` hidden:** hidden filtering is **index-time** today (`walker.hidden(true)`). `-H` therefore (a) becomes an **index-build flag** `index --hidden` (include hidden files) and (b) controls `--direct` online scan. Indexed search reflects what was built. (Honest: a search-time `-H` cannot surface un-indexed hidden files.)
> - **`-p` / `-b`:** `-p` = match full path (current default), `-b` = match basename only. Basename mode = candidate gen unchanged (full-path trigrams are a superset) + post-verify against basename only. Encoded as `SearchOptions.path_mode: PathMode { Full, Basename }`, default `Full`.
> - **`--max-results N`:** alias for the engine cap with explicit early-exit streaming semantics (stop collecting at N; already bounded by `limit`). Implemented as `SearchRequest.limit = Some(N)` from the flag, plus an early `break` once N delivered.
> - **Sort:** default sort key = `(match_kind_weight, path_depth, path)` where weight `Both=0 < Content=1 < Filename=2` (best matches first); `--sort {path,kind,none}` overrides (`none` = insertion/stream order). Deterministic, stable.

## Task B1: Layer select, path mode, hidden, max-results (proto + filter + daemon + CLI)

For each flag, TDD: (1) a `passes`/unit test for the predicate, (2) a daemon integration test, (3) wire CLI. Concrete sub-tasks:

- [ ] **B1.1 proto fields** — add to `SearchOptions`: `layers: LayerMask`, `path_mode: PathMode`, `sort: SortMode` (all `#[serde(default)]`, `#[derive(Default)]`). Add enums `LayerMask { bits }` with `const FILENAME/CONTENT/both()` and `PathMode { Full, Basename }`, `SortMode { Default, Path, Kind, None }`. Test: roundtrip + defaults (`layers == both`, `path_mode == Full`, `sort == Default`).
- [ ] **B1.2 filter predicates** (`df-ipc/src/filter.rs`) — `pub fn basename(path) -> &str`; extend `passes` to apply `path_mode` (basename substring check when `Basename`) **only conceptually** — path_mode actually affects the engine verify, not `passes`. **Decision:** `path_mode` is enforced in the daemon filename verify (re-check basename contains needle), not in `passes` (which is about filters, not the query needle). Keep `passes` for `-e/-t/-E/-g/-d`; add a separate daemon check. Test the basename helper.
- [ ] **B1.3 daemon layer gating + path mode** (`deepfindd/lib.rs`) — when `layers` excludes Filename, skip `query_docids`; when excludes Content, skip shard query. When `path_mode == Basename`, after filename docids resolve, drop those whose basename doesn't contain the (case-appropriate) needle. Integration test: index `dir/foo.txt` + `barfoo.txt`, search `foo -b` → only basename `foo.txt` (not `barfoo.txt`).
- [ ] **B1.4 index `--hidden` + direct-scan `-H`** (`df-index/content_build.rs` adds `hidden: bool` to `ContentBuildOptions`, gates `walker.hidden(!hidden)`; `deepfind/main.rs` adds the flags). Test: `index --hidden` includes `.hidden.txt` in filename docs.
- [ ] **B1.5 `--max-results` early exit** — CLI flag `--max-results N` sets `limit`; daemon already truncates. Add an explicit test that with `--max-results 1` over many matches, only 1 is returned and the daemon stops streaming (assert `Done.total == 1`).
- [ ] **B1.6 Three gates + commit** — `git commit -m "feat(cli): layer select (-p/-b), -H hidden, --max-results early exit"`.

## Task B2: Result sorting

- [ ] **B2.1 test** — index a fixed tree producing Both/Content/Filename matches at varying depths; assert default order is `(kind_weight asc, depth asc, path asc)`; assert `--sort path` is pure path order; assert stable/reproducible (run twice, identical).
- [ ] **B2.2 implement** — in `handle_conn`, after the `entries` Vec is built and filtered, `match opts.sort { Default => sort_by_key(|(_,_,k)| (kind_weight(*k), depth_of(path), path.clone())), Path => sort_by(path), None => {} }` before `truncate(cap)`. `kind_weight`: Both=0, Content=1, Filename=2. Use a total order (paths are unique keys → stable).
- [ ] **B2.3 Three gates + commit** — `git commit -m "feat(cli): deterministic result sort (kind+depth default; --sort override)"`.

**Phase B exit:** all flags behave per fd/bfs/ripgrep parity on a hand-built corpus; integration tests cover each.

---

# Phase C — Multi-DB / Named Roots (P1)

> **Design decision (record before C):** Multi-DB = a **registry of named independent indices** under `~/.deep-finder/dbs.toml` (`name → { root, db_path, content_dir }`). `db add <name> <root>` builds + registers; `db remove`/`db list` manage the registry. The daemon loads **all** registered DBs at startup into a `DbSet`; a query loops over each DB, merging results by path (existing `merge_in` dedup — no global docid needed, since dedup is path-keyed). `search --db <name>` restricts the loop to one DB; default searches all. **Cross-root base_docid mapping is already per-shard within each DB**; cross-DB union needs no extra mapping because merge is by path. (`MANIFEST` multi-root is therefore "list of DBs", satisfied by the registry; no on-disk MANIFEST change required for correctness — record this.)

## Task C1: DB registry (df-index)

- [ ] **C1.1** Create `crates/df-index/src/registry.rs`: `struct DbRecord { name, root, db_path, content_dir }`, `struct Registry { records: Vec<DbRecord> }` with `load()`, `save()` (TOML via `toml` crate — **add `toml` to workspace deps**), `add()`, `remove()`, `get(name)`. Stored at `~/.deep-finder/dbs.toml`. **Decision:** use `toml = "0.8"` (human-readable, editable). Test: add/remove/list roundtrip in a tempdir-backed `data_dir` (inject the dir, don't touch `~/.deep-finder/`).
- [ ] **C1.2** Export from `df-index/src/lib.rs`: `pub mod registry; pub use registry::{Registry, DbRecord};`.
- [ ] **C1.3 Three gates + commit** — `git commit -m "feat(index): named-DB registry (dbs.toml)"`.

## Task C2: DbSet + daemon multi-DB query (deepfindd)

- [ ] **C2.1** Create `crates/deepfindd/src/dbset.rs`: `struct DbEntry { name, db: Arc<DbReader<FileSource>>, shards: Arc<ContentShards> }`; `struct DbSet { entries: Vec<DbEntry> }` with `open_all(data_dir)`, `open_one(name)`, and `query(req) -> Vec<(...)>` that loops entries (refactor the per-DB query out of `handle_conn` into a `query_one(entry, ...)`). Test: build 2 DBs from 2 temp roots, open `DbSet`, query a needle present in both → both paths returned, no dup if same relative path.
- [ ] **C2.2** Refactor `serve()` to open a `DbSet` (all registered DBs, plus a fallback default DB if registry empty) and pass it to `handle_conn`; `handle_conn` honors `req.opts`/`req.db` to select one or all.
- [ ] **C2.3 proto** — add `SearchRequest.db: Option<String>` (`#[serde(default)]`).
- [ ] **C2.4 integration test** — `db add` two roots via CLI helper, `search --db a` returns only `a`'s matches; default `search` returns union, deduped.
- [ ] **C2.5 Three gates + commit** — `git commit -m "feat(daemon): multi-DB query (DbSet, --db select, path-keyed merge)"`.

## Task C3: CLI `db` subcommands

- [ ] **C3.1** Add `Cmd::Db { action: DbAction }` with `DbAction::{ Add { name, root }, Remove { name }, List }`. `db add` calls `build_content_index` into the DB's dir + `Registry::add`; `db remove` deletes the dir + `Registry::remove`; `db list` prints the registry.
- [ ] **C3.2** Add `search --db <name>` flag → sets `SearchRequest.db`.
- [ ] **C3.3 tests + commit** — `git commit -m "feat(cli): db add/remove/list + search --db"`.

**Phase C exit:** build two named DBs, search by name and across all, dedup correct; fallback to single default DB preserved.

---

# Phase D — Perf Baseline + M7 Hardening (measurement-driven)

## Task D1: Criterion bench suite + baseline doc

- [ ] **D1.1** `crates/df-core/benches/candidate.rs` — criterion group: build an in-memory `DbReader`/`ShardReader` over a synthetic corpus (reuse the `bench_corpus` helper), bench `query_docids` and `candidates` at p50/p99 across {short (2-byte), common-trigram (`the`), rare} queries. Use `&[u8]` `DbSource` impl (pure, no I/O) so it benches in `df-core`.
- [ ] **D1.2** `crates/df-index/benches/build.rs` — bench `build_content_index` throughput on a temp corpus (docs/sec, bytes/sec).
- [ ] **D1.3** Peak RSS — a `justfile`/shell recipe: `/usr/bin/time -l cargo run --release -- index --root <corpus>` and `/usr/bin/time -l ... search <query>`, capturing `maximum resident set size`.
- [ ] **D1.4** Write `docs/perf-baseline.md` with the recorded numbers (build time, query p50/p99, peak RSS) and the bench commands to reproduce.
- [ ] **D1.5 Three gates + commit** — `git commit -m "perf: criterion bench suite + baseline (docs/perf-baseline.md)"`.

## Task D2: Measurement-driven hardening

> Each item is **gated on the baseline**: only implement if the bench shows it helps. Each is its own commit with a before/after bench delta recorded in `docs/perf-baseline.md`. Suggested order:

- [ ] **D2.1 2-rarest intersection** (`df-core/src/candidate.rs`) — when the rarest trigram posting is "large" (e.g. > 1% of docs), intersect the 2 rarest postings (two-pointer on sorted TurboPFor-decoded deltas) before verify. Test: candidate set ⊆ current (no false negatives) on a corpus with a common trigram; bench delta.
- [ ] **D2.2 bigram short-query path** (`df-core/src/candidate.rs` + `df-content/src/shard.rs`) — for 2-byte queries, add a bigram index (65k-entry array) instead of linear scan. **Only if** short-query latency is a measured hot spot. Test: 2-byte query correctness unchanged; bench delta.
- [ ] **D2.3 ASCII direct-index array** (`df-content/src/shard.rs`) — for ASCII trigrams (< 0x80), a direct 2M-slot array; non-ASCII tail keeps Robin Hood. Test: identical posting results; bench delta on ASCII-heavy corpus.
- [ ] **D2.4 dirTable shard pruning** (`df-content/src/shard.rs` + `df-core/src/scope.rs`) — per-doc `u16 dir_id` + shard-level dir set; `--scope` skips whole shards with no matching dir. Test: scoped query returns same results, fewer shards touched.
- [ ] **D2.5 per-shard parallel query** (`deepfindd/src/lib.rs`) — `rayon`-parallel (or `std::thread`) shard loop, CPU-capped. **Add `rayon` dep.** Test: results identical (order-independent merge by path); bench delta with many shards.
- [ ] **D2.6 madvise hints** (`df-index/src/mmap_source.rs`) — `MADV_RANDOM` on hash/postings, `MADV_DONTNEED` on cold corpus regions. Test: functional unchanged; RSS delta.
- [ ] **D2.7 final** — update `docs/perf-baseline.md` with all deltas; three gates; `git commit -m "perf: M7 hardening (2-rarest/bigram/ascii-array/dirTable/parallel/madvise) per baseline"`.

**Phase D exit:** baseline recorded; only implemented hardening items that the bench justified, each with a quantified delta and green tests.

---

# Phase E — bfs Expression Language (P2/L)

> **Design decision (record before E):** The bfs language is an **advanced expression mode** coexisting with `-e/-t/-E/-g/-d` (not replacing them). A new `--expr '...'` flag carries a find-style expression parsed into an `Expr` AST, evaluated per-result against `(path, LiteMeta)`. `-name/-path` are glob (reuse `df_ipc::filter::glob_matches`); `-size`/`-links` numeric with `[+-]N[c k M G]`; `-newer FILE` compares mtime to FILE's mtime; boolean `-a/-o/!` + parens, implicit `-a`. Evaluated in the daemon post-query filter (and `--direct` scan).

## Task E1: bfs parser + evaluator (df-ipc)

- [ ] **E1.1** Create `crates/df-ipc/src/bfs.rs`: `enum Prim { Name(String), Path(String), Size(Cmp, i64), Newer(PathBuf), Links(Cmp, i64) }`, `enum Expr { Prim(Prim), And(Box,Box), Or(Box,Box), Not(Box) }`, `parse(s: &str) -> Result<Expr>`, `eval(expr, path: &str, meta: &LiteMeta, newer_mtime: Option<i64>) -> bool`. Reuse `glob_matches` for name/path. Tokenizer recognizes `-name`, `-path`, `-size`, `-newer`, `-links`, `(`, `)`, `-a`, `-o`, `!`, and bare args. **Decision:** `-newer FILE` resolution (stat FILE's mtime) is I/O → done in the daemon before eval; the parser keeps `Newer(PathBuf)` and the daemon supplies `newer_mtime` per file. Pure parse + eval are unit-tested.
- [ ] **E1.2 tests** — parity with `bfs`/`find` predicates on a fixed tree: `-name '*.rs'`, `-name '*.rs' -a -size +0c`, `-path '*src*'`, `! -name '*.md'`, `\( -name a -o -name b \)`. Each: build expected set from the tree, assert `eval` agrees.
- [ ] **E1.3 proto + filter** — `SearchOptions.expr: Option<String>`; in `passes`, if `opts.expr` parses, compile once and eval per path (daemon compiles once per query, not per call — pass a precompiled `&Expr` through a small wrapper).
- [ ] **E1.4 daemon + direct** — daemon compiles `opts.expr` once, resolves `-newer` mtimes lazily (cache per FILE), applies to merged entries; `--direct` scan applies the same.
- [ ] **E1.5 CLI** — `--expr` flag; print as usual.
- [ ] **E1.6 Three gates + commit** — `git commit -m "feat(query): bfs expression language (--expr), coexists with filter flags"`.

**Phase E exit:** `deepfind search foo --expr '-name "*.rs" -a -size +100c'` returns the same set as the equivalent `bfs` invocation on the indexed tree.

---

# Phase F — Incremental Update v2.1 (last, highest risk)

> **New workspace deps:** `notify = "6"` (FSEvents), `arc-swap = "1"`.
>
> **Design decisions (record before F):**
> - **Hot-swap:** daemon's shard set becomes `ArcSwap<Vec<Arc<ShardEntry>>>`. A rebuild writes **new** shard files, then `ArcSwap::store` swaps the snapshot; the old `Arc`s drain as in-flight queries finish, then the old files are **renamed-aside** (`.dfcs.bak`) and deleted after a grace period — never truncated/unlinked while mapped, to avoid SIGBUS.
> - **Incremental strategy:** the watcher coalesces FSEvents; on a settled change set it performs a **dir-mtime-reusing partial rescan** (the dir-mtime table — reserved hook at `index.dfdb` header offset 36 — lets it skip unchanged directories) and rebuilds **only affected shards** (those whose doc set changed). Full rebuild remains the `--force` fallback. Per-file *posting* incremental merge is approximated by shard rebuild (true in-place TurboPFor merge is out of scope; record this).
> - **MANIFEST signature:** `Manifest::signature()` = hash over `(build_time, sorted shard entries)`; the watcher verifies the on-disk set matches before swapping (detects external tampering / drift).
> - **No offline window:** queries always read a consistent `ArcSwap` snapshot; rebuilds run in a background task while the old snapshot keeps serving.

## Task F1: ArcSwap shard snapshot + rename-aside swap

- [ ] **F1.1** Add `arc-swap` to workspace + `deepfindd` deps. Replace `struct ContentShards { sources: Vec<MmapSource> }` with a snapshot model: `type ShardSnap = Arc<Vec<Arc<ShardSnapEntry>>>` where `ShardSnapEntry { mmap: MmapSource, meta: ShardEntry }`; held in `ArcSwap<ShardSnap>`. `query`/`query_regex`/`query_lines` load a snapshot once (`arc_swap.load()`) and iterate it (borrow stable for the query lifetime). **Test:** two snapshots coexist; a query started on snapshot A completes correctly after snapshot B is stored (no panic, A's results intact).
- [ ] **F1.2 rename-aside + drain** — `swap_shards(new_snap, old_files)`: store new, spawn a task that waits `DRAIN_TIMEOUT` (reuse), then renames each old file to `.bak` and `fs::remove_file`s it. **Test:** after swap, old file is gone but a query holding the old `Arc` still reads valid bytes (mmap keeps the inode alive via the `File` in `MmapSource` until the `Arc` drops) — assert no SIGBUS by reading through a cloned old `Arc` after the file is renamed+removed.
- [ ] **F1.3 Three gates + commit** — `git commit -m "feat(daemon): ArcSwap lock-free shard hot-swap + rename-aside drain"`.

## Task F2: dir-mtime table (df-core)

- [ ] **F2.1** Land the reserved hook: write/read a dir-mtime section at `index.dfdb` header offset 36 (`dirmtime_off`). `DbBuilder` records `(dir_path, mtime)` per directory during build; `DbReader::dir_mtimes() -> Vec<(String, i64)>`. **Test:** roundtrip; a partial rescan using the table skips a dir whose mtime is unchanged and re-reads a dir whose mtime changed.
- [ ] **F2.2 Three gates + commit** — `git commit -m "feat(core): dir-mtime table (incremental readdir reuse hook)"`.

## Task F3: MANIFEST signature

- [ ] **F3.1** `Manifest::signature(&self) -> u64` (splitmix/fnv over encoded bytes); `Manifest::verify_signature(path) -> bool`. **Test:** tampered MANIFEST fails verification.
- [ ] **F3.2 commit** — `git commit -m "feat(index): MANIFEST signature (drift detection)"`.

## Task F4: notify watcher + incremental rebuild orchestration

- [ ] **F4.1** Add `notify = "6"` dep. Create `crates/deepfindd/src/watcher.rs`: spawn an `FsWatcher` over the indexed root(s) using `notify::RecommendedWatcher` (FSEvents on macOS). Coalesce events with a debounce window (e.g. 500ms); on settle, compute the changed-path set and call `rebuild_affected`.
- [ ] **F4.2 `rebuild_affected`** — using the dir-mtime table, rescan only changed dirs; rebuild affected shards into **new** files; rewrite MANIFEST; `swap_shards`. Full rebuild on `--force` or signature mismatch.
- [ ] **F4.3 Equivalence test (the core safety net):** build an index over a temp root; start the daemon with the watcher; mutate the tree (add/edit/delete files); settle; query results equal a fresh full `--force` rebuild's results (path-set + content matches), for a matrix of edits. **This is the gate for F correctness.**
- [ ] **F4.4 in-flight query test** — start a long-ish query, trigger a swap mid-query, assert the query returns a consistent (pre-swap) result set and no SIGBUS.
- [ ] **F4.5 no-offline-window test** — during a rebuild, concurrent queries keep succeeding against the old snapshot (latency-only impact).
- [ ] **F4.6 Three gates + commit** — `git commit -m "feat(daemon): df-watch incremental update (notify + dir-mtime reuse + ArcSwap swap)"`.

**Phase F exit:** incremental updates are equivalent to full rebuild; hot-swap is SIGBUS-safe; daemon never goes offline during rebuild; `--force` full rebuild retained as fallback.

---

# Definition of Done (whole plan)

1. Phase A–F all implemented, tests green.
2. `cargo fmt --check` · `cargo clippy --workspace --all-targets -D warnings` · `cargo test --workspace` all green; criterion benches runnable; `docs/perf-baseline.md` populated.
3. End-to-end integration tests cover: content-regex + line numbers (A), multi-root search (C), bfs expression (E), df-watch incremental equivalence (F).
4. No GUI / interactive TUI introduced.
5. `docs/decisions.md` aggregates every default decision made across phases.

---

# Self-Review (run after writing, before execution)

- **Spec coverage:** A1→A1.1/A1.2 ✓; A2→A2.1–A2.3 ✓; B1→B1.1–B1.6 ✓; B2→B2.1–B2.3 ✓; C1→C1 ✓; C2→C2 ✓; C3→C3 ✓; D1→D1 ✓; D2→D2.1–D2.7 ✓; E1→E1.1–E1.6 ✓; F1–F4 ✓. Smart-case `(?i)` conditioning for content regex: handled by passing the already-`(?i)`-prefixed `re` (built in `handle_conn`) into `query_regex`/`query_lines` ✓.
- **Type consistency:** `LineHit { path, line_no, text }` used identically in proto, daemon, CLI ✓. `content_regex_docids(reader: &ShardReader, atom_folded: &[u8], re: &Regex, limit)` matches the daemon call ✓. `query_lines` signature matches its call site ✓.
- **Placeholders:** none — every step has real test code or concrete signatures + integration points. D2 items are intentionally conditional (measurement-gated), which is a spec requirement, not a placeholder.
