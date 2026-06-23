# DeepFinder v2 — CLI Parity & Strengths-Integration Roadmap

**Date:** 2026-06-23
**Basis:** Knowledge of the reference projects in `search-analysis/` (zoekt, trigrep, fd, bfs, reflex, lolcate-rs). **Caveat:** derived from tool knowledge, not a fresh source audit — verify each feature against the cloned source before implementing. Survey workflow that would have confirmed this hit account rate-limits; this is the pragmatic fallback.

**Goal (user directive 2026-06-23):** make DeepFinder's CLI feature-complete by integrating the strengths of each reference project. GUI is deferred until explicit user confirmation.

**STATUS (2026-06-23) — done this round:** `-e/--extension`, `-t/--type`, `-E/--exclude`, `-g/--glob`, `-d/--max-depth`, `-x/--exec`, `--color` (match highlight), `--regex` (filename-regex via longest-literal-atom candidate gen), `-0/--null`, `--count` — all live + integration-tested (one real bug, the `./`-prefix glob match, caught + fixed). Combined filename∪content results with `MatchKind` (M5). Remaining P0: **smart-case + content-regex** (engine-level: verify-mode change / content-byte regex). Remaining P1: `-n/-c` context, ranking, multi-DB, bfs expression language.

---

## What each project is best at (signature strength → adopt)

| Project | Signature strength | Adopt into DeepFinder |
|---|---|---|
| **fd** | Best-in-class find UX: types/extensions/hidden/exclude/exec, smart-case, fast parallel walk | Primary CLI-UX template for the `search`/`find` flags |
| **bfs** | find expression language + breadth-first + robust predicates | Depth control, prune, `-size/-newer` predicates |
| **zoekt** | Code-search: regex, file-type filter, ranking, context/line-numbers, repo prune | Content-search power features (regex, -f, -n, -c, ranking) |
| **trigrep** | Trigram-accelerated regex grep (already our engine model) | Regex query planner on top of our trigram index |
| **reflex** | Indexed repeat-search + incremental | Fast repeat search (we have mmap); incremental = future |
| **lolcate-rs** | Rust locate: mmap, multi-DB, restrict filters, db management | Multi-root/named-DB management, `--regexp/--type` filters |

---

## Deduplicated integration backlog

### P0 — core CLI must-haves (biggest parity gap)
| Feature | Source | Milestone | Effort | Notes |
|---|---|---|---|---|
| **Regex search** (filename + content) on top of the trigram candidate engine | zoekt, trigrep, fd, bfs | M6 (new) | M | Add `regex` crate; literal substring stays the fast path; trigram-extract the regex's literal atoms for candidate gen |
| **`-t/--type`** file-type filter (f/d/l + ext-groups like `code`,`docs`,`media`) | fd, bfs, lolcate | M6 | S | type table (ext → category); filter at query + build |
| **`-e/--extension`** filter | fd | M6 | S | trivial on top of path |
| **Case control**: `-i/--ignore-case`, `-s/--case-sensitive`, **smart-case default** (case-insensitive unless query has uppercase) | fd, zoekt | M6 | S | smart-case is the fd/zoekt default users expect |
| **`-H/--hidden`** include hidden files (search-side toggle, orthogonal to index) | fd | M6 | S | index already has them via `--no-skip`-style; surface a flag |
| **`-d/--max-depth`** | fd, bfs | M6 | S | depth limit on candidate paths |

### P1 — high-value
| Feature | Source | Milestone | Effort | Notes |
|---|---|---|---|---|
| **`-x/--exec`** run a command per result | fd, bfs | M7/M8 | M | `{}` placeholder, parallel; big UX win |
| **`-g/--glob`** glob-pattern match (vs regex) | fd | M6 | S | globset |
| **`-p/--full-path`** match against full path (vs basename) | fd, bfs | M6 | S | DeepFinder already matches full path; add basename-only mode (`-b`?) |
| **`-E/--exclude`** exclude globs | fd | M6 | S | globset exclude |
| **Content match `-n/--line-number` + `-c/--context`** | zoekt, trigrep | M8 | M | needs positional-ish content scan (we're file-level; line-num requires scanning the matched file — acceptable post-verify) |
| **Result ranking/sorting** (recency, path-score, match-quality) | zoekt | M8 | M | REVIEW §8.3 unresolved; pick path-depth + match-kind weighting |
| **`--max-results`** early-exit cap | fd | M7 | S | cap + stop streaming |
| **Colorized output** (`--color=auto/always/never`) | fd, zoekt | M8 | S | terminal color crate |

### P2 — nice-to-have / future
| Feature | Source | Milestone | Effort | Notes |
|---|---|---|---|---|
| bfs full **find expression language** (`-name/-path/-size/-newer/-links` + boolean) | bfs | M8+ | L | big; subsumes several P0 filters |
| **`-X/--exec-batch`** | fd | M8 | S | one command, all results |
| **Multi-DB / named roots** (`deepfind db add/remove`, search a named root) | lolcate | M8 | M | MANIFEST + multiple content_dirs |
| **Symbol search** | zoekt | future | L | needs language-aware parsing |
| **Interactive filter mode** | (various) | skip | — | TUI-like; deferred w/ GUI |
| **pinyin/jieba** CJK tokenization | — | future | M | v2.0 byte-trigram handles CJK already |

---

## Already covered (DeepFinder v1 + v2, don't re-build)
Filename + content trigram search; mmap content shards; boolean AND/OR/NOT; `--scope`; `--limit`; `-l` long listing; `--direct` fallback; configurable skip-list (`--skip`/`DEEPFIND_SKIP`); FDA detection; graceful daemon drain (SIGINT/SIGTERM); streamed Batch results; `--force`/staleness; `--max-file-size`/`--no-content`/`--one-file-system`.

## Deliberately skipped
- **GUI** — deferred until explicit user confirmation (user directive).
- **Interactive TUI** — same.
- **pinyin/jieba, launchd auto-launch, SIMD** — v2.0 out of scope (existing).

---

## Target CLI surface (after integration)
```
deepfind index    [--root] [--force] [--skip …] [--max-file-size N]
                  [--no-content] [--one-file-system]
deepfind daemon
deepfind status
deepfind search <query>
    # match modes
    [--regex | --glob PATTERN]      # default: literal substring; -g glob; --regex regex
    [-i | -s]                        # ignore-case / case-sensitive (default: smart-case)
    [-p | --full-path]               # match full path (default) vs --basename
    # filters
    [-t TYPE[,…]] [-e EXT[,…]]       # file type / extension
    [-E EXCLUDE] [-d N] [-H]         # exclude glob / max-depth / hidden
    [--scope PATH] [--limit N] [--max-results N]
    # content-specific
    [-n] [-c N]                      # line numbers / context (content matches)
    # output
    [-l] [--color WHEN] [--no-filename]
    # layers
    [--content | --filename]         # restrict layer (default: both)
    [--direct]                       # online fallback
    # action
    [-x CMD]                         # exec per result
```

## Recommended next (after M5)
**Regex search + type/extension filters + smart-case** (the P0 block) — it's the single biggest parity gap: every reference tool does regex + type filters, and DeepFinder currently does only literal substring. This is also the natural M6 (the spec's M6 "CLI flags" expands into this). M5 (in-progress: daemon combined filename+content results) is the prerequisite (combined results are what regex/filters then constrain).
