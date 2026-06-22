# DeepFinder v2 — Content Index (Final Architecture)

**Date:** 2026-06-22
**Status:** Design approved (pending spec review)
**Supersedes v1 scope only by addition; v1 filename layer is unchanged.**

Grounded in a multi-agent survey of `search-analysis/` reference repos:
**zoekt** (shard format / query pipeline), **trigrep** (trigram-accelerated
substring verify), **lolcate-rs** (Rust full-disk mmap / streaming build),
**bfs/fd** (full-disk walk robustness), plus `search-analysis/REVIEW.md` §7.2/§7.3/§7.7.

---

## 1. Goals

- **Full-disk / home-directory content search.** Index file *contents* (not just
  names) across a whole disk or `$HOME`.
- **Substring search** via file-level (non-positional) trigram inverted index +
  on-verify. Reuse v1's boolean engine (AND/OR/NOT).
- **Combined, deduped results**: a file matching by filename *and* content is
  reported once.
- **Low RSS** via mmap (content) + pread (filename). Daemon stays resident.
- **Reuse v1**: TurboPFor, Robin Hood hash, bijective u32 trigram key, zstd
  filename blocks, boolean parser, `ignore` walker, atomic writes, IPC framing.

## 2. Scope

**In (v2.0):** content substring index, mmap multi-shard storage, combined
filename+content results, full-rebuild build model, full-disk walk with binary
detection + per-file size cap, `--scope` shard pruning, `--direct` online-grep
fallback.

**Out (deferred):** positional trigram / phrase / proximity, relevance ranking,
incremental/FSEvents updates (`df-watch`), SIMD decode, multi-volume sharding
beyond the home dir, resumable cursor.

## 3. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Capability | content substring, file-level trigram | minimal, reuses v1 patterns |
| Scale | full-disk / home-directory | user-locked |
| Storage | mmap multi-shard | GB-scale requires it |
| Results | filename + content, deduped | user-locked |
| Update model | full rebuild only (v2.0) | user-locked; incremental is v2.1 |
| Tokenization | byte trigram over lowercased bytes | encoding-agnostic, CJK-native, matches v1 |
| mmap impl | **memmap2** | standard/safe; self-written mmap rejected on SIGBUS/alignment risk |
| contentCorpus | **raw bytes** (zoekt-style) | fastest verify; disk budget accepted (~1× corpus) |

**Conscious divergence from REVIEW §7.2/§7.7:** REVIEW recommends *positional*
trigram for content. v2.0 uses *file-level* trigram + substring-verify. Mitigation
for the degenerate common-trigram case is the rarest-trigram pruning + 2-rarest
intersection + bounded verify (see §13 risk 1).

## 4. Two-layer architecture (REVIEW §7.7)

Two distinct file families under `~/.deep-finder/db/`:

1. **Filename DB** — `index.dfdb` (v1, **unchanged**). Single pread-backed file,
   plocate-style. DbReader/FileSource/query path reused as-is.
2. **Content shards** — `content/shard-NNNNN.dfcs` + `content/MANIFEST`. mmap'd.

Both built in a single walk pass; the walker feeds both builders.

## 5. Content shard format (.dfcs)

Adopts zoekt's tagged-TOC + trailing-footer scheme (`index/read.go`,
`index/section.go`) for forward/backward format evolution (unknown tags skipped).

```
[u8; N]   body: sections written back-to-back
TOC:      u32 section_count (0 => tagged mode)
          repeat: varint tag_len, tag bytes, varint kind
                    (0=simple: u32 off,u32 sz
                     1=compound: u32 data_off,data_sz,idx_off,idx_sz)
FOOTER:   8 bytes: u32 toc_off, u32 toc_sz   (read first; at file end)
```

Opened by `memmap2` MAP_SHARED PROT_READ → read last 8 bytes → seek TOC.

### v2.0 sections

| Section | Kind | Contents |
|---|---|---|
| `metaData` | simple | `version:u16, build_time:u64, base_docid:u32, num_docs:u32, shard_id:u32` |
| `fileNames` | compound | u32-delta-sorted varint-length-prefixed paths; index = per-doc rel offsets (uncompressed; mmap random-access > compression) |
| `fileMeta` | simple | per-doc `is_dir:u8, size:i64, mtime:i64` (17 B, **identical to v1 LiteMeta**) |
| `contentOffsets` | compound | per-doc `u64 abs byte offset into contentCorpus` + `u32 stored_len`; index = per-doc u32 |
| `contentCorpus` | simple | raw size-capped file bytes, concatenated in docid order |
| `contentTrigrams` | — | trigram→docid inverted index (see §6) |
| `dirTable` + per-doc `u16 dir_id` | — | directory-id → path, for `--scope` shard pruning |

Uncompressed where mmap random-access wins (postings, corpus, meta). Shard flush
threshold: ~128 MB contentCorpus. `u32` offsets cap a shard at <4 GB total.
MANIFEST: shard list + `base_docid` map + `build_time` + walker-stat signature;
atomically rewritten (v1 `atomic_write` reused).

## 6. Content trigram index (file-level)

Same bijective u32 key as v1 (`(a<<16|b<<8|c)` over lowercased bytes — collision-free).

Two layers (mirror v1's HASH+POSTINGS split, mmap-tuned):

1. **ASCII direct-indexed array** (zoekt `asciiPostings[1<<21]`): flat 2M-entry
   array for all-ASCII trigrams. Each entry: `u32 offset + u32 count`. Zero-hash
   fast path (full-disk content is overwhelmingly ASCII). ~16 MB/shard resident;
   `O(unique)` reset via a populated-slot list.
2. **Non-ASCII table**: v1 Robin Hood open-addressed hash (reused verbatim,
   20 B slots) for the CJK/non-ASCII tail.

**Postings**: per-trigram list of **file-docid deltas** (not rune positions —
the v2 simplification vs zoekt). TurboPFor-encoded (v1 `turbopfor`, BLOCK=128);
varint fallback for tiny lists. Per-shard docids are LOCAL (0..num_docs);
`metaData.base_docid` maps into the global combined space.

## 7. Combined docid model

Single global u32 docid namespace spanning both layers. Filename docids
`0..N_name` (v1, unchanged). Content shard docids are local per shard, mapped to
global via `shard.base_docid + local_docid`. **Dedup is a path-keyed set union**
(a file matching both layers resolves to one path → one entry), not a string join
across layers. Both layers emit identical canonical absolute paths from the same
walk, so the dedup key matches.

## 8. Query pipeline

For query Q (≥3 bytes; fallback below):

1. **Parse** — reuse v1 `boolquery::parse`. Pure substring → single-term path.
2. **Candidate generation (per layer)** — split Q into byte trigrams (v1
   `trigrams()`). Filename: v1 `single_docids` (rarest posting). Content per
   shard: ASCII array hit (zero hash) or Robin Hood; pick **rarest** trigram,
   intersect the **2 rarest** (trigrep smallest-first, two-pointer on sorted
   TurboPFor-decoded deltas).
3. **Verify (content only)** — for each candidate, mmap-slice its bytes via
   `contentOffsets`+`contentCorpus`, run case-insensitive substring search
   (`memchr`). Survivors are verified matches. This absorbs REVIEW's
   many-list-intersection cost: rarest-trigram prunes to a small candidate set.
4. **Merge + dedup** — union filename + content docids, dedup by resolved path
   (content match wins on conflict). Optional match-kind flag for display.
5. **Shard prune** — before step 2, skip shards whose `dirTable` proves no path
   matches `--scope` (v1 `in_scope` reused).
6. **Stream** — Batch frames of 512 (v1 `STREAM_CHUNK`).

**<3-byte fallback:** 2-char queries use a per-shard **bigram** index (65k-entry
array, same structure). 1-char queries degrade to scan (capped; documented limit,
see §13 risk 5).

## 9. Build pipeline (full-disk, bounded RSS)

v1's `Arc<Mutex<Vec>>` buffer is unbounded → OOM at GB scale. Replace with a
streaming pipeline (lolcate-rs bounded-channel pattern):

```
ignore::WalkParallel (producers)
   →  bounded crossbeam channel (cap ~8000)
      → text-gate (NUL/TrigramMax/1MB cap)  [on walk workers]
         → dual builders: v1 DbBuilder (filename) + ShardBuilder (content)
            → shard flush @ ~128MB → atomic_write → MANIFEST
```

Walker robustness added (bfs-grade): raise `RLIMIT_NOFILE` (~min(64k, sys/16)),
treat EACCES/EPERM/ENOENT(depth>0) as recoverable (race classification),
`--one-file-system` (st_dev compare, skip NFS/Time Machine), sentinel-file
subtree prune (`.git` present → skip). FDA denial tally kept (v1) + extended to
content-skipped-as-binary.

Text gate (zoekt DocChecker + trigrep): NUL in first 8 KB → binary (filename
only); distinct-trigram count > 20000 → likely minified/base64 (filename only);
hard 1 MB size cap → index filename + flag, skip content bytes.

## 10. mmap strategy

- **Content layer = mmap** (memmap2, MAP_SHARED PROT_READ, daemon-lifetime).
  Shards are write-once at build; a rebuild writes NEW files + swaps the set
  atomically → no SIGBUS from writes.
- **Filename layer = pread** (v1 FileSource) — unchanged.
- Daemon opens all shards at startup into a `ShardSet = ArcSwap<Vec<Arc<Shard>>>`
  (zoekt lock-free atomic snapshot). Shard swap on rebuild: `ArcSwap::store`,
  old `Arc`s drop when in-flight queries drain. **Old shard FILES are renamed
  aside (not unlinked) until drain completes** to avoid SIGBUS (risk 4).
- `madvise`: `MADV_RANDOM` on hash/postings (no linear prefetch). ASCII array
  resident. Cold-region `MADV_DONTNEED` optional (OS page cache mostly suffices).
- RSS target: tens of MB + 16 MB/shard ASCII arrays.

## 11. Crate plan

Workspace + 1 new crate:

- **df-core** (pure, extended): all v1 modules reused. Add a `CandidateSource`
  trait (`posting(trig)→Option<Vec<u32>>`, `verify(docid,needle)→bool`) so both
  layers share candidate generation. No I/O.
- **df-index** (I/O layer, extended): keep FileSource/build_index/atomic_write.
  Add `MmapSource` (memmap2-backed `DbSource`), the content `ShardBuilder` +
  shard reader, the bounded-channel streaming build.
- **df-content** (NEW): text-gate, contentCorpus assembly, substring-verify
  (memchr), combined union+dedup, bigram fallback. Depends on df-core + df-index.
- **df-ipc**: extend `ResponseFrame` with `match_kind`; `SearchRequest` content
  flag (default on). serde ignores unknown fields → old/new interop.
- **deepfindd**: keep serve/framed/streaming. Add `ShardSet`; query = filename ∪
  content, dedup, stream. Per-query shard pruning + per-shard parallelism capped
  at CPU.
- **deepfind**: keep subcommands. `search` defaults to both layers;
  `--content`/`--filename` restrict. `index` builds both (new `--max-file-size`,
  `--no-content`, `--one-file-system`). `status` reports shard count + bytes.
  `--direct` extended to online-grep content.

New deps: `memmap2`, `memchr`, `crossbeam-channel` (all standard; crossbeam/memchr
likely already transitive via ignore/tokio).

## 12. CLI / daemon

- `deepfind index [--root] [--force] [--skip …] [--max-file-size 1MB]
   [--no-content] [--one-file-system]` — builds both layers.
- `deepfind search <q> [--content|--filename] [--scope …] [--limit] [-l]
   [--direct]` — combined deduped results, one path/line; `-l` adds match-kind
   marker (`[c]`/`[f]`/`[b]`).
- `deepfind status` — daemon reachable + filename doc count + shard count +
  total content bytes + index age.
- Daemon query: parse → filename query (`spawn_blocking`) ∥ content query
  (per-shard, CPU-capped) → union+dedup → stream.

## 13. Build sequence (M0 → M7)

| Milestone | Deliverable | Verify |
|---|---|---|
| **M0** | Lock v1 behind tests; confirm trigram key + rarest selection contract | v1 suite green |
| **M1** | `CandidateSource` trait; generalize v1 `single_docids` over it | filename query via new abstraction passes |
| **M2** | Shard format: `ShardBuilder` + reader (tagged-TOC/footer), all sections, hand-fed records | roundtrip a synthetic shard: write → mmap → read TOC → fetch posting → slice corpus |
| **M3** | Single-shard content query: parse → rarest → 2-rarest intersect → verify | substring search matches brute-force grep |
| **M4** | Streaming build pipeline (bounded channel), text-gate, dual builders, shard flush, MANIFEST, RLIMIT_NOFILE, `--one-file-system` | build a real `~/subdir`; shards valid; peak RSS bounded |
| **M5** | `ShardSet` (ArcSwap) + daemon integration; filename ∪ content query; `match_kind` frame; `--scope` shard prune | end-to-end `deepfind search` returns combined deduped results |
| **M6** | CLI flags (`--content`/`--filename`/`--max-file-size`/`--no-content`); `status` shards; `--direct` online-grep fallback | daemon-down path returns combined results; FDA guidance on content-skipped |
| **M7** | Hardening: `madvise`, bigram fallback, per-shard CPU-capped parallelism, shard-swap-on-rebuild drain correctness, 1-char cap | full `~` build completes without OOM; latency targets met; RSS in budget |

## 14. Open risks & defaults

1. **Common-trigram degeneration** (`the`, `com`, `src`): candidate set large,
   verify scans many files. **Default (M7):** cap candidate set + warn; accept
   slow common-substring queries as a known v2.0 limit. Revisit positional in v2.1.
2. **Disk budget ~1× corpus** (10–50 GB for home dir). Accepted (raw
   contentCorpus); the 1 MB/file cap bounds worst case.
3. **No incremental → long rebuilds.** Accepted for v2.0. Daemon MUST serve stale
   shards during rebuild (atomic shard-set swap, no offline window). v2.1 adds
   incremental (architecture must not preclude it; the reserved v1 dir-mtime hook
   + MANIFEST signature support this).
4. **mmap SIGBUS on unlink during in-flight query.** Mitigation: rename-aside old
   shards, unlink only after drain (M5).
5. **1-char queries catastrophic at full-disk.** **Default:** refuse/cap 1-char
   content queries in v2.0 (M6/M7), document.
6. **Binary/encoding detection long tail** (UTF-16, minified JS). Heuristic
   acceptable for v2.0; measure in M4/M7.
7. **memmap2 dependency** vs zero-dep ethos. Accepted (user-approved); memmap2 is
   the standard safe choice.

## 15. Dependencies added

`memmap2` (mmap), `memchr` (verify fast path), `crossbeam-channel` (bounded build
pipeline). All lightweight, well-maintained, Rust-standard.

## 16. Completion tracking

| Milestone | Status | Commit range |
|---|---|---|
| M0 (v1 baseline locked) | ✅ done | (baseline; 67 tests pre-Phase-1) |
| M1 (CandidateSource trait) | ✅ done | `584df39`–`5e8941b` (+ `4ba0940`) |
| M2 (shard format: builder + reader + mmap) | ✅ done | `774c46b`–`4e40105` (+ `c75bfae`, `9534ce5`) |
| M3 (single-shard content query) | ✅ done | `639f0b4`–`a8d3931` (+ `9ac4ab8`) |
| **Phase 1 total** | ✅ **70 tests green, clippy/fmt clean** | `584df39^..9ac4ab8` |
| M4 (streaming full-disk build) | ⏳ Phase 2 | — |
| M5 (daemon ShardSet + combined results) | ⏳ Phase 2 | — |
| M6 (CLI flags + `--direct` content grep) | ⏳ Phase 2 | — |
| M7 (hardening: madvise/bigram/parallelism/1-char cap) | ⏳ Phase 2 | — |

Phase 1 verification: per-milestone two-stage review (spec + code-quality) + a final holistic review. The `CandidateSource` abstraction unifies filename (`DbReader`) and content (`ShardReader`) through one `candidates()`; the `.dfcs` format is byte-compatible with v1's Robin Hood/TurboPFor primitives; mmap path documented with the no-truncate SIGBUS invariant.

