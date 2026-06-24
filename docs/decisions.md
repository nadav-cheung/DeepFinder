# Design Decisions — DeepFinder Complete Implementation (2026-06-23)

> Append-only log of default decisions made while executing
> `docs/superpowers/plans/2026-06-23-complete-implementation-plan.md`.
> Format: `## YYYY-MM-DD — <topic>` · **Default:** … · **Reason:** … · **Phase:** …
> Rule: ambiguity does not block — pick a default, record it here, continue.

---

## 2026-06-23 — Content regex applies to both layers (Phase A1)

**Default:** `--regex` mode runs the regex over **both** the filename and the content layer (mirroring literal mode), not filename-only. The longest literal atom drives content candidate generation (case-insensitive superset); `regex.is_match` over the mmap content bytes is authoritative.

**Reason:** Architecture §6 notes the *current* state skips content in regex mode — that is the gap A1 closes. Mirroring literal mode (search both layers) is the least-surprising behavior and matches `grep -E` semantics over file bodies.

---

## 2026-06-23 — Line-number output uses a dedicated `ResponseFrame::Lines` (Phase A2)

**Default:** `-n`/`-C` produce content matches as `LineHit { path, line_no, text }` streamed via a new `ResponseFrame::Lines` frame (separate from path `Batch`es). Filename-only matches have no line number and are omitted in `-n` mode (content-focused, matching `grep`).

**Reason:** A path can match on multiple lines; a parallel `Lines` stream keeps the path-dedup `Batch` model intact and avoids variable-length line info inside path batches.

---

## 2026-06-23 — `-H` hidden is an index-build + direct-scan flag, not a search-only flag (Phase B1)

**Default:** Hidden filtering happens **index-time** (`walker.hidden(true)`). `-H`/`--hidden` therefore (a) is an **index-build** flag (`index --hidden` includes hidden files) and (b) controls `--direct` online scan. Indexed search reflects whatever was built; a search-time `-H` cannot surface un-indexed hidden files (documented limitation).

**Reason:** Honest about where the filter takes effect; avoids implying hidden files are reachable from a pre-built index that excluded them.

---

## 2026-06-23 — `-p`/`-b` path mode is enforced at verify, not in `passes` (Phase B1)

**Default:** `-p` = full-path match (default), `-b` = basename-only. Candidate generation is unchanged (full-path trigrams are a superset); basename mode adds a **post-verify** check that the basename contains the needle. `passes()` stays responsible for `-e/-t/-E/-g/-d` filters only.

**Reason:** Keeps the trigram/candidate superset invariant intact and isolates query-needle concerns from filter concerns.

---

## 2026-06-23 — `--max-results` aliases the engine cap with early-exit streaming (Phase B1)

**Default:** `--max-results N` sets `SearchRequest.limit = Some(N)`; the daemon stops collecting/streaming once N are delivered (already bounded by the existing `limit` cap + `truncate`).

**Reason:** Reuses the existing cap machinery; the only new semantics are explicit early-stop documentation and a guarantee that no more than N frames are emitted.

---

## 2026-06-23 — Default sort = (match-kind weight, path depth, path); stable (Phase B2)

**Default:** weight `Both=0 < Content=1 < Filename=2`, then path-depth ascending, then path ascending — best matches first, deterministic and reproducible. `--sort {path,kind,none}` overrides.

**Reason:** Deterministic output (current `HashMap` order is nondeterministic); best-match-first matches user intuition.

---

## 2026-06-23 — Multi-DB = named independent indices + path-keyed merge; no global docid (Phase C)

**Default:** A registry (`~/.deep-finder/dbs.toml`: `name → {root, db_path, content_dir}`). The daemon loads all registered DBs into a `DbSet` and loops over them, merging results by path (existing `merge_in` dedup). `search --db <name>` restricts to one; default = all. **No on-disk MANIFEST change and no cross-DB base_docid mapping is required** for correctness, because dedup is path-keyed, not docid-keyed. (Per-shard `base_docid` within a DB already exists.)

**Reason:** Simplest correct design that satisfies "build multiple roots, search by name, dedup correct" without a compound-shard docid namespace. `toml = "0.8"` added as a workspace dep for a human-editable registry.

---

## 2026-06-23 — bfs language coexists with filter flags as `--expr` (Phase E)

**Default:** The find-style expression (`-name/-path/-size/-newer` + boolean + parens) is an **advanced mode** behind `--expr`, evaluated post-query against `(path, LiteMeta)`. It does **not** replace `-e/-t/-E/-g/-d`. `-newer FILE`'s mtime is resolved (I/O) once in the daemon and passed into the pure evaluator.

**Reason:** Spec mandates coexistence; `--expr` keeps the existing flag surface stable and isolates the richer grammar.

---

## 2026-06-23 — Incremental = watcher → full-root rescan + ArcSwap hot-swap; dir-mtime partial rescan + posting merge deferred (Phase F)

**Default:** `df-watch` coalesces FSEvents and, on each debounced change event, calls `rebuild_and_swap` — a **full rescan of the changed root** that reuses `build_content_index` to rebuild **all** shards (not just affected ones) into new files, then hot-swaps via `ArcSwap`. Old shards are **rename-aside + drain-then-delete** (never truncate/unlink while mapped → no SIGBUS). Full rebuild is retained as `--force`. This is *correct* (the full rescan is equivalent to `--force`) and SIGBUS-safe, just not minimal-I/O.

**Deferred (correctness-neutral optimizations):** the **dir-mtime partial rescan (F2)** (would let the watcher skip unchanged dirs) and **per-file in-place TurboPFor posting merge** are **not** implemented — full rescan already gives the correct result, so they are pure perf extras only measurable on a large real corpus.

**Reason:** True incremental posting merge is high-risk and out of the verified scope; the full-rescan watcher is provably correct (equivalent to `--force`) and far simpler. See the F2/F3 entry below for the deferred set. New deps: `notify = "6"`, `arc-swap = "1"`.

## 2026-06-23 — D2 hardening: measured, none justified on the synthetic baseline (Phase D)

**Default:** No M7 hardening item is implemented this round. Each was evaluated against `docs/perf-baseline.md`:

- **2-rarest intersection (D2.1)** — implemented + benchmarked, then **reverted**. For DeepFinder's *literal-substring* candidate generation, a query's trigrams are contiguous, so they co-occur in the same documents ⇒ the two rarest postings overlap almost entirely ⇒ intersecting them does not shrink the verify set. Measured: `common` ("src") 1.05 ms → 1.06 ms (noise). 2-rarest only helps *multi-term* queries, which DeepFinder routes through the boolean AST, not `candidates()`.
- **Bigram short-query path (D2.2)** — the only hot signal (2-byte `short` = 2.43 ms linear scan), but it needs an on-disk bigram index = an invasive filename-DB + content-shard **format change** for a modest, narrow gain. Not justified at current corpus scale.
- **ASCII direct array / dirTable / per-shard parallel / madvise (D2.3–D2.6)** — signal unclear without a real multi-GB corpus; deferred until one is benchmarked.

**Reason:** The spec mandates "按基准结果选做" + "每项量化提升 + 测试全绿". No item met the quantified-improvement bar on the baseline, so per the measurement-driven rule and simplicity-first, none is kept. D1 (benches + `perf-baseline.md`) is the Phase D deliverable; revisit D2 with a large real corpus.

## 2026-06-23 — F2 dir-mtime table + F3 MANIFEST signature deferred (Phase F)

**Default:** F is delivered as F1 (ArcSwap SIGBUS-safe hot-swap, proven) + F4 (notify watcher → `rebuild_and_swap` → hot-swap, proven by a live integration test). The watcher does a **full rescan of the changed root** on each debounced change event, which is *correct* (equivalent to `--force` — it reuses `build_content_index`) and SIGBUS-safe, just not minimal-I/O.

**Deferred (correctness-neutral optimizations):**
- **F2 dir-mtime table** — would let the watcher skip unchanged dirs instead of a full rescan. Not needed for correctness (full rescan is equivalent); added complexity for an optimization only measurable on a large real corpus.
- **F3 MANIFEST signature** — drift/tamper detection before swapping. The watcher rebuilds from its own `build_content_index` output, so the on-disk shards always match by construction.

**Reason:** Both are perf/hardening extras; the spec's F correctness gates (incremental ≡ full rebuild, SIGBUS-safe hot-swap, no offline window, `--force` retained) are met without them. Revisit when benchmarking incremental latency on a large corpus.

## 2026-06-24 — df-watch ignores its own writes under the data dir (feedback-loop fix, post-A–F)

**Default:** The df-watch watcher ignores any event whose path is inside `~/.deep-finder` (the index data dir — shards, `index.dfdb`, `daemon.sock`, `logs/`, `dbs.toml`), via a new pure predicate `is_self_write(paths, data_dir)`. The data dir is canonicalized so the prefix match survives a symlinked `$HOME`.

**Reason:** Without it, a registered DB whose `root` *contains* the data dir (e.g. `db add w ~`, indexing `$HOME` or any ancestor of `~/.deep-finder`) feeds back forever: `rebuild_and_swap` writes shards under the watched root → FSEvents → another rebuild → … . Reproduced: one mutation → ~29 rebuilds in 8 s, never converging (CPU burn + index churn). After the fix: one mutation → one rebuild. The predicate is unit-tested; the existing `df_watch_serves_incremental_update` (sibling root, no overlap) is unchanged.

**Scope note (NOT fixed here):** df-watch only ever watches *registered* DBs (`db add`, `root = Some`); the **default** DB (`index --root`, `root = None`) spawns no watcher, so `deepfind install`'s `DEEPFIND_WATCH=1` is a silent no-op for a default-only setup. Making the default DB watchable needs the root persisted somewhere the daemon can recover — separate work.

## 2026-06-25 — Retired all 19 Swift-era tags for a clean Rust v1.0.0 slate

**Default:** Deleted all 19 pre-rewrite tags — `v0.0.1-beta`, `v0.1.0`–`v0.7.0`, `v1.0.0`–`v1.5.0`, `v2.0.0`–`v2.2.0`, `v3.0.0`, `v3.2.0` — both locally and on the remote. The Rust rewrite (2026-06-22, clean-slate) is treated as a new product versioned from `v1.0.0`; these tags all pointed at the deleted Swift codebase (dated 2026-05-29 → 06-04; `v3.2.0` contained `Package.swift` + `Sources/`) and would have collided with / confused the Rust release lineage.

**Reason:** User decision (OSS release design): Rust = new product, start at 1.0.0, retire old tags. Confirmed the full set of 19 (an earlier check via `git tag | head` had shown only 10 — the complete `git tag -l | sort -V` revealed 19, all Swift-era; user re-confirmed deleting all 19). No Rust docs/CI referenced them.
