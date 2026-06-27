# Architecture Decision Records — DeepFind

> Append-only log of decisions made while building DeepFind. Each record follows the
> **MADR** (Markdown Any Decision Record) format — **Status / Context / Decision / Consequences** —
> numbered `ADR-0001` onward. The log is append-only: never edit a past record's *Decision*; if it no
> longer holds, supersede it with a new record instead.
> Working rule (from the build plan): ambiguity does not block — pick a default, record it here, continue.
> Records `ADR-0001`–`ADR-0011` were captured 2026-06-23 while executing
> `docs/superpowers/plans/2026-06-23-complete-implementation-plan.md`.

## Index

| ADR | Title | Date | Status |
|---|---|---|---|
| 0001 | Content regex applies to both layers | 2026-06-23 | Accepted |
| 0002 | Line-number output uses a dedicated `ResponseFrame::Lines` | 2026-06-23 | Accepted |
| 0003 | `-H` hidden is an index-build + direct-scan flag, not search-only | 2026-06-23 | Accepted |
| 0004 | `-p`/`-b` path mode is enforced at verify, not in `passes` | 2026-06-23 | Accepted |
| 0005 | `--max-results` aliases the engine cap with early-exit streaming | 2026-06-23 | Accepted |
| 0006 | Default sort = (match-kind weight, path depth, path); stable | 2026-06-23 | Accepted |
| 0007 | Multi-DB = named independent indices + path-keyed merge; no global docid | 2026-06-23 | Accepted |
| 0008 | bfs language coexists with filter flags as `--expr` | 2026-06-23 | Accepted |
| 0009 | Incremental = watcher → full-root rescan + ArcSwap hot-swap; per-file merge + dir-mtime deferred | 2026-06-23 | Superseded by 0017 |
| 0010 | D2 hardening: measured, none justified on the synthetic baseline | 2026-06-23 | Accepted |
| 0011 | F2 dir-mtime table + F3 MANIFEST signature deferred | 2026-06-23 | Accepted |
| 0012 | df-watch ignores its own writes under the data dir (feedback-loop fix) | 2026-06-24 | Accepted |
| 0013 | Retired all 19 Swift-era tags for a clean Rust v1.0.0 slate | 2026-06-25 | Superseded by 0014 |
| 0014 | First public version is 0.1.0, not 1.0.0 | 2026-06-25 | Accepted |
| 0015 | Full Disk Access: heuristic probe + guidance, no programmatic grant | 2026-06-25 | Accepted |
| 0016 | Index build = daemon background task submitted over the socket; progress via status | 2026-06-26 | Accepted |
| 0017 | True incremental = LSM hot overlay (Overlay + WAL + compaction + safety-net); supersedes 0009 | 2026-06-26 | Accepted |
| 0018 | Single-instance daemon guard via advisory `flock` on `daemon.lock` | 2026-06-26 | Accepted |
| 0019 | Global `settings.json` config with a gitignore ignore list + `config` subcommand | 2026-06-27 | Accepted |

---

## ADR-0001 — Content regex applies to both layers

**Date:** 2026-06-23 · **Phase:** A1 · **Status:** Accepted

**Context.** Architecture §6 noted that the *then-current* state skipped the content layer in regex mode. Closing that gap (A1) meant deciding what regex mode should search. `grep -E` searches file bodies, so users expect regex to match content, not just filenames.

**Decision.** `--regex` mode runs the regex over **both** the filename and the content layer (mirroring literal mode), not filename-only. The longest literal atom drives content candidate generation (a case-insensitive superset); `regex.is_match` over the mmap'd content bytes is authoritative.

**Consequences.** Mirroring literal mode (search both layers) is the least-surprising behavior and matches `grep -E` semantics over file bodies.

---

## ADR-0002 — Line-number output uses a dedicated `ResponseFrame::Lines`

**Date:** 2026-06-23 · **Phase:** A2 · **Status:** Accepted

**Context.** A path can match on multiple lines, and per-line text is variable-length — neither fits cleanly inside the path-dedup `Batch` model.

**Decision.** `-n`/`-C` produce content matches as `LineHit { path, line_no, text }` streamed via a new `ResponseFrame::Lines` frame, separate from path `Batch`es. Filename-only matches have no line number and are omitted in `-n` mode (content-focused, matching `grep`).

**Consequences.** A parallel `Lines` stream keeps the path-dedup `Batch` model intact and avoids variable-length line info inside path batches.

---

## ADR-0003 — `-H` hidden is an index-build + direct-scan flag, not a search-only flag

**Date:** 2026-06-23 · **Phase:** B1 · **Status:** Accepted

**Context.** Hidden filtering is fundamentally an index-time concern (`walker.hidden(true)`). A search-time flag cannot retroactively surface files that were never indexed.

**Decision.** Hidden filtering happens **index-time**. `-H`/`--hidden` therefore (a) is an **index-build** flag (`index --hidden` includes hidden files) and (b) controls `--direct` online scan. Indexed search reflects whatever was built; a search-time `-H` cannot surface un-indexed hidden files (documented limitation).

**Consequences.** Honest about where the filter takes effect; avoids implying hidden files are reachable from a pre-built index that excluded them.

---

## ADR-0004 — `-p`/`-b` path mode is enforced at verify, not in `passes`

**Date:** 2026-06-23 · **Phase:** B1 · **Status:** Accepted

**Context.** Candidate generation must preserve the trigram/candidate superset invariant, and query-needle concerns should be kept separate from filter concerns.

**Decision.** `-p` = full-path match (default), `-b` = basename-only. Candidate generation is unchanged (full-path trigrams are a superset); basename mode adds a **post-verify** check that the basename contains the needle. `passes()` stays responsible for `-e/-t/-E/-g/-d` filters only.

**Consequences.** Keeps the trigram/candidate superset invariant intact and isolates query-needle concerns from filter concerns.

---

## ADR-0005 — `--max-results` aliases the engine cap with early-exit streaming

**Date:** 2026-06-23 · **Phase:** B1 · **Status:** Accepted

**Context.** An existing `limit` cap + `truncate` already bounds collection; a new flag should reuse that machinery rather than add a parallel path.

**Decision.** `--max-results N` sets `SearchRequest.limit = Some(N)`; the daemon stops collecting/streaming once N are delivered (already bounded by the existing `limit` cap + `truncate`).

**Consequences.** The only new semantics are explicit early-stop documentation and a guarantee that no more than N frames are emitted.

---

## ADR-0006 — Default sort = (match-kind weight, path depth, path); stable

**Date:** 2026-06-23 · **Phase:** B2 · **Status:** Accepted

**Context.** The current `HashMap` iteration order is nondeterministic, so output was not reproducible.

**Decision.** weight `Both=0 < Content=1 < Filename=2`, then path-depth ascending, then path ascending — best matches first, deterministic and reproducible. `--sort {path,kind,none}` overrides.

**Consequences.** Deterministic output; best-match-first matches user intuition.

---

## ADR-0007 — Multi-DB = named independent indices + path-keyed merge; no global docid

**Date:** 2026-06-23 · **Phase:** C · **Status:** Accepted

**Context.** The requirement was "build multiple roots, search by name, dedup correct." The simplest correct design avoids inventing a compound-shard docid namespace.

**Decision.** A registry (`~/.deep-find/dbs.toml`: `name → {root, db_path, content_dir}`). The daemon loads all registered DBs into a `DbSet` and loops over them, merging results by path (existing `merge_in` dedup). `search --db <name>` restricts to one; default = all. **No on-disk MANIFEST change and no cross-DB `base_docid` mapping is required** for correctness, because dedup is path-keyed, not docid-keyed. (Per-shard `base_docid` within a DB already exists.)

**Consequences.** Simplest correct design satisfying the requirement. `toml = "0.8"` was added as a workspace dep for a human-editable registry.

---

## ADR-0008 — bfs language coexists with filter flags as `--expr`

**Date:** 2026-06-23 · **Phase:** E · **Status:** Accepted

**Context.** The spec mandated coexistence with the existing flag surface; the richer find-style grammar should not destabilize the simple filters.

**Decision.** The find-style expression (`-name/-path/-size/-newer` + boolean + parens) is an **advanced mode** behind `--expr`, evaluated post-query against `(path, LiteMeta)`. It does **not** replace `-e/-t/-E/-g/-d`. `-newer FILE`'s mtime is resolved (I/O) once in the daemon and passed into the pure evaluator.

**Consequences.** Keeps the existing flag surface stable and isolates the richer grammar.

---

## ADR-0009 — Incremental = watcher → full-root rescan + ArcSwap hot-swap; per-file merge + dir-mtime deferred

**Date:** 2026-06-23 · **Phase:** F · **Status:** Superseded by ADR-0017

**Context.** True per-file in-place TurboPFor posting merge is high-risk and out of the verified scope. A full-rescan watcher is provably correct (equivalent to `--force`) and far simpler.

**Decision.** `df-watch` coalesces FSEvents and, on each debounced change event, calls `rebuild_and_swap` — a **full rescan of the changed root** that reuses `build_content_index` to rebuild **all** shards (not just affected ones) into new files, then hot-swaps via `ArcSwap`. Old shards are **rename-aside + drain-then-delete** (never truncate/unlink while mapped → no SIGBUS). Full rebuild is retained as `--force`. This is *correct* (the full rescan is equivalent to `--force`) and SIGBUS-safe, just not minimal-I/O.

**Consequences.** Deferred (correctness-neutral optimizations): the **dir-mtime partial rescan (F2)** (would let the watcher skip unchanged dirs) and **per-file in-place TurboPFor posting merge** are **not** implemented — full rescan already gives the correct result, so they are pure perf extras only measurable on a large real corpus. New deps: `notify = "6"`, `arc-swap = "1"`.

---

## ADR-0010 — D2 hardening: measured, none justified on the synthetic baseline

**Date:** 2026-06-23 · **Phase:** D · **Status:** Accepted

**Context.** The spec mandates "pick based on baseline results" + "each item a quantified improvement + all tests green." No M7 hardening item is implemented unless it clears that bar on the synthetic baseline in [perf-baseline.md](perf-baseline.md).

**Decision.** No M7 hardening item is implemented this round. Each was evaluated against the baseline:

- **2-rarest intersection (D2.1)** — implemented + benchmarked, then **reverted**. For DeepFind's *literal-substring* candidate generation, a query's trigrams are contiguous, so they co-occur in the same documents ⇒ the two rarest postings overlap almost entirely ⇒ intersecting them does not shrink the verify set. Measured: `common` ("src") 1.05 ms → 1.06 ms (noise). 2-rarest only helps *multi-term* queries, which DeepFind routes through the boolean AST, not `candidates()`.
- **Bigram short-query path (D2.2)** — the only hot signal (2-byte `short` = 2.43 ms linear scan), but it needs an on-disk bigram index = an invasive filename-DB + content-shard **format change** for a modest, narrow gain. Not justified at current corpus scale.
- **ASCII direct array / dirTable / per-shard parallel / madvise (D2.3–D2.6)** — signal unclear without a real multi-GB corpus; deferred until one is benchmarked.

**Consequences.** No item met the quantified-improvement bar on the baseline, so per the measurement-driven rule and simplicity-first, none is kept. D1 (benches + `perf-baseline.md`) is the Phase D deliverable; revisit D2 with a large real corpus.

---

## ADR-0011 — F2 dir-mtime table + F3 MANIFEST signature deferred

**Date:** 2026-06-23 · **Phase:** F · **Status:** Accepted

**Context.** The spec's F correctness gates (incremental ≡ full rebuild, SIGBUS-safe hot-swap, no offline window, `--force` retained) can be met without these two hardening extras.

**Decision.** F is delivered as F1 (ArcSwap SIGBUS-safe hot-swap, proven) + F4 (notify watcher → `rebuild_and_swap` → hot-swap, proven by a live integration test). The watcher does a **full rescan of the changed root** on each debounced change event, which is *correct* (equivalent to `--force` — it reuses `build_content_index`) and SIGBUS-safe, just not minimal-I/O.

**Consequences.** Deferred (correctness-neutral optimizations):

- **F2 dir-mtime table** — would let the watcher skip unchanged dirs instead of a full rescan. Not needed for correctness (full rescan is equivalent); added complexity for an optimization only measurable on a large real corpus.
- **F3 MANIFEST signature** — drift/tamper detection before swapping. The watcher rebuilds from its own `build_content_index` output, so the on-disk shards always match by construction.

Revisit when benchmarking incremental latency on a large corpus.

---

## ADR-0012 — df-watch ignores its own writes under the data dir (feedback-loop fix)

**Date:** 2026-06-24 · **Phase:** post-A–F · **Status:** Accepted

**Context.** Without this, a registered DB whose `root` *contains* the data dir (e.g. `db add w ~`, indexing `$HOME` or any ancestor of `~/.deep-find`) feeds back forever: `rebuild_and_swap` writes shards under the watched root → FSEvents → another rebuild → … . Reproduced: one mutation → ~29 rebuilds in 8 s, never converging (CPU burn + index churn). After the fix: one mutation → one rebuild.

**Decision.** The df-watch watcher ignores any event whose path is inside `~/.deep-find` (the index data dir — shards, `index.dfdb`, `daemon.sock`, `logs/`, `dbs.toml`), via a new pure predicate `is_self_write(paths, data_dir)`. The data dir is canonicalized so the prefix match survives a symlinked `$HOME`.

**Consequences.** The predicate is unit-tested; the existing `df_watch_serves_incremental_update` (sibling root, no overlap) is unchanged. **Scope not fixed here:** df-watch only ever watches *registered* DBs (`db add`, `root = Some`); the **default** DB (`index --root`, `root = None`) spawns no watcher, so `deepfind install`'s `DEEPFIND_WATCH=1` is a silent no-op for a default-only setup. Making the default DB watchable needs the root persisted somewhere the daemon can recover — separate work.

---

## ADR-0013 — Retired all 19 Swift-era tags for a clean Rust v1.0.0 slate

**Date:** 2026-06-25 · **Status:** Superseded by ADR-0014

**Context.** The Rust rewrite (2026-06-22, clean-slate) is treated as a new product versioned from `v1.0.0`. The 19 pre-rewrite tags all pointed at the deleted Swift codebase (dated 2026-05-29 → 06-04; `v3.2.0` contained `Package.swift` + `Sources/`) and would have collided with / confused the Rust release lineage.

**Decision.** Deleted all 19 pre-rewrite tags — `v0.0.1-beta`, `v0.1.0`–`v0.7.0`, `v1.0.0`–`v1.5.0`, `v2.0.0`–`v2.2.0`, `v3.0.0`, `v3.2.0` — both locally and on the remote. Confirmed the full set of 19: an earlier check via `git tag | head` had shown only 10 — the complete `git tag -l | sort -V` revealed 19, all Swift-era; the user re-confirmed deleting all 19. No Rust docs/CI referenced them.

**Consequences.** The Rust release lineage is clean. The first public version was later revised from 1.0.0 to 0.1.0 — see ADR-0014.

---

## ADR-0014 — First public version is 0.1.0, not 1.0.0

**Date:** 2026-06-25 · **Status:** Accepted

**Context.** For a brand-new open-source project's first release, 0.1.0 is the conventional choice (ripgrep/fd/bat all started at 0.x): it signals "usable, but pre-1.0 — CLI/behavior may still change," avoiding the SemVer stability commitments that 1.0.0 implies for a solo project still iterating. 0.0.1 was rejected as too conservative (rarely used for a real distributable release).

**Decision.** The first public Rust release is versioned **0.1.0** (tag `v0.1.0`), revising the earlier 1.0.0 plan. `Cargo.toml` workspace `version`, `CHANGELOG.md` (`## [0.1.0]`), the release tag, and `dist plan` all reflect 0.1.0. (The dated design spec/plan still say 1.0.0 — left as historical snapshots.)

**Consequences.** The user picked 0.1.0 over the originally-planned 1.0.0 at release time.

---

## ADR-0015 — Full Disk Access: heuristic probe + guidance, no programmatic grant

**Date:** 2026-06-25 · **Phase:** post-A–F · **Status:** Accepted

**Context.** DeepFind reads the whole disk — including TCC-protected `~/Library` subdirs (`Mail`, `Messages`, …) — so the process must hold Full Disk Access (FDA). Before this, FDA was surfaced only *reactively*: `df-index` counted `permission-denied` entries and `deepfind index` printed one warning at the end. There was no proactive check and no guidance to grant. macOS exposes **no API** to query or grant FDA, and — unlike Accessibility — **no consent prompt** an app can trigger; the user must manually add the binary in System Settings. Design: `docs/superpowers/specs/2026-06-25-permissions-design.md`.

**Decision.**
- **Detection = heuristic `readdir` probe**, not a TCC API query (user-space can't read `TCC.db` under SIP). `df-index::fda_state()` does **one** `read_dir` on the first existing TCC-protected candidate (`~/Library/{Calendars,Mail,Messages,Safari,Metadata/CoreData}`): `Ok` ⇒ `Granted`, `PermissionDenied` ⇒ `Denied`, absent/non-mac ⇒ `Unknown`. No cache (one `readdir` is cheap).
- **No `permissions grant`** — physically impossible for FDA. The closest "auto" action is `doctor` `open`-ing the FDA Settings pane; the user still adds the binary by hand.
- **Lives in `df-index`** (the fs-I/O layer), preserving the `df-core` zero-I/O hard constraint.
- **CLI and daemon are the same `deepfind` binary** (`deepfindd` is a linked lib), so a local CLI probe equals the daemon's FDA state — no socket roundtrip, no "daemon down ⇒ Unknown" path (unlike an Accessibility/Screen-Recording model where the granting identity and the CLI are separate processes).
- **Three exit surfaces, distinct behavior:** `status` reports the verdict word only; `doctor` is the human self-check (TTY ⇒ auto-`open` the FDA pane + print `current_exe()` + the `launchctl kickstart -k` restart command; non-TTY ⇒ guidance only, so scripts/CI don't pop a GUI); daemon startup emits one `tracing::warn!` if `Denied` and never opens a GUI.

**Consequences.** FDA state is now surfaced proactively at three places instead of only reactively at end-of-index. The probe is heuristic (community-standard, not a TCC API call) — authoritative for the `deepfind` binary, but macOS version drift could make a candidate readable without FDA, so candidates are tried in order and the list exhausts to `Unknown` rather than false-`Denied`. macOS-only pieces (`open`, candidate paths, `launchctl`) are `#[cfg(target_os = "macos")]`-gated; non-mac returns `Unknown`.

---

## ADR-0016 — Index build is a daemon background task submitted over the socket; progress via status

**Date:** 2026-06-26 · **Status:** Accepted

**Context.** Before P2.3, `deepfind index` built the index in-process in the foreground (a blocking walk + dual-layer write). The daemon already background-built *missing* registered DBs at startup (`index_job::spawn_if_missing`) and hot-swapped via `ArcSwap`; df-watch already did change-triggered `rebuild_and_swap` + hot-swap. But the user-facing `index` command did not use that path, so a manual rebuild blocked the terminal and gave no progress.

**Decision.** `deepfind index` now sends an `IndexRequest` over the socket; the daemon's `index_job::spawn_build` runs the build off the hot path and hot-swaps the `DbSet`, exactly like the startup path. The CLI returns immediately with the `IndexAck` and the user polls `deepfind status` for progress. Progress numbers come from `IndexProgress` atomics (files / bytes / shards) bumped inside `build_content_index_with_progress` and snapshotted to the `.indexing` marker by a reporter thread; `status` reads them cross-crate via `index_job::read_progress`.

- **Concurrency guard:** `spawn_build` uses `create_new` on the marker as an atomic guard — two concurrent builds of the same DB never interleave shard writes; a second submit returns `accepted = false` ("already indexing").
- **Fallback:** `--foreground` (and `--no-content`, which the background path doesn't serve) build in-process; the CLI also falls back to in-process automatically when the daemon is unreachable — mirroring `deepfind search`'s `--direct`, so the user is never blocked.
- **No new swap path:** on-demand builds reuse the existing `dbset.store` + rename-aside retirement, so in-flight queries (which pin an `Arc<DbSet>` snapshot per connection) are never interrupted — there is no second SIGBUS-safety story to get right.

**Consequences.** The foreground blocking build is gone from the default path (still reachable via `--foreground` for scripts / tests / no-daemon). The wire gained a tagged `enum Request { Search, Index }`; since CLI and daemon are the same binary, version skew is not a concern. `IndexProgress` lives in `df-index` (the I/O layer), preserving the `df-core` zero-I/O hard constraint.

---

## ADR-0017 — True incremental = LSM hot overlay (Overlay + WAL + compaction + safety-net)

**Date:** 2026-06-26 · **Status:** Accepted · **Supersedes:** ADR-0009

**Context.** ADR-0009 shipped df-watch as a **full-root rescan on every change** — provably correct and SIGBUS-safe, but high I/O/CPU for a single edited file, with latency that scaled with corpus size. The "true per-file incremental" it explicitly deferred was the in-place TurboPFor posting merge, which stayed high-risk (mutating immutable cold postings). The LSM-tree model (MemTable + WAL + SSTables + compaction) gets per-file incremental *without* mutating the cold postings: fold live edits into a small in-memory overlay, persist via a WAL, merge at read time, and periodically rebuild (compact) to fold the overlay back into cold storage.

**Decision.** A tiered-LSM incremental layer, reusing the existing engine primitives:

- **MemTable — hot `Overlay`** (`df-content::overlay`, pure, in-memory, behind an `ArcSwap`): absorbs per-file changes as `WalRecord::Upsert{path,meta,content}` / `Delete{path}`. It keeps its own per-path local docid space + trigram `try_map`, and `OverlayReader` implements `CandidateSource`, so the **same** rarest-trigram candidate + verify algorithm queries it. Re-upsert drops the doc's old postings; delete leaves an inert slot + a tombstone.
- **WAL — `OverlayStore`** (`df-index::overlay_store`): append-only `overlay.wal` (`u32 len` + bincode `WalRecord`), fsync'd per debounced batch, replayed into a fresh `Overlay` on restart; truncated on compaction. A half-written tail frame from a crash is dropped at decode (stops at the first truncated/corrupt frame).
- **Read merge (standard LSM):** cold filename/content layers + overlay are each queried independently and merged by path — overlay entries **override** stale cold hits on the same path, tombstones **suppress** deleted paths. An empty / freshly-compacted overlay (`shadows_anything() == false`) skips the override pass entirely (zero cost on the common query).
- **Compaction — `compact_and_swap`:** when the overlay ≥ threshold (default 2000, `DEEPFIND_COMPACTION_THRESHOLD`), a full rebuild subsumes the overlay → reload shards **and reload the filename layer** → `overlay.clear()` + WAL truncate. Bounds memory + query-merge cost between compactions.
- **Safety-net — `rebuild_and_swap`:** a daily full rebuild (`DEEPFIND_SAFETY_NET_SECS`, default 24h) refreshes the cold layer *without* clearing the overlay, backstopping anything missed (daemon downtime, coalesced/lost FSEvents, WAL corruption).
- df-watch stays **env-gated** (`DEEPFIND_WATCH=1`) and watches **registered DBs only** (a known `root`); the default DB (`root = None`) still has no incremental — see ADR-0012.

**Consequences.**

- **Supersedes ADR-0009:** per-file incremental is no longer deferred — it is delivered via the overlay. df-watch no longer rescans on every change; a full rebuild fires only on compaction or the safety-net.
- **F2 (dir-mtime partial rescan, ADR-0011) is moot on the common path** — there is no per-change rescan left to optimize. It could still apply to the compaction / safety-net rescans; still unimplemented, still correctness-neutral.
- **F3 (MANIFEST signature) is backstopped** by WAL replay + the daily safety-net, so on-disk drift detection is no longer the only line of defense; still not implemented.
- No new external deps: the WAL is `std::fs` + the already-in-tree `bincode`; the overlay reuses the existing `CandidateSource` trait (no I/O added to `df-core`). The overlay adds one merge step per DB per query, bounded by the compaction threshold; <3-byte queries over the overlay linear-scan its (small) doc set by design.

---

## ADR-0018 — Single-instance daemon guard via advisory `flock` on `daemon.lock`

**Date:** 2026-06-26 · **Status:** Accepted

**Context.** A resident daemon owns the Unix socket and the index-build pipeline; two daemons sharing `$HOME` would contend on the socket bind and race on shard/index writes. The socket file alone cannot serve as the guard — a crashed daemon leaves a stale socket behind, so "socket exists" is not a reliable liveness signal (and a manual `deepfind daemon` can race launchd's KeepAlive respawn).

**Decision.** Serialize daemon startup with an exclusive, non-blocking advisory `flock` (`LOCK_EX | LOCK_NB`) on `<socket dir>/daemon.lock`, held for the daemon's lifetime (`deepfindd::singleton`). Because `flock` is owned by the live open file description, the kernel releases it automatically on crash/exit — **no stale lock to clean up**, unlike the socket file (which is still removed on startup, now safe to do under the lock since no peer can be live). A second acquire returns `EWOULDBLOCK`, surfaced as a clear "deepfindd already running" error. Unix-only (`#![cfg(unix)]`); the project targets apple-darwin.

**Consequences.** At most one daemon per `$HOME`; the manual-start-vs-launchd race resolves with the loser bailing cleanly. No lock-cleanup logic is needed (kernel-managed lifetime). It does **not** prevent a second daemon under a different `$HOME` / data dir — by design, those are independent instances.

---

## ADR-0019 — Global `settings.json` config with a gitignore ignore list + `config` subcommand

**Date:** 2026-06-27 · **Status:** Accepted

**Context.** DeepFind pruned a hardcoded `DEFAULT_SKIP` and offered `--skip NAME` per build, but had no persistent, user-editable, whole-disk ignore list, and `--direct` online scan applied **no** skip at all. Users wanted to permanently exclude paths/patterns (`**/.venv`, `*.log`, `/Users/x/Secret`) across all DBs and scans without retyping flags.

**Decision.** A global `~/.deep-find/settings.json` (JSON, `#[serde(default)]` for forward/back-compat) whose first field is `ignore: Vec<String>` of **gitignore-glob** patterns, **unioned** with the `ignore` walker's `standard_filters` (`.gitignore`) and the existing `extra_skip` name-pruning — all three apply, none replaces another. Patterns compile to an in-memory `ignore::gitignore::Gitignore` rooted at each walk's root; an absolute path under the root is normalized to its anchored root-relative form (a raw `/Users/x/Secret` otherwise silently matches nothing — a false-sense-of-security bug caught in review). Applied at every index build (loaded once in `tracked_build`, covering on-demand/startup/compaction/safety-net), `--direct` scan, and df-watch (matcher recompiled **per debounce batch**, so a `config ignore add` during a running watch is honored by the next event). Managed by `deepfind config show` / `config ignore add|remove|list`. New `df-index::settings` module (next to `registry.rs`); `df-core` stays zero-I/O.

**Consequences.** One persistent global ignore list; no per-build flags; `--direct`'s no-skip gap closed. **No file watcher** on `settings.json` (§10's hot-reload exclusion stands) — each consumer reads at use time, so a change takes effect on the next build / `--direct` scan / df-watch event. Already-indexed-but-now-ignored files drop at the next compaction/safety-net rebuild (documented, tested). Design spec: [`docs/superpowers/specs/2026-06-27-settings-json-design.md`](superpowers/specs/2026-06-27-settings-json-design.md).
