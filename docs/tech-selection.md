# DeepFinder — End-state Technology Selection

> **Status:** Updated 2026-06-24. This table is the **end-state (target)** model; the 2026-06-23 "complete implementation" (Phases A–F) delivered several of these items (see the ✅ marks), the rest ⏳ remain to be built. Derived from the two locked design specs (`docs/superpowers/specs/2026-06-22-rust-search-index-cli-design.md`, `…-v2-content-index-design.md`).
> **In one sentence:** the end-state = **the built baseline + the v2.1 incremental layer + the M7 hardening layer**; full rebuild is only the v2.0 milestone, not the end-state.
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
| **Update model** | **incremental: `df-watch` (`notify`/FSEvents watcher) → `rebuild_and_swap` + ArcSwap hot-swap** | ✅ (partial) | the watcher + zero-downtime hot-swap **are delivered** (F4); but each change is a **full-root rescan**, not a per-file posting merge (high-risk, not done) |
| Full rebuild | v2.0 baseline (retained) | ✅ | Simple and reliable; kept as the `--force` fallback |
| Incremental hooks | dir-mtime table (F2) + MANIFEST signature (F3) | ⏳ (deferred) | Correctness-neutral — a full-root rescan is equivalent to a full rebuild; the hooks are in `crates/df-core/src/db.rs` (`dirmtime_off` reserved). Only worth it once benchmarked on a large corpus |
| Rebuild shard swap | write new file → `ArcSwap::store` → drop old after drain (old shard first **renamed aside**) | ✅ | No offline window; rename-aside (not a direct unlink) prevents an mmap SIGBUS (F1 verified) |

> **Design-lock conclusion** (spec): v2.0 = full rebuild (user-locked); incremental = v2.1. The end-state target is incremental, but **the architecture deliberately reserves hooks** so it is never painted into a corner. **Current state (2026-06-24):** v2.1's watcher incremental (rebuild_and_swap + ArcSwap hot-swap) is delivered; true per-file posting merge remains for later.

---

## 5. Process model / IPC / mmap

| Dimension | End-state choice | Status | Why this |
|---|---|---|---|
| Deployment | **resident daemon + thin CLI** | ✅ | the daemon holds the index handles (no re-opening of large mmaps) → fast repeated queries |
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

---

## Status summary

| Layer | ✅ Built | ⏳ Not yet built (end-state) |
|---|---|---|
| Language / engineering | 3/3 | — |
| Storage | 8/9 | dirTable pruning |
| Engine | 8/11 | ASCII direct array, 2-rarest (measured-reverted), bigram |
| Update model | watcher + hot-swap + full rebuild ✅; per-file merge not done | dir-mtime (F2), MANIFEST signature (F3), per-file posting merge |
| Process / IPC / mmap | 4/6 | madvise, per-shard parallelism |

**Verdict:** the core engine + process model + dual-layer storage are **built and correct**; the incremental-update watcher + hot-swap layer is also delivered. The remaining end-state work clusters in two areas — **(1) true incremental (per-file merge / dir-mtime / signature)**, **(2) the performance-hardening layer (M7)**. Both have **locked designs and an unblocked architecture**; they only await implementation (D2 left none in place after measurement this round; they need re-evaluation on a large real corpus).

---

## Convergence (one sentence)

> **Progress (2026-06-24):** lockless shard hot-swap (ArcSwap, F1) + df-watch incremental (watcher → `rebuild_and_swap`, F4) **are delivered**, upgrading "full rebuild" to "change-triggered rescan + hot-swap." **Still to build:** per-file posting merge, dir-mtime incremental (F2), MANIFEST signature (F3), plus the M7 hardening layer (ASCII direct array / 2-rarest already measured-reverted / bigram / dirTable / madvise / per-shard parallelism) — D2 left none in place after measurement this round; needs re-evaluation on a large real corpus. The architecture is **unblocked** thanks to reserved hooks in `db.rs`; only implementation is missing.
