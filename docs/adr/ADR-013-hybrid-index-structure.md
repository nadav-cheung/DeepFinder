# ADR-013: Hybrid Index Structure — Trie + Hash + Trigram + Pinyin

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

DeepFinder's core value proposition is sub-millisecond filename search across an entire filesystem. Every keystroke in the search field triggers a lookup. This means the search path must be optimized for four distinct query patterns:

1. **Prefix search** — user types "repo" → finds "report.pdf", "repositories/", "report_Q4.docx". This is the most common query type for interactive search (~70% of keystrokes).
2. **Substring search** — user types "port" → finds "report.pdf", "export.csv", "transport/". Also common (~25% of queries).
3. **Long-filename search** — user searches within auto-generated filenames (build artifacts, logs, temp files) that exceed 64 characters (~1% of files but important for developer workflows).
4. **Chinese filename search** — user types pinyin "bao" → finds files with Chinese names containing 报, 包, 保, etc. Critical for Chinese-speaking users (~5% of global userbase but essential for our target market).

A single data structure cannot be optimal for all four patterns. A prefix trie gives O(k) prefix lookup but cannot do substring search. A suffix array gives O(log N) substring search but is complex to update incrementally. A hash map of all substrings gives O(1) lookup but has quadratic memory cost. A trigram index gives O(#postings) intersection but adds CPU overhead at query time.

The challenge is to compose multiple structures into a single index that:
- Provides sub-millisecond lookup for the common case (short-name prefix/substring search)
- Gracefully degrades for rare cases (long names, pinyin)
- Supports incremental updates (single-file insert/remove without full rebuild)
- Operates entirely in memory on Apple Silicon's unified memory architecture (memory is abundant; CPU cycles for query-time computation are the bottleneck)

## Decision

**Use a hybrid composition of four index structures, each optimized for a specific query pattern, orchestrated by the `InMemoryIndex` actor.**

The four structures and their roles:

### 1. Trie — Prefix Matching (`Sources/Index/Trie.swift:12`)

A generic prefix tree (`Trie<Key: UnicodeScalar, Value: Set<UInt32>>`) that stores the NFC-normalized, lowercased Unicode scalar sequence of each filename as the key, and a `Set<UInt32>` of matching FileRecord IDs as the value.

```
Query "repo"
  → walk Trie: r → e → p → o
  → collect all Set<UInt32> values at nodes along the path
  → returns IDs for: report.pdf, repositories/, report_Q4.docx
```

**Characteristics:**
- O(k) lookup where k = query length (typically 3-15 Unicode scalars)
- Insert O(k) — walk/create nodes, upsert ID into Set at terminal node
- Remove O(k) — walk to terminal node, remove ID from Set
- Copy-on-write via `Node` (reference type) + `isKnownUniquelyReferenced` + `deepCopy()`. Value semantics for the struct, reference semantics for sharing until mutation.
- Unicode scalar granularity — not UTF-8 byte, not Character (grapheme cluster). Balances correctness (respects Unicode boundaries) with simplicity (scalars are fixed-width for iteration).

### 2. FullSubstringMap — O(1) Substring for Short Names (`Sources/Index/FullSubstringMap.swift:12`)

A dictionary mapping every possible substring of every filename (up to 64 characters) to a set of matching FileRecord IDs.

```
Filename: "report.pdf" (10 chars)
Substrings generated: "r", "e", "p", ..., "re", "ep", "po", ..., "rep", "epo", "por", ..., "report.pdf"
Total substrings: ~55 (10*11/2)
Dictionary entry: "port" → {ID_report}
Query "port": one dictionary lookup → {ID_report}
```

**Characteristics:**
- O(1) lookup — a single dictionary access
- O(N^2) memory per name — a 32-char name generates ~528 entries; a 64-char name generates ~2,080 entries
- Hard threshold at 64 characters (`FullSubstringMap.maxNameLength`) — names exceeding this are silently skipped
- Covers ~95% of real-world filenames (median filename length on macOS is ~20 characters)
- In practice, substring reuse across filenames with shared substrings (e.g., multiple files containing "report") reduces the total entry count significantly below the theoretical maximum

### 3. TrigramIndex — Substring for Long Names (`Sources/Index/TrigramIndex.swift`)

A trigram-based inverted index for filenames exceeding 64 characters. Each filename is decomposed into overlapping 3-character trigrams. Each trigram maps to a posting list (set of FileRecord IDs). At query time, the query string is also decomposed into trigrams, their posting lists are intersected, and candidates are verified against the original filename.

```
Filename: "very_long_build_artifact_2026-06-03T12-00-00.log" (50 chars, but for illustration)
Trigrams: "ver", "ery", "ry_", "y_l", ..., ".lo", "log"
Query "build":
  Query trigrams: "bui", "uil", "ild"
  Intersection: posting("bui") ∩ posting("uil") ∩ posting("ild")
  Candidates verified against original filename
```

**Characteristics:**
- Memory O(N) per name — 3 trigrams per position = (name length - 2) entries
- Query: O(#postings) for intersection + O(#candidates) for verification
- Only used for names > 64 characters — the `InMemoryIndex.insert()` method gates on `name.count > FullSubstringMap.maxNameLength`
- Handles the long-tail of auto-generated filenames (build artifacts, logs, temporary files)

### 4. PinyinIndex — Chinese Filename Search (`Sources/Index/PinyinIndex.swift`)

Uses `CFStringTokenizer` to identify Chinese tokens in filenames, then `CFStringTransform` to convert them to pinyin (Latin script representation). Both full pinyin ("baogao") and first-letter abbreviations ("bg") are indexed in their own Tries.

```
Filename: "季度报告.docx" (quarterly report)
CFStringTokenizer finds tokens: 季度, 报告
CFStringTransform converts: jidu, baogao
Indexed:
  Full pinyin Trie: "jidu" → {ID}, "baogao" → {ID}, "jidubaogao" → {ID}, "baogao" → {ID} (suffix)
  First-letter Trie: "jd" → {ID}, "bg" → {ID}
Query "baogao": matches full pinyin Trie → finds 季度报告.docx
Query "bg": matches first-letter Trie → finds 季度报告.docx
```

**Characteristics:**
- Uses `CFStringTokenizer` with `kCFStringTokenizerUnitWord` for Chinese token boundary detection
- Uses `CFStringTransform` with `kCFStringTransformToLatin` + `kCFStringTransformStripDiacritics` for pinyin conversion
- Suffix insertion at token boundaries enables mid-query matching (e.g., "baogao" matches even though the full inserted key is "jidubaogao")
- Non-Chinese tokens are silently skipped — the `tokenContainsChinese()` check tests for CJK Unified Ideographs ranges
- Stores both full pinyin and first-letter abbreviation in separate Tries

### Unified Search Path

`InMemoryIndex.search()` (`Sources/Index/InMemoryIndex.swift:233`) queries all four structures and unions the results:

```swift
func search(query: String) -> [FileRecord] {
    let lowered = query.precomposedStringWithCanonicalMapping.lowercased()
    let scalars = Array(lowered.unicodeScalars)

    var matchedIDs = Set<UInt32>()

    // 1. Trie prefix matches
    let trieResults = trie.search(prefix: scalars)
    for set in trieResults { matchedIDs.formUnion(set) }

    // 2. FullSubstringMap substring matches
    let substringResults = substringMap.search(substring: lowered)
    matchedIDs.formUnion(substringResults)

    // 3. TrigramIndex matches (long names)
    let trigramResults = trigramIndex.search(substring: lowered)
    matchedIDs.formUnion(trigramResults)

    // 4. PinyinIndex matches (Chinese filenames)
    let pinyinResults = pinyinIndex.search(pinyin: lowered)
    matchedIDs.formUnion(pinyinResults)

    // 5. Look up records, sort by ID
    return matchedIDs.compactMap { records[$0] }.sorted { $0.id < $1.id }
}
```

Result deduplication is automatic via `Set<UInt32>` union. The same file may appear in multiple structures (e.g., a short Chinese filename appears in Trie, FullSubstringMap, AND PinyinIndex) — the Set ensures it is returned once.

## Alternatives Considered

### A. Single Suffix Array

Build a generalized suffix array over all filenames concatenated with sentinel separators. Substring search becomes a binary search over the suffix array (O(log N + k) for k results).

**Rejected because:**
- **Complex incremental updates.** Inserting or deleting a single filename requires rebuilding a portion of the suffix array — not a simple append operation. The FullSubstringMap approach handles single-file updates naturally (just add or remove the filename's substrings from the dictionary).
- **Implementation complexity.** A correct, performant suffix array implementation (with LCP array for efficient string matching) is significantly more complex than a dictionary + trie composition. Our four structures are individually simple (~100-200 lines each) and easy to reason about.
- **No natural prefix optimization.** Suffix arrays optimize for arbitrary substring search but have no special-case optimization for prefix search, which is the most common query pattern. A Trie gives O(k) prefix lookup with a simple walk.

### B. Pure Inverted Index (Like Lucene's Term Dictionary)

Tokenize filenames into terms (split on word boundaries, delimiters, case changes), build an inverted index mapping terms to posting lists.

**Rejected because:**
- **Tokenization mismatch.** Filenames don't have natural word boundaries. "Q4Report2026.pdf" — how do you tokenize this? By case changes ("Q4", "Report", "2026")? By delimiters? By n-grams? The user might search for "4Rep" (crossing a token boundary) and expect to find it. A substring-based approach handles this naturally; an inverted index requires query-time expansion.
- **Overkill for filenames.** Inverted indices shine for full-text search where terms have semantic meaning and stop words can be removed. Filenames are short strings where every character is potentially searchable. The term abstraction adds complexity without benefit.
- **No prefix optimization.** An inverted index gives O(log N) term lookup via a sorted dictionary but no O(k) prefix walk like a Trie.

### C. Finite State Transducer (FST)

Build a minimal deterministic automaton representing the set of all filenames. Works well for dictionary-like lookups and can support prefix/suffix queries with appropriate construction.

**Rejected because:**
- **No natural substring support.** An FST built for prefix matching cannot efficiently answer substring queries without additional construction (e.g., building a suffix FST). Our FullSubstringMap gives O(1) substring lookup with a trivially simple implementation.
- **CJK complexity.** FSTs encode strings as byte sequences. Unicode scalar-level operations (which our Trie supports natively) would require careful encoding choices.
- **Incremental updates are expensive.** Modifying an FST typically requires a rebuild. Our dictionary+Trie approach handles single-file inserts/removes efficiently.

### D. Single FullSubstringMap with No Threshold

Index ALL filenames as substrings, regardless of length. Remove the 64-character threshold.

**Rejected because:**
- **Pathological memory cost.** A single 500-character auto-generated filename would generate ~125,000 substring entries. While M4 unified memory is abundant, this is wasteful memory for a filename the user will likely never search for.
- **Diminishing returns beyond 64.** 95% of real filenames are already covered. The remaining 5% are disproportionately long and expensive to index with FullSubstringMap but cheap with TrigramIndex.

## Consequences

### Positive

- **Optimal performance for the common case.** ~70% of queries (prefix) hit the Trie's O(k) fast path. ~25% (substring) hit FullSubstringMap's O(1) dictionary lookup. The remaining ~5% (long names, pinyin) use the slightly more expensive but still fast TrigramIndex and PinyinIndex paths.
- **Compositional design.** Each structure is a simple, independent Swift struct. They share no state and have no dependencies on each other. `InMemoryIndex` owns all four and merges their results. Each can be tested, benchmarked, and optimized independently.
- **Incremental updates.** Inserting a single file adds its entries to all four structures independently. Removing a file removes its entries from all four. No cross-structure coordination. No rebuild required.
- **Graceful degradation.** If FullSubstringMap can't index a name (due to the 64-char threshold), TrigramIndex covers it. If PinyinIndex finds no Chinese characters in a name, it correctly returns no results. No query pattern is completely unserved.
- **Value type safety.** All four structures are structs with value semantics. No locks, no race conditions. When used inside the `InMemoryIndex` actor, thread safety is guaranteed by actor isolation — no internal synchronization is needed within any structure.
- **Memory efficiency for the common case.** The 64-char threshold prevents unbounded memory growth from a few pathological long filenames while covering 95% of real-world files with instant O(1) lookup.

### Negative

- **Four structures to maintain.** Each structure implements `insert(name:id:)`, `remove(name:id:)`, and `search(...)`. Changes to the index interface must be reflected in all four. Each is ~100-200 lines, so total code is ~800 lines for index structures — manageable but requires discipline.
- **No shared query planning.** The `InMemoryIndex.search()` method queries all four structures independently and unions results. There is no query planner that decides "this is clearly a prefix query, skip FullSubstringMap and TrigramIndex." A future optimization could add query classification to skip unnecessary structure lookups.
- **Memory duplication of IDs.** The same `FileRecord.id` may appear in multiple structures (Trie, FullSubstringMap, AND PinyinIndex for a short Chinese filename). The memory overhead of duplicate `UInt32` values across structures is negligible compared to the filename substrings.
- **Trie COW copies.** The Trie's copy-on-write design means that after an insert, the entire path from root to terminal node is deep-copied. For concurrent reads after a write, this is correct (readers see the old version). For a write-heavy workload (initial scan), this means many allocations. Mitigation: the initial scan batches inserts into `InMemoryIndex` sequentially, not concurrently, so COW copies are minimal (the Trie is not shared during scan).
- **FullSubstringMap memory scaling.** While the 64-char threshold bounds per-file memory, the total memory still grows with the filesystem. A system with 500,000 files averaging 20 characters each generates ~100M substring entries in the map. On M4 with 16GB+ unified memory, this is acceptable (~2-4 GB). The TrigramIndex provides memory headroom for the long-tail.

### Mitigation

1. **Protocol-based refactoring planned.** A future `SubIndex` protocol would define `func insert(name: String, id: UInt32)` and `func search(...)` methods, making the four structures pluggable and enabling cleaner composition. The `InMemoryIndex` would hold `[any SubIndex]` instead of four named properties.

2. **FullSubstringMap replacement.** The current FullSubstringMap has quadratic memory cost. A replacement based on a suffix automaton or compressed substring index is planned to reduce memory while maintaining O(1)-equivalent lookup performance.

3. **Query classification.** A future enhancement could classify queries as "definitely prefix" (e.g., short query with no internal wildcards) and skip the substring/pinyin structures, reducing the number of lookups per query from 4 to 1 for the most common case.

## Related

- [ADR-003](ADR-003-fullsubstringmap-64-char-threshold-trigram-fallback.md) — Detailed analysis of the 64-char threshold and FullSubstringMap/TrigramIndex tradeoff
- [ADR-005](ADR-005-unicode-nfc-normalization-strategy.md) — NFC normalization applied before insertion into all four structures
- [ADR-011](ADR-011-actor-based-concurrency.md) — Actor isolation for InMemoryIndex which owns all four structures
