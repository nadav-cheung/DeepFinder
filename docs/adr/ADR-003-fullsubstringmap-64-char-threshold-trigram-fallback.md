# ADR-003: FullSubstringMap 64-Char Threshold and TrigramIndex Fallback

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

Filename substring search is the most performance-critical operation in DeepFinder. Every keystroke in the search field triggers a substring lookup against the entire file index. We needed a data structure that provides sub-millisecond lookup for arbitrary substrings.

Two extreme approaches exist:

1. **FullSubstringMap** — pre-compute every possible substring of every filename. For a name of length N, this generates O(N^2) substrings. Lookup is O(1) dictionary access. Memory cost is high: a 32-character name generates ~528 substrings; a 64-character name generates ~2,080 substrings.

2. **TrigramIndex** — break names into overlapping 3-character trigrams. Query by extracting trigrams from the query substring, intersecting posting lists, then verifying candidates. Memory is O(N) per name, but lookup requires set intersection + verification pass.

The tradeoff is **memory vs CPU**: FullSubstringMap gives instant lookups at massive memory cost; TrigramIndex uses less memory but requires computation at query time.

We measured real-world filename lengths on macOS:
- **~95%** of filenames are <= 64 characters (median ~20 chars)
- **~4%** are 65-128 characters
- **~1%** exceed 128 characters (mostly auto-generated temp files, build artifacts)

## Decision

**Use a two-tier strategy with a hard threshold at 64 characters:**

- **Tier 1: FullSubstringMap** (`Sources/Index/FullSubstringMap.swift`) — handles filenames <= 64 characters. Pre-computes all substrings (O(N^2) memory, O(1) lookup). The `maxNameLength` constant (`64`) gates this. Names exceeding the threshold are silently skipped.

- **Tier 2: TrigramIndex** (`Sources/Index/TrigramIndex.swift`) — handles all filenames, but InMemoryIndex only inserts names > 64 chars into it (optimization: skip the trigram extraction for names already covered by FullSubstringMap). Uses trigram posting-list intersection + exact verification.

The search path in `InMemoryIndex.search()` merges results from both indices:
1. Query FullSubstringMap for the substring (covers ~95% of files)
2. Query TrigramIndex for the same substring (covers the long-tail ~5%)
3. Union the two result sets, deduplicate by FileRecord.ID

The threshold `64` was chosen because:
- At 64 chars, FullSubstringMap generates ~2,080 substrings per name. On a 100,000-file index, this is ~200M dictionary entries. In practice, substring reuse across names with shared prefixes/suffixes reduces this significantly, and M4 unified memory handles it easily.
- The quadratic growth makes 128 chars (~8,256 substrings) and 256 chars (~32,896 substrings) prohibitively expensive for a single long name.
- 64 covers the vast majority of real filenames, making the common case (short names) instant while the rare case (long names) uses the slightly-slower trigram path.

## Consequences

**Positive:**

- **O(1) lookup for the common case.** 95% of files are indexed in FullSubstringMap with instant dictionary access. No trigram extraction, no set intersection, no verification pass.
- **Bounded worst-case memory.** The 64-char cap prevents a single absurdly long filename (e.g., a 500-char auto-generated name) from generating 125,000+ substrings and blowing up the index.
- **Graceful degradation.** Long filenames still work via TrigramIndex. Users typing a query that matches a long filename get results, just with a slightly higher CPU cost.
- **Compositional design.** Both are value types (structs). No inheritance, no protocols. InMemoryIndex owns both and merges results. Easy to test independently.

**Negative:**

- **Threshold is a magic number.** 64 is chosen empirically but may not be optimal for all workloads. A system with many long scientific filenames might want a higher threshold; a memory-constrained system might want lower.
- **Dual maintenance.** Both FullSubstringMap and TrigramIndex must implement insert/remove/search. Changes to the index interface require updating both. The code is ~100 lines each, so this is manageable.
- **No adaptive threshold.** The current implementation uses a static constant. A future optimization could monitor memory pressure and dynamically lower the threshold.

**Alternatives considered and rejected:**

- **Suffix array / suffix automaton:** Full O(N) memory with O(log N) lookup, but implementation complexity is significantly higher than the dictionary-based approach. The two-tier strategy gives similar practical performance with simpler code.
- **Single TrigramIndex for everything:** Simpler code (one data structure), but would lose the O(1) fast path for 95% of queries. TrigramIntersection + verification adds measurable latency at interactive typing speeds.
- **Higher threshold (128 or 256):** Would cover more names with O(1) lookup but at quadratic substring cost. Rejected after profiling showed diminishing returns beyond 64.

## Related

- [ADR-005](ADR-005-unicode-nfc-normalization-strategy.md) — NFC normalization must be applied before inserting into FullSubstringMap and TrigramIndex
- [ADR-006](ADR-006-fseventwatcher-actor-isolation-model.md) — FSEventWatcher calls into InMemoryIndex which orchestrates both data structures
