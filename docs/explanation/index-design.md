# Index Design — Why Trie + FullSubstringMap + TrigramIndex

DeepFinder's in-memory index uses three complementary data structures. Here's why.

## The Problem

File search needs three kinds of matching:

1. **Prefix matching**: "rep" → "report.pdf", "reports/"
2. **Substring matching**: "ort" → "report.pdf", "airport.jpg"
3. **Fallback for long names**: filenames > 64 characters

One data structure can't do all three well.

## Trie: O(k) Prefix Matching

```
         r
         ├─ e
         │  ├─ p
         │  │  ├─ o
         │  │  │  └─ r
         │  │  │     └─ t → [report.pdf, report_q1.pdf]
```

- **Strength**: Extremely fast prefix matching. Walk the trie for k characters = O(k).
- **Weakness**: No substring matching. "ort" doesn't start at the root, so the trie can't find it.
- **Implementation**: Unicode scalar granularity. Each node maps a scalar to child nodes + posting list.

## FullSubstringMap: O(1) Substring Lookup

For filenames ≤ 64 characters: pre-compute every possible substring and map it to matching FileRecord IDs.

```
"report.pdf" →
  "r"    → [fileID]
  "re"   → [fileID]
  "rep"  → [fileID]
  ...
  "ort"  → [fileID]
  ...
  "report.pdf" → [fileID]
```

- **Strength**: O(1) lookup for any substring. No traversal needed.
- **Weakness**: O(n²) memory for an n-character filename. 64²/2 = ~2K substrings per file. At 500K files, that's ~1B entries.
- **Guard rail**: Only applied to names ≤ 64 characters. Most filenames are under this.

## TrigramIndex: Fallback for Long Names

For filenames > 64 characters (rare): extract 3-character trigrams and store them with posting lists.

```
"very_long_configuration_file_name_2026_final_v2.txt" →
  "ver" → [fileID]
  "ery" → [fileID]
  "ry_" → [fileID]
  ...
```

Query substring is also trigrammed. Intersection of trigram posting lists → candidate set → full verification.

- **Strength**: Handles arbitrarily long names with bounded memory.
- **Weakness**: Slower than FullSubstringMap (intersection + verification step).
- **Usage**: <1% of files have names > 64 characters.

## PinyinIndex: Chinese Filename Search

Chinese filenames (e.g., `报告.pdf`) are tokenized via `CFStringTokenizer` into pinyin syllables (`baogao`). These pinyin tokens are stored in a separate Trie.

Typing `baogao` → PinyinIndex Trie → `报告.pdf`.

- **Strength**: Native Chinese search without requiring Chinese keyboard input.
- **Guard rail**: Only activated when the query contains Latin characters that could be pinyin.

## Memory Budget

On a MacBook Pro M4 Max with 500K files:

| Structure | Memory |
|-----------|--------|
| Trie | ~80 MB |
| FullSubstringMap | ~90 MB |
| TrigramIndex | ~5 MB |
| PinyinIndex | ~15 MB |
| FileRecord array | ~10 MB |
| **Total** | **~200 MB** |

Design principle: **Speed over memory. M4+ unified memory is abundant.**

## Why Not an Inverted Index?

Traditional full-text search uses an inverted index (term → document list). This works for word-based text search but fails for:

- **Single-character queries**: "a" would match every file
- **Arbitrary substrings**: Need to index every possible substring anyway
- **Prefix matching without wildcards**: `rep*` needs a trie

The Trie + FullSubstringMap approach is specialized for filename search, where queries are short, files are many, and sub-millisecond latency is the primary goal.

---

*See [ADR-003: FullSubstringMap 64-Char Threshold Trigram Fallback](../adr/ADR-003-fullsubstringmap-64-char-threshold-trigram-fallback.md) for the design decision.*
