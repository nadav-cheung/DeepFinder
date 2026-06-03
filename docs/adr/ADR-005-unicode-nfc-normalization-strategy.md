# ADR-005: Unicode NFC Normalization Strategy

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

macOS filenames are stored in Unicode. The HFS+ and APFS filesystems enforce **NFD** (Normalization Form Canonical Decomposition) for filenames on disk: the character "é" is stored as two code points (U+0065 "e" + U+0301 combining acute accent).

However, user input (search queries, command-line arguments) typically arrives in **NFC** (Normalization Form Canonical Composition): "é" as a single code point (U+00E9). String comparison between NFC and NFD representations of the same visual character fails unless both strings are normalized to the same form.

Without normalization, a user typing "café" would not find a file named "café" (stored in NFD by the filesystem), and vice versa. This is a real bug: macOS Finder handles it transparently because it normalizes behind the scenes, but raw byte-level comparison does not.

The problem is particularly acute for:
- **Chinese, Japanese, Korean (CJK) filenames.** Some CJK characters have multiple valid Unicode representations (compatibility ideographs, variation selectors).
- **European diacritics.** "ü", "ñ", "ç", "ø" are common in German, Spanish, French, Norwegian filenames.
- **Emoji filenames.** Emoji sequences (ZWJ, skin tone modifiers, flag sequences) have complex normalization behavior.

## Decision

**Normalize all filenames and queries to NFC using `String.precomposedStringWithCanonicalMapping`.**

Implementation across the codebase:

| Location | Normalization point |
|----------|-------------------|
| `FileRecord.name` | NFC-normalized at construction time |
| `FileRecord.originalName` | Preserved as-is from filesystem (for display) |
| `InMemoryIndex.insert(_:)` | `name.precomposedStringWithCanonicalMapping` before indexing |
| `InMemoryIndex.search(query:)` | Normalize query string before lookup |
| `FullSubstringMap.insert/search` | Internal NFC normalization before lowercasing |
| `TrigramIndex.insert/search` | Internal NFC normalization before lowercasing |
| `PinyinIndex.insert/search` | Internal NFC normalization before pinyin tokenization |
| `FSEventWatcher` file event handlers | `fileName.precomposedStringWithCanonicalMapping` before inserting |

The pattern is consistent: **normalize early, normalize everywhere.** Every ingestion path and every query path normalizes. The normalization is idempotent (normalizing an already-NFC string is a no-op), so defensive re-normalization is safe.

**Why NFC (not NFD)?**

- `precomposedStringWithCanonicalMapping` produces NFC, which is the form users naturally type (composed characters are the default on most keyboard layouts).
- NFC strings are shorter (composed characters use fewer code points), reducing index memory footprint.
- Apple's Foundation consistently uses NFC for `String` comparisons, sorting, and hashing. Using NFC aligns with platform conventions.
- HFS+ enforced NFD, but APFS (the current macOS filesystem since High Sierra) is normalization-insensitive -- it preserves whatever form was written and does not enforce NFD. However, most file creation APIs still decompose names, so NFD is common on disk. Normalizing to NFC at ingestion is the standard approach.

**Why not normalization-insensitive comparison?**

Swift's `String` does not offer a built-in normalization-insensitive comparison (unlike ICU's `UNORM` or `.compare(_:options:)` with `.diacriticInsensitive`, which is broader and less precise). Pre-normalizing is simpler, faster (one normalization at insert time, not at every comparison), and deterministic.

## Consequences

**Positive:**

- **Correct search behavior.** Users always find files regardless of the Unicode normalization form used in the filename on disk. "café.pdf" and "café.pdf" are treated as identical.
- **Deterministic hashing.** Dictionary keys in FullSubstringMap, TrigramIndex posting lists, and PinyinIndex tries are always NFC, preventing duplicate entries from normalization variants.
- **Consistent with Apple platform.** `precomposedStringWithCanonicalMapping` is a Foundation primitive, not a third-party dependency.
- **Defense in depth.** Normalizing at every boundary (insert + search + FSEvent) means even if one path misses normalization, the other path catches it.

**Negative:**

- **Normalization can change string length.** An NFD string like "é" (2 code points, count=1 character) normalizes to "é" (1 code point, count=1 character). The `count` property (which counts characters, not code points) is unaffected, but any code that depends on `unicodeScalars.count` or `utf16.count` must be aware.
- **Idempotent normalization is still O(N) work.** Every insert and search call traverses the string for normalization, even if it's already NFC. In practice, this is negligible compared to substring index insertion cost.
- **Some edge cases remain.** Unicode normalization does not handle case folding, width variants (fullwidth vs halfwidth), or compatibility characters (e.g., "fi" ligature U+FB01 vs "f" + "i"). These are handled separately: case folding via `.lowercased()`, and width/compatibility variants are accepted as distinct (consistent with macOS Finder behavior).
- **Original name must be preserved.** `FileRecord` stores both `name` (NFC, for search) and `originalName` (as-read, for display). This doubles the string storage for filenames that are already in NFC (common case: ASCII names), where `name == originalName`. The `originalName` field exists only to handle the rare NFD-on-disk case.

**Alternatives considered and rejected:**

- **NFD normalization:** Would match HFS+ legacy behavior but produces longer strings and disagrees with user typing conventions. APFS does not enforce NFD, making it unnecessary.
- **NFKC (compatibility composition):** Would normalize "fi" ligature to "f"+"i" and fullwidth "A" to halfwidth "A". Overly aggressive -- users typing fullwidth characters expect them to be searchable as-is.
- **Normalize-at-compare-time only:** Store raw strings, normalize during search. Rejected because it requires normalization on every comparison (not just at insert) and complicates index structures that use strings as dictionary keys.

## Related

- [ADR-003](ADR-003-fullsubstringmap-64-char-threshold-trigram-fallback.md) — FullSubstringMap, TrigramIndex, and PinyinIndex all apply NFC normalization at insert/search time (see normalization table above)
- [ADR-006](ADR-006-fseventwatcher-actor-isolation-model.md) — FSEventWatcher normalizes filenames from filesystem events before inserting into InMemoryIndex
