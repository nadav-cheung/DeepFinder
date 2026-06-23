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

**Default:** The find-style expression (`-name/-path/-size/-newer/-links` + boolean + parens) is an **advanced mode** behind `--expr`, evaluated post-query against `(path, LiteMeta)`. It does **not** replace `-e/-t/-E/-g/-d`. `-newer FILE`'s mtime is resolved (I/O) once in the daemon and passed into the pure evaluator.

**Reason:** Spec mandates coexistence; `--expr` keeps the existing flag surface stable and isolates the richer grammar.

---

## 2026-06-23 — Incremental ≈ dir-mtime partial rescan + affected-shard rebuild; true posting merge out of scope (Phase F)

**Default:** `df-watch` coalesces FSEvents, rescans only changed directories (dir-mtime table, hook at `index.dfdb` header offset 36), and rebuilds **affected shards** into new files, then hot-swaps via `ArcSwap`. Old shards are **rename-aside + drain-then-delete** (never truncate/unlink while mapped → no SIGBUS). Full rebuild is retained as `--force`. Per-file in-place TurboPFor posting merge is **not** implemented (shard rebuild approximates it).

**Reason:** True incremental posting merge is high-risk and out of the verified scope; shard-rebuild incremental is correct (proven by equivalence vs full rebuild) and far simpler. New deps: `notify = "6"`, `arc-swap = "1"`.

## 2026-06-23 — D2 hardening: measured, none justified on the synthetic baseline (Phase D)

**Default:** No M7 hardening item is implemented this round. Each was evaluated against `docs/perf-baseline.md`:

- **2-rarest intersection (D2.1)** — implemented + benchmarked, then **reverted**. For DeepFinder's *literal-substring* candidate generation, a query's trigrams are contiguous, so they co-occur in the same documents ⇒ the two rarest postings overlap almost entirely ⇒ intersecting them does not shrink the verify set. Measured: `common` ("src") 1.05 ms → 1.06 ms (noise). 2-rarest only helps *multi-term* queries, which DeepFinder routes through the boolean AST, not `candidates()`.
- **Bigram short-query path (D2.2)** — the only hot signal (2-byte `short` = 2.43 ms linear scan), but it needs an on-disk bigram index = an invasive filename-DB + content-shard **format change** for a modest, narrow gain. Not justified at current corpus scale.
- **ASCII direct array / dirTable / per-shard parallel / madvise (D2.3–D2.6)** — signal unclear without a real multi-GB corpus; deferred until one is benchmarked.

**Reason:** The spec mandates "按基准结果选做" + "每项量化提升 + 测试全绿". No item met the quantified-improvement bar on the baseline, so per the measurement-driven rule and simplicity-first, none is kept. D1 (benches + `perf-baseline.md`) is the Phase D deliverable; revisit D2 with a large real corpus.
