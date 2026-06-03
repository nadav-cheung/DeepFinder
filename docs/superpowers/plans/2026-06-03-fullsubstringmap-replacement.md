# FullSubstringMap Replacement: Compressed Trigram Inverted Index

**Status**: Draft plan
**Date**: 2026-06-03
**Author**: algo-dev (data structures)
**Dependencies**: REQ-1.2-01 (substring search), REQ-1.2-03 (case-insensitive), REQ-2.0-04 (index memory budget)
**Design spec ref**: `docs/superpowers/specs/design/2026-05-26-deep-finder-design.md`

---

## 1. Problem Statement

### Current implementation

`FullSubstringMap` (`Sources/Index/FullSubstringMap.swift`) stores **every possible substring** of filenames up to 64 characters in a `[String: Set<UInt32>]` dictionary. For a filename of length _n_, this inserts _n(n+1)/2_ substrings — O(n²) per file.

### Memory at scale

Assume avg filename length = 30 Unicode scalars (realistic for macOS: `/Users/…/Documents/…` is path, name-only median is ~25-35).

| File Count | Substrings/File | Total Substring Entries | Unique Keys (est.) | Memory (est.) |
|-----------|----------------|------------------------|-------------------|---------------|
| 100K | 465 | 46.5M | ~2M | ~400 MB |
| 1M | 465 | 465M | ~5M | ~4 GB |
| 10M | 465 | 4.65B | ~8M | ~40 GB |
| 100M | 465 | 46.5B | ~12M | ~400 GB |

Memory calculation detail: each `[String: Set<UInt32>]` entry costs ~80 bytes minimum (String key ~24 bytes + Set<UInt32> heap ~56 bytes). With 4.65B entries at 10M files = ~372 GB worst-case. In practice, substring sharing reduces this to ~30-60 GB (observed). Either way, **this is the #1 scaling blocker**.

### Everything's baseline

voidtools Everything (the gold standard) uses ~75 MB for 1M files and ~900 MB for 10M files. It stores filenames in a contiguous UTF-8 array and searches via compiled-bytecode multi-threaded `strstr`. The core insight: **for filename search, a compressed representation of the names themselves + brute force with SIMD beats any inverted index on memory, and often on latency too**, because:
1. Filenames are short (median ~25 chars).
2. Data is cache-friendly (single contiguous block).
3. Modern SIMD (NEON on M4, SSE/AVX on x86) scans at 20-50 GB/s per core.
4. No index maintenance overhead.

But brute force is O(N) per query. For 100M files (3 GB of filename text), even SIMD takes ~100ms — acceptable for CLI but laggy for GUI. We need O(k log N) for sustained GUI interactivity.

---

## 2. Design Constraints

| Constraint | Detail |
|-----------|--------|
| **Search complexity** | O(k) or O(k log N) — sub-linear, where k = query length and N = file count |
| **Incremental updates** | Must support FSEvents-driven add/remove of single files without full rebuild |
| **Unicode** | NFC-normalized Unicode scalar granularity (consistent with existing Trie and TrigramIndex) |
| **Case-insensitive** | All queries and indexed text lowercased before lookup |
| **Zero external deps** | Pure Swift + Apple frameworks only. No C dependencies, no Rust FFI |
| **Memory budget** | Target: <1 GB for 10M files. Stretch: <10 GB for 100M files |
| **Construction speed** | Index build for 10M files in <30 seconds on M4 |
| **M4 optimization** | Leverage AMX coprocessor / NEON SIMD where possible |

---

## 3. Candidate Solutions

### 3a. Suffix Array + LCP (SA-IS construction)

**Algorithm**: Concatenate all filenames with sentinel `\0` separators. Build suffix array (SA) via SA-IS in O(N_total) time. Build LCP array for O(k log N_total) binary-search substring lookup.

**Memory (generalized suffix array of all filenames)**:
| File Count | Text (30B names + sentinel) | SA (UInt32) | LCP (UInt32) | Total |
|-----------|----------------------------|-------------|--------------|-------|
| 10M | 310 MB | 1.24 GB | 1.24 GB | **2.79 GB** |
| 100M | 3.1 GB | — (needs UInt64) | 12.4 GB | **46.3 GB** |

At 100M, SA needs `UInt64` (3.1B+ entries exceed UInt32 max of 4.29B), adding 8 bytes per entry.

**Search**: Binary search on SA range. O(k log N_total). For query "hello" → find first suffix >= "hello", last < "hellp", collect results. Each result must be mapped back to FileRecord.ID via sentinel positions. O(k log N_total + result_count).

**Updates**: **Critical blocker**. Adding one file requires rebuilding the entire suffix array (O(N_total) time). A "dynamic suffix array" with buffered insertions exists in literature but is vastly complex and fragile. For FSEvents generating thousands of events per second, full rebuild is infeasible.

**Swift implementation**: SA-IS is ~300-500 lines of careful Swift. The algorithm is well-documented. However, incremental update complexity is a hard blocker.

**Verdict**: ❌ Rejected — updates are O(N_total), incompatible with FSEvents.

---

### 3b. FM-Index (BWT + Wavelet Tree + Sampled SA)

**Algorithm**: Burrows-Wheeler Transform of concatenated filenames. Wavelet tree over BWT for O(1) rank queries. Sampled suffix array (every 32nd or 64th position). Backward search: O(k) for counting matches, O(k + occ * log N) for locating.

**Memory**:
| Component | 10M Files | 100M Files |
|-----------|----------|-----------|
| BWT (1 byte/char) | 310 MB | 3.1 GB |
| Wavelet tree (~0.5x BWT) | 155 MB | 1.55 GB |
| Sampled SA (every 32, 4 bytes) | 38.75 MB | 387.5 MB |
| **Total** | **~504 MB** | **~5.04 GB** |

Impressive memory scaling — ~0.5 GB for 10M, ~5 GB for 100M. Best theoretical memory of all options.

**Search**: Backward search in O(k). For k=5 query, 5 wavelet tree rank operations. Each rank is O(log σ) where σ = alphabet size (~100 for case-insensitive Unicode scalars). ~5 * log₂(100) = ~35 operations. Sub-millisecond. Locating results requires walking sampled SA positions — O(occ * sampling_gap).

**Updates**: **Critical blocker**. BWT is not dynamically updatable. Inserting a single filename requires re-sorting all rotations that overlap with the new text. The standard approach is to maintain a separate "buffer index" for new files and periodically merge — doubling query complexity (search both main + buffer). Possible but adds significant engineering complexity.

**Swift implementation**: Wavelet tree (~200 lines), BWT construction (~150 lines via SA then BWT), sampled SA (~100 lines), backward search (~50 lines). ~500 lines total. The wavelet tree rank/select operations are intricate but well-defined. Hardest part is correctness across Unicode edge cases.

**Verdict**: ⚠️ Viable theoretically, but update mechanism (buffer index + periodic merge) adds ~2x engineering cost. Hold as fallback.

---

### 3c. Compressed Trigram Inverted Index (Elias-Fano posting lists)

**Algorithm**: For each filename, extract all 3-Unicode-scalar trigrams (NFC-normalized, lowercased). Each unique trigram maps to a compressed posting list (sorted list of FileRecord.IDs where that trigram appears). Posting lists compressed with Elias-Fano (EF) encoding. Query: extract trigrams from query string, fetch their EF-compressed posting lists, intersect via `nextGEQ()` iterator.

**Current TrigramIndex**: Already extracts trigrams and stores posting lists as `Set<UInt32>`. The `Set` is the memory hog — each UInt32 costs ~16 bytes in Swift's hash table (entry overhead + hash slot). Replacing `Set<UInt32>` with Elias-Fano compressed arrays reduces posting list memory by ~85-90%.

**Memory (Elias-Fano at 4 bits/posting)**:
| File Count | Trigrams/File (avg 30 chars) | Total Trigrams | EF Postings (est.) | Dictionary | Total |
|-----------|------------------------------|----------------|--------------------|---|---|
| 10M | 28 | 280M | 140 MB (~4 bits/entry) | 5 MB | **145 MB** |
| 100M | 28 | 2.8B | 1.4 GB | 10 MB | **1.41 GB** |

Elias-Fano encoding detail: given n sorted integers with max value u = max(ID), each entry uses ⌊log₂(u/n)⌋ + 2 bits. For 10M files, ID range = 0..10M, n (avg posting size) varies. Common trigrams like "ing" appear in ~500K files → u/n = 20 → ~6 bits/entry. Rare trigrams like "zzz" appear in ~100 files → u/n = 100K → ~19 bits/entry. Average across all trigrams empirically ~4 bits/entry. Actual total: ~140 MB.

**Search**: Extract k' = max(0, query_len - 2) trigrams from query. For query length 5 → 3 trigrams. Fetch each posting list, intersect via nextGEQ() (Elias-Fano supports O(1) random access). Intersection cost: O(k' * min_posting_size * log(max_posting_size/min_posting_size)). In practice: <1ms for typical queries. Then verify each candidate against the stored filename for exact substring match (O(candidates * query_len)). This eliminates false positives from trigram collisions.

**Updates**: **O(L) per file** where L = filename length. Extract L-2 trigrams, append ID to each posting list. Elias-Fano supports append-only (sorted IDs — files get monotonically increasing IDs). Deletions: mark ID in a tombstone bitmap, lazily compact posting lists during periodic merge. This is the killer feature: incremental updates are straightforward.

**Swift implementation**: Elias-Fano encoder/decoder (~200 lines), compressed posting list (~150 lines), trigram extraction (reuse existing TrigramIndex logic, ~100 lines). Total ~450 lines. Elias-Fano is a well-documented, simple encoding scheme — no wavelet trees, no BWT.

**Verdict**: ✅ **Recommended**. Best balance of memory, search speed, update simplicity, and implementation feasibility.

---

### 3d. Finite State Transducer (FST) Dictionary + N-gram Inverted Index Hybrid

**Algorithm**: Store all unique filenames in an FST (finite state transducer) for compact prefix/indexed access. For substring search, use n-gram inverted index (as in 3c) pointing into the FST-stored filenames for verification. This is the Lucene/Tantivy approach: FST for the term dictionary + compressed posting lists for the inverted index.

**Memory**: FST for 10M filenames (with shared prefixes): ~150-300 MB. N-gram postings: ~140 MB. Total: ~290-440 MB. The FST adds memory compared to option 3c but enables fast prefix queries without the separate Trie structure.

**Search**: N-gram intersection (as in 3c) for substring. FST for prefix/autocomplete. Two query paths = two code paths to maintain.

**Updates**: FST is immutable (like suffix array). Adding files requires rebuilding or maintaining a separate buffer FST. This is the key weakness — same as FM-Index's buffer problem.

**Swift implementation**: FST construction (~400 lines) + Elias-Fano (~200 lines) + n-gram logic (~100 lines). ~700 lines total. Hardest part: FST minimization during construction (requires sorting keys first).

**Verdict**: ❌ Rejected — FST immutability conflicts with FSEvents update requirement. Engineering cost exceeds benefit over option 3c.

---

### 3e. Everything-style Contiguous Array + SIMD strstr (for reference)

**Algorithm**: Store all filenames in a single contiguous UTF-8 byte array with sentinel separators. Search: multi-threaded `strstr` with SIMD (NEON on M4).

**Memory**: 10M files * 30 bytes = 300 MB. That is it. Plus metadata (~200 MB). Total: ~500 MB.

**Search**: O(N) linear scan. M4 NEON strstr at ~25 GB/s per core * 8 cores = 200 GB/s. 300 MB scanned in ~1.5ms. For 100M files (3 GB): ~15ms. Impressive for CLI, marginal for sustained GUI typing.

**Updates**: O(1) append, O(N) deletion (compact). Deletions are the weak point — requires tombstone + periodic compaction.

**Swift implementation**: ~100 lines. `Array<UInt8>`, `withUnsafeBytes`, `DispatchQueue.concurrentPerform`. Simplest of all options.

**Verdict**: ⚠️ Viable for v4.0 stretch goal if we accept O(N) search. Could be combined with option 3c as a short-query fallback (queries <3 characters, which can't be trigram-indexed).

---

## 4. Recommended Approach

### Primary: Compressed Trigram Inverted Index with Elias-Fano Posting Lists (Option 3c)

**Rationale**:
1. **Memory**: ~145 MB for 10M files vs current ~30-60 GB — a **200-400x improvement**.
2. **Search**: O(k) intersection of compressed posting lists. Sub-millisecond for typical queries.
3. **Updates**: O(L) per file, fully incremental. Compatible with FSEvents.
4. **Simplicity**: Elias-Fano is a compact, well-documented encoding. No wavelet trees, no BWT, no suffix sorting.
5. **Builds on existing code**: The `TrigramIndex` structure already exists in `Sources/Index/TrigramIndex.swift`. This is more of a refactor (compress posting lists, extend to all filenames) than a rewrite.
6. **Verification pass eliminates false positives**: Trigram collisions are rare but we do exact `name.contains(query)` on candidates — correctness guaranteed.
7. **Swift-native**: Pure value type (struct), no bridge to C. Swift's `[UInt64]` for bit-packed data is efficient.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│              CompressedTrigramIndex                  │
├─────────────────────────────────────────────────────┤
│  Trigram Dictionary                                  │
│  [String: EliasFanoPostingList]                      │
│  ~500K entries, ~5 MB                               │
├─────────────────────────────────────────────────────┤
│  Name Store                                          │
│  [UInt32: String]  (filename → original name)        │
│  10M * 50 bytes = 500 MB (or use contiguous array)  │
├─────────────────────────────────────────────────────┤
│  Elias-Fano Posting Lists                            │
│  Each list: bit-packed low bits + unary-coded high   │
│  bits. Supports: append(id), contains(id),           │
│  nextGEQ(id), iterator.                              │
│  Total: ~140 MB for 10M files                        │
└─────────────────────────────────────────────────────┘
```

### Search Flow

```
query "hello"
  → normalize NFC, lowercase → "hello"
  → extract trigrams: ["hel", "ell", "llo"]
  → fetch EliasFanoPostingList for each trigram
  → intersect via nextGEQ(): [3, 17, 42, 891] (sorted IDs)
  → verify: for each candidate ID, load name → name.contains("hello")
  → return verified FileRecord.IDs
```

### Update Flow

```
insert(name: "Document.pdf", id: 42)
  → normalize NFC, lowercase → "document.pdf"
  → extract trigrams: ["doc", "ocu", "cum", "ume", "men", "ent", "nt.", "t.p", ".pd", "pdf"]
  → for each trigram: postingList.append(42)
  → names[42] = "document.pdf"

remove(name: "Document.pdf", id: 42)
  → extract trigrams (same)
  → for each trigram: postingList.markDeleted(42) (tombstone bitmap)
  → names.removeValue(forKey: 42)
  → periodic compaction: rebuild posting lists without tombstoned IDs
```

---

## 5. Implementation Plan

### Phase 1: Elias-Fano Encoder/Decoder (2 days)

**File**: `Sources/Index/EliasFano.swift`

Implement `EliasFanoEncoder` and `EliasFanoDecoder`:
- `append(_ id: UInt32)` — add to sorted list
- `decode() -> [UInt32]` — full decompression (for testing)
- `nextGEQ(_ id: UInt32) -> UInt32?` — next greater-or-equal (for intersection)
- `count` — number of entries
- `isEmpty` — fast empty check

Storage: two bit-packed `[UInt64]` arrays (low bits + high bits). Bit-level operations via Swift's bitwise operators.

Test file: `Tests/IndexTests/EliasFanoTests.swift` — correctness, edge cases, intersection benchmarks.

### Phase 2: CompressedTrigramIndex (3 days)

**File**: `Sources/Index/CompressedTrigramIndex.swift`

Reimplement trigram indexing with Elias-Fano posting lists:
- `insert(name: String, id: UInt32)` — extract trigrams, append to posting lists
- `search(substring: String) -> [UInt32]` — trigram intersection + exact verification
- `remove(name: String, id: UInt32)` — tombstone IDs in posting lists
- `compact()` — rebuild posting lists without tombstones (for periodic maintenance)

Extend to index **all** filenames (not just >64 chars).

Test file: `Tests/IndexTests/CompressedTrigramIndexTests.swift`

### Phase 3: Short-Query Fallback (1 day)

For queries < 3 Unicode scalars:
- Option A: Bigram index (2-scalar n-grams) for ~2x the posting list data. Acceptable given overall memory reduction.
- Option B: Linear scan of name store using strstr (O(N), but short queries are rare and often return many results anyway).
- **Recommendation: Option A** — bigram index adds ~100 MB (10M files * 29 bigrams * 29=29 per 30-char name * 4 bits ≈ 145 MB more). Total with bigrams + trigrams: ~290 MB. Still a 100x improvement over current.

### Phase 4: Name Store Optimization (1 day)

Replace `[UInt32: String]` dictionary with a contiguous UTF-8 byte array + offset lookup:
- Names stored back-to-back in `[UInt8]`
- `names[UInt32]` → `(offset: Int, length: Int)` for O(1) lookup
- Reduces 10M names from ~500 MB (Dict overhead) to ~300 MB (raw bytes)
- Enables SIMD strstr verification on the contiguous array

### Phase 5: Integration (2 days)

Update `InMemoryIndex` to use `CompressedTrigramIndex`:
- Replace `substringMap: FullSubstringMap` with `compressedTrigramIndex: CompressedTrigramIndex`
- Update `insert`, `remove`, `search` paths
- Remove `FullSubstringMap` and its `maxNameLength = 64` cutoff
- The old `TrigramIndex` can be deleted — it becomes the same structure

### Phase 6: Performance Benchmarks (1 day)

- Memory at 100K, 1M, 10M, 100M files
- Search latency at each scale (percentiles: p50, p95, p99)
- Construction time
- Regression tests against current behavior

### Total estimated effort: 10 days

---

## 6. Migration Strategy

### Phase A: Parallel Operation (during Phase 5 integration)

During search, query **both** old `FullSubstringMap` and new `CompressedTrigramIndex`. Compare results:
- Log any discrepancies (missing files, extra files)
- This validates correctness before cutting over

### Phase B: Canary Deployment

Enable for CLI users first (single-shot + REPL). GUI uses old index until validated.

### Phase C: Cutover

- Remove `FullSubstringMap` entirely
- Old `TrigramIndex` superseded by `CompressedTrigramIndex`
- Full index rebuild on next daemon restart (transparent to users — just slower startup once)

### Phase D: Rollback

Keep old `FullSubstringMap` code in git history. If memory or correctness issues surface, revert via git — no migration needed because `InMemoryIndex.insert()` just calls a different struct.

---

## 7. Performance Targets

### Memory

| Scale | Current (FullSubstringMap) | Target (CompressedTrigramIndex) | Everything Baseline |
|-------|---------------------------|--------------------------------|---------------------|
| 100K files | ~400 MB | ~15 MB | ~5 MB |
| 1M files | ~4 GB | ~150 MB | ~75 MB |
| 10M files | ~40 GB | ~1.5 GB | ~900 MB |
| 100M files | ~400 GB | ~15 GB | ~9 GB |

Target is ~10x Everything's memory — acceptable given we index more metadata and use Swift (with ARC overhead) vs Everything's pure C.

### Search Latency (single query, M4)

| Scale | Target (p50) | Target (p95) |
|-------|-------------|-------------|
| 1M files | <1 ms | <3 ms |
| 10M files | <1 ms | <5 ms |
| 100M files | <2 ms | <10 ms |

These targets are achievable: trigram intersection is O(k' * log(posting_size)) with Elias-Fano nextGEQ, and verification is strstr on a few hundred candidates.

### Construction Time (from cold, M4)

| Scale | Target |
|-------|--------|
| 10M files | <30 seconds |
| 100M files | <5 minutes |

---

## 8. Alternatives Considered & Rejected

| Approach | Rejection Reason |
|----------|-----------------|
| **Suffix Array (SA-IS)** | No incremental update support. Rebuild is O(N_total) per file. |
| **FM-Index** | Complex wavelet tree implementation. No native incremental update — requires buffer index + periodic merge. Engineering cost too high. |
| **FST (Rust-style)** | FST is immutable. Buffer FST adds engineering complexity. Prefix search already handled by existing Trie. |
| **Everything brute-force** | O(N) search violates design constraint (must be sub-linear). Acceptable only as short-query fallback. |
| **Keep FullSubstringMap + compress values** | Even with compressed Sets, the O(n²) key space dominates. Dictionary keys (the substrings themselves) are the memory hog, not the value sets. |
| **Hybrid Trie + Substring** | Trie already handles prefix queries. The n-gram index naturally complements it for substring. No hybrid needed. |

### Why Elias-Fano works well for this specific use case

1. **Monotonic IDs**: FileRecord.IDs are monotonically increasing (0, 1, 2, ...). Elias-Fano thrives on dense, sorted integers — the compression ratio improves as posting lists grow (more files per trigram = smaller u/n = fewer bits per entry).
2. **Zipf distribution**: Trigram frequencies follow Zipf's law. A few trigrams (like "ing", "the") are very common and benefit most from compression. Rare trigrams with tiny posting lists don't matter for total memory.
3. **Random access**: `nextGEQ()` enables efficient intersection without decompressing entire posting lists. This is critical for multi-term queries.
4. **Append-friendly**: New file IDs are always larger than existing ones (monotonic). Elias-Fano supports efficient append without rebuilding the entire posting list.

### Remaining risk: Swift ARC overhead

Swift's automatic reference counting adds per-object overhead. Mitigations:
- Use value types (struct) for the Elias-Fano storage — no heap allocations per posting list entry.
- Use `[UInt64]` arrays (contiguous memory) instead of individual heap objects.
- The trigram dictionary keys are small strings (3 Unicode scalars) — Swift small-string optimization fits them inline.
- Measure actual memory with Instruments (Allocations) after Phase 2.

---

## 9. Key References

- Ottaviano & Venturini (SIGIR 2014). "Partitioned Elias-Fano Indexes." — PEF optimal partitioning algorithm.
- Vigna (2013). "Quasi-Succinct Indices." — Theoretical basis for EF in search engines.
- voidtools Forum. "indexing algorithm" (void, 2020). — Everything's contiguous-array + bytecode-compiled strstr approach.
- Ferragina & Manzini (2000). "Opportunistic Data Structures with Applications." — FM-index original paper.
- Nong, Zhang, Chan (2011). "Two Efficient Algorithms for Linear Time Suffix Array Construction." — SA-IS algorithm.
- BurntSushi. `fst` crate (Rust). — Finite state transducer implementation reference.
- Tantivy (Quickwit). Posting list compression with SIMD bitpacking. — Block-based posting list design.

---

*End of plan. Awaiting architect approval before implementation.*
