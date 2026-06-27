# DeepFind — End-state Technology Selection

> **Status:** Updated 2026-06-27 (v0.1.6). This table is the **end-state (target)** model; the 2026-06-23 "complete implementation" (Phases A–F) plus the v0.1.x follow-ons delivered most of these items (see the ✅ marks), the rest ⏳ remain to be built. Derived from the two locked design specs (`docs/superpowers/specs/2026-06-22-rust-search-index-cli-design.md`, `…-v2-content-index-design.md`).
> **In one sentence:** the end-state = **the built baseline + the incremental layer (LSM hot overlay, now built) + the M7 hardening layer**; full rebuild is only the v2.0 milestone, not the end-state.
> **Companion doc:** [architecture.md](architecture.md) (as-built architecture diagrams, reflecting the real code on `main`).

---

## Legend

| Mark | Meaning |
|---|---|
| ✅ | Built and verified (code on `main`) |
| ⏳ | Design locked, code not yet built (v2.1 / M7) — this is the "end-state relative to today" delta |

---

## 1. Language & engineering baseline (all built)

| Dimension | End-state choice | Status | Why this |
|---|---|---|---|
| Implementation language | **Rust** (edition 2021, resolver 2) | ✅ | The search hot path needs C-level control (mmap/pread/zero-copy) + memory safety (no GC pauses, no UB). The original Swift project was rewritten wholesale on 2026-06-22 |
| Engineering organization | **6-crate, single-directional acyclic workspace** | ✅ | Layered decoupling; the key point is **df-core is zero-I/O** — the engine operates on the `DbSource` trait, so it can be unit-tested + benchmarked without a real DB |
| Serialization | **serde + bincode**, all fields `#[serde(default)]` | ✅ | Compact binary (no JSON text overhead) + old/new ends interoperate (forward/backward compatible) |

---

## 2. Storage model

| Dimension | End-state choice | Status | Why this |
|---|---|---|---|
| Overall | **two independent storage layers + one candidate engine** | ✅ | Filename vs. content layers have different access profiles → stored separately; but the **algorithm is unified** (shared `CandidateSource` trait), avoiding two engines |
| Filename layer | `.dfdb` single file, **fully pread** | ✅ | Low latency, low RSS: pread reads only the hit postings, the daemon never holds the whole DB resident |
| Content layer | `.dfcs` multi-shard, **fully mmap'd** (memmap2 MAP_SHARED PROT_READ) | ✅ | GB-scale content; the kernel page cache manages residency — untouched pages cost no memory, zero-copy |
| Format evolution | zoekt-style **tagged-TOC + footer 8B locator** | ✅ | Self-describing + forward-compatible (unknown tags skipped); read the last 8B to locate the TOC |
| Content corpus | **raw bytes** (zoekt-style, ~1× disk budget) | ✅ | Fastest verify; trading disk budget for speed (accepted; capped by the 1 MB/file limit) |
| Filename compression | zstd + **trained dictionary** + block index | ✅ | Paths are highly redundant; a trained dictionary compresses far better than generic zstd; the block index enables random decompression |
| docid model | global u32 + `base_docid` mapping | ✅ | Results from both layers can be **union-deduped by path key** directly, with no cross-layer join |
| **shard set** | `ArcSwap<Vec<Arc<Shard>>>` **lockless atomic snapshot** | ✅ | Swap shards with no downtime during a rebuild; old `Arc`s drop after drain (F1 delivered; rename-over preserves inode, verified to prevent SIGBUS) |
| **hot overlay (incremental)** | in-memory `Overlay` (ArcSwap) + persisted `overlay.wal` (append + fsync + replay); cold layers stay immutable | ✅ | LSM tiered model: live edits folded into the overlay between compactions; queries merge cold + overlay by path. See ADR-0017 |
| **scope pruning** | `dirTable` + per-doc `u16 dir_id` → shard-level skip | ⏳ | Today `--scope` is a post-query path filter; the end-state can skip an entire shard |

---

## 3. Engine algorithms (df-core)

| Dimension | End-state choice | Status | Why this |
|---|---|---|---|
| Index granularity | **byte trigram**, bijective u32 key (see below) | ✅ | Zero key collisions + native CJK (UTF-8 multibyte forms windows directly, no tokenizer needed) |
| **trigram table** | **ASCII direct-index array (2M slots, ~16MB/shard) + non-ASCII Robin Hood tail** | ⏳ | The vast majority of whole-disk content is ASCII → a **zero-hash fast path**; the non-ASCII tail reuses RH (20B/slot) |
| **candidate generation (end-state)** | **2-rarest intersection** (two-pointer on sorted TurboPFor-decoded deltas) | ⏳ | When a high-frequency trigram (`the`/`com`/`src`) degenerates, 2-rarest narrows the candidate set further |
| candidate generation (baseline) | single-rarest → verify | ✅ | Current state: correct but not fastest |
| Exact verify | `memchr::memmem` (content) / `windows==` (filename) | ✅ | One precise substring pass eliminates all trigram false positives; memchr takes the SIMD fast path |
| Inverted compression | **self-written TurboPFor** (PFor delta, block=128, **scalar, no SIMD**) | ✅ | docid postings are near-monotonic integers → high compression + fast decode; self-written buys **pure Rust (no FFI) + scalar portability** |
| Hash table | **Robin Hood open addressing**, splitmix32, 20B/slot | ✅ | No pointer chasing → cache-friendly; Robin Hood bounds the worst-case probe length → query latency is predictable |
| **<3-byte queries** | **bigram index (65k array)**; 1-char refuse/cap | ⏳ | Today <3-byte queries linear-scan the whole DB |
| Case | default **smart-case**, `-i`/`-s` override | ✅ | Lowercase ⇒ fuzzy search, uppercase ⇒ exact search, matching fd/ripgrep intuition |
| Complex queries | **boolean AST** (AND/OR/NOT + parens + implicit AND) | ✅ | zoekt-style expressiveness |
| trigram semantics | **file-level (non-positional) + substring verify** | ✅ | A deliberate departure from REVIEW §7.2 (which recommended positional trigram); the rarest + 2-rarest + bounded-verify hedge against degeneration |

**Byte-trigram key** (bijective u32, zero collisions):

```
key = (a << 16) | (b << 8) | c        // three bytes a,b,c sliding window → u32
index side: slide a window over lowercased bytes to extract keys
query side:  extract keys from the folded query → take the shortest posting
```

---

## 4. Update model ← the end-state's key upgrade

| Dimension | End-state choice | Status | Why this |
|---|---|---|---|
| **Update model** | **incremental: `df-watch` (`notify`/FSEvents) folds changes into an LSM hot overlay (`Overlay` + `overlay.wal`) — queries merge cold + overlay; compaction + daily safety-net rebuild** | ✅ | True per-file incremental **without mutating cold postings**: edits land in the overlay (~1s to surface); a full rebuild fires only on compaction (overlay ≥ threshold) or the safety-net. See ADR-0017 |
| Full rebuild | v2.0 baseline (retained) | ✅ | Simple and reliable; used by compaction, the safety-net, and `--force` |
| Rebuild shard swap | write new file → `ArcSwap::store` → drop old after drain (old shard first **renamed aside**) | ✅ | No offline window; rename-aside (not a direct unlink) prevents an mmap SIGBUS (F1 verified) |
| dir-mtime partial rescan (F2) | skip unchanged dirs during a rebuild | ⏳ (largely moot) | Moot on the change path (incremental is the overlay, no per-change rescan); could still optimize the compaction/safety-net rescans. Hooks reserved in `crates/df-core/src/db.rs` (`dirmtime_off`). Correctness-neutral |
| MANIFEST signature (F3) | drift/tamper detection before swapping | ⏳ (backstopped) | On-disk drift is now backstopped by WAL replay + the daily safety-net rebuild, so F3 is no longer the only defense; still not implemented |

> **Design-lock conclusion** (spec): v2.0 = full rebuild (user-locked); incremental = v2.1. **Current state (2026-06-27, v0.1.6):** incremental is delivered as the LSM hot overlay (ADR-0017) — a per-file change no longer triggers a rescan; it folds into the overlay and surfaces in ~1s, with compaction + a daily safety-net rebuild bounding memory and backstopping misses. The architecture's reserved hooks in `db.rs` are now largely moot for the change path.

---

## 5. Process model / IPC / mmap

| Dimension | End-state choice | Status | Why this |
|---|---|---|---|
| Deployment | **resident daemon + thin CLI** | ✅ | the daemon holds the index handles (no re-opening of large mmaps) → fast repeated queries |
| **Single instance** | advisory `flock` on `<data_dir>/daemon.lock` | ✅ | At most one daemon per `$HOME`; kernel releases the lock on crash (no stale-lock cleanup). See ADR-0018 |
| Transport | **Unix domain socket** + LengthDelimitedCodec (4B length prefix) | ✅ | Local-only, no network exposure, low latency, can carry credentials |
| Result transport | **streaming Batch×N (512/frame) + Done** | ✅ | Ten-thousand-scale results don't block — returned incrementally, CLI prints as it receives |
| Fallback | daemon unavailable → CLI auto `--direct` online scan | ✅ | Never blocks the user; graceful degradation |
| **madvise** | hash/postings `MADV_RANDOM`; ASCII array resident; cold regions `MADV_DONTNEED` | ⏳ | Keeps RSS down to "tens of MB + 16MB/shard ASCII array" |
| **per-shard parallelism** | CPU-capped parallel query | ⏳ | Today the content query is a sequential loop; latency grows linearly with shard count |

---

## 6. Deliberately not in the end-state (explicit exclusions)

| Item | Why excluded |
|---|---|
| Positional trigram / phrase / proximity search | File-level + substring verify is enough; positional cost is high, re-evaluated at v2.1 or later |
| Relevance ranking | Optional (path-depth + match-kind weighting), not core |
| SIMD decode | Scalar correctness first; SIMD is an optional optimization |
| Multi-volume auto-sharding / resumable cursor / GUI / pinyin-jieba | Out of scope this round |
| Programmatic Full Disk Access grant / reading `TCC.db` | Physically impossible on macOS (no consent prompt an app can trigger, unlike Accessibility) / infeasible under SIP. FDA is **detected** via a heuristic `readdir` probe and the user is **guided** to System Settings — see ADR-0015 |

---

## Status summary

| Layer | ✅ Built | ⏳ Not yet built (end-state) |
|---|---|---|
| Language / engineering | 3/3 | — |
| Storage | 9/10 | dirTable pruning |
| Engine | 8/11 | ASCII direct array, 2-rarest (measured-reverted), bigram |
| Update model | LSM overlay incremental + compaction + safety-net + hot-swap + full rebuild ✅ | dir-mtime (F2, largely moot), MANIFEST signature (F3, backstopped) |
| Process / IPC / mmap | 5/7 | madvise, per-shard parallelism |

**Verdict:** the core engine + process model + dual-layer storage are **built and correct**; the incremental-update layer is now **fully delivered** as the LSM hot overlay (ADR-0017) — per-file changes fold into the overlay instead of triggering a rescan. The remaining end-state work is essentially **the performance-hardening layer (M7)** (ASCII direct array / 2-rarest already measured-reverted / bigram / dirTable / madvise / per-shard parallelism), plus the two now-moot/backstopped extras (F2 dir-mtime, F3 MANIFEST signature). These have **locked designs and an unblocked architecture**; D2 left none in place after measurement — they need re-evaluation on a large real corpus.

---

## Convergence (one sentence)

> **Progress (2026-06-27, v0.1.6):** lockless shard hot-swap (ArcSwap, F1) + **true incremental via the LSM hot overlay** (Overlay + WAL + compaction + safety-net, ADR-0017) + single-instance guard (ADR-0018) **are delivered** — a per-file change folds into the overlay and surfaces in ~1s, with compaction + a daily safety-net bounding memory and backstopping misses. **Still to build:** the M7 performance-hardening layer (ASCII direct array / 2-rarest already measured-reverted / bigram / dirTable / madvise / per-shard parallelism); F2 (dir-mtime) is now largely moot and F3 (MANIFEST signature) is backstopped by WAL replay + the safety-net. D2 left none in place after measurement; needs re-evaluation on a large real corpus.
