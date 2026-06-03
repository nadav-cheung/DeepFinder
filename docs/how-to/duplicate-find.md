# Find Duplicate Files

## You want to find and manage duplicate files

Duplicate files waste disk space and create confusion. DeepFinder can identify duplicates by name, size, content hash, or emptiness — letting you find redundant downloads, backup copies, and stale temp files.

### Find files with the same name

The `dupe:` modifier finds files that share the same name (regardless of location):

```bash
deepfinder "dupe:README.md"
# Returns all files named "README.md" — shows groups with 2+ copies
```

Name-based duplicate detection groups files by filename and reports groups with more than one member. This catches downloaded copies (`README.md` and `README (1).md` are NOT the same name), backup naming patterns, and identical filenames in different directories.

### Find files with the same size

The `sizedupe:` modifier finds files with identical sizes:

```bash
deepfinder "sizedupe:1024"
# Returns groups of files that are exactly 1024 bytes
```

Size-based grouping is fast — it only compares the `size` field in the index, which is always in memory. Use it as a first pass before running content-based deduplication, or to find files that are suspiciously the same size.

### Find exact content duplicates (hash-based)

The `hashdupe:` modifier uses SHA-256 hashing to find files with identical content:

```bash
deepfinder "hashdupe:*.jpg"
# Returns all .jpg files grouped by exact content match
```

This uses a **two-phase approach** for efficiency:
1. **Size grouping**: files are grouped by byte size (instant from the index).
2. **SHA-256 hashing**: within each size group, file contents are hashed. Only groups where at least two files produce the same hash are reported.

For large files, the hash is computed incrementally in 1MB chunks to avoid loading the entire file into memory.

### Find empty files

The `empty:` modifier finds zero-byte files:

```bash
deepfinder "empty:"
# Returns all files with size 0
```

Empty files are often stale lock files, truncated downloads, or placeholder files. Combine with path filters to scope the search:

```bash
deepfinder "empty: *.log"
# Empty .log files
```

### Example workflows

**Clean up duplicate downloads:**

```bash
# Find all duplicate files in ~/Downloads
deepfinder "dupe: ~/Downloads" --json | jq '.[] | select(.dupeCount > 2)'
```

**Find identical photos (by content, not filename):**

```bash
# Find exact duplicates among JPEG files
deepfinder "hashdupe:*.jpg"
# hashdupe confirms bit-for-bit identity — safe to delete extras
```

**Clean up empty temp files:**

```bash
# Find and review empty files
deepfinder "empty:" --0 | xargs -0 ls -la
# Delete after review
deepfinder "empty:" --0 | xargs -0 rm
```

**Find duplicate configurations:**

```bash
# Find duplicate .env or config files
deepfinder "dupe:.env"
# Check if you have multiple environment configs scattered across projects
```

### How duplicate detection works

| Modifier | Grouping Method | Speed | False Positives? |
|----------|----------------|-------|------------------|
| `dupe:` | Filename match | Instant (index lookup) | Yes — different files can share a name |
| `sizedupe:` | Byte size match | Instant (index field) | Yes — different files can have the same size |
| `hashdupe:` | SHA-256 content hash | I/O-bound (reads file contents) | No — hash collision probability is negligible |
| `empty:` | Size = 0 | Instant (index field) | No |

For the most reliable deduplication, use `hashdupe:` — it confirms bit-for-bit content identity. For quick scans, start with `sizedupe:` to find candidates, then verify with `hashdupe:` on the suspect groups.

### Performance considerations

- **Name-based (`dupe:`)**: instant. Compares indexed filenames in memory. No file I/O.
- **Size-based (`sizedupe:`)**: instant. Compares the `size` field in `FileRecord`. No file I/O.
- **Hash-based (`hashdupe:`)**: I/O-bound. Reads every file in the result set. On M4+ SSD (~5 GB/s read), hashing 10,000 files averaging 1 MB takes ~2 seconds. Hashing 10,000 files averaging 100 MB takes ~200 seconds.
- **Empty (`empty:`)**: instant. Filters on `size == 0`. No file I/O.

To speed up `hashdupe:`, narrow the scope with filename or path filters first:

```bash
# Fast: hash only Swift files
deepfinder "*.swift hashdupe:"

# Slow: hash all files on disk — avoid this
deepfinder "hashdupe:"
```

---

**Next steps:**

| You want to... | Read this |
|---------------|-----------|
| Find files by name or pattern | [Find Files](find-files.md) |
| Filter by file size, date, type | [Filter Results](filter-results.md) |
| Automate deduplication in scripts | [Scripting](scripting.md) |
| Understand index structures | [Index Design](../explanation/index-design.md) |
