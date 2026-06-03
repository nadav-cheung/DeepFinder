# Search Inside Files (Content Search)

## You want to find files by their contents, not just their names

Content search looks inside files to find text matches. Use it to locate that script that calls a specific function, find notes mentioning a particular topic, or track down configuration files containing a specific setting.

### Basic content search

Use the `content:` query modifier followed by your search term:

```bash
deepfinder "content:TODO"
# Returns files containing the text "TODO"
```

The search is case-insensitive by default. `content:error` matches `Error`, `ERROR`, and `error`.

### Combine with filename search

Narrow results by combining content and filename filters:

```bash
deepfinder "*.swift content:deepfinder"
# Swift files containing "deepfinder"

deepfinder "*.md content:API"
# Markdown files mentioning "API"
```

### Supported file types and encodings

Content search supports these text encodings with automatic detection via BOM (Byte Order Mark):

| Encoding | BOM | Common In |
|----------|-----|-----------|
| UTF-8 | EF BB BF (optional) | Source code, config files, Markdown, JSON, YAML, logs |
| UTF-16 LE | FF FE | Windows text files, some XML, registry exports |
| UTF-16 BE | FE FF | Legacy Mac OS files, some Java .class files |

Files without a BOM are treated as UTF-8 by default. Binary files are skipped automatically — content search checks for null bytes and control characters to avoid false matches in compiled code, images, and archives.

### What gets searched

- **Plain text files**: `.txt`, `.md`, `.csv`, `.log`, `.json`, `.xml`, `.yaml`, `.toml`
- **Source code**: `.swift`, `.c`, `.h`, `.py`, `.js`, `.ts`, `.rs`, `.go`, `.java`, `.sh`, and more
- **Configuration files**: `.plist`, `.ini`, `.cfg`, `.conf`, `.env`
- **Scripts**: any file with a shebang (`#!/bin/sh`, `#!/usr/bin/env python3`, etc.)

Content search does **not** search: compiled binaries, images, video, audio, PDFs, `.docx`, `.xlsx`, application bundles, or package contents.

### File size limit

Files larger than **64 MB** are skipped. Content search is designed for text files — large log files, database dumps, and other exceptionally large files are better searched with dedicated tools (`grep`, `rg`, `less`).

### Line-level matching

Results show the matching line and line number where the text was found:

```bash
deepfinder "content:TODO" --json
```

```json
{
  "path": "/Users/nadav/Projects/DeepFinder/Sources/Daemon/DaemonMain.swift",
  "matches": [
    {"line": 42, "text": "    // TODO: handle SIGTERM for graceful shutdown"},
    {"line": 156, "text": "        // TODO: add index rebuild on corruption detection"}
  ]
}
```

### Performance

Content search runs **8 concurrent streams** across files, using Grand Central Dispatch for parallelism. On Apple Silicon (M4+), typical throughput is:

| File Count | Total Size | Scan Time |
|-----------|-----------|-----------|
| 100 files | ~10 MB | < 100 ms |
| 1,000 files | ~100 MB | < 1 second |
| 10,000 files | ~1 GB | 5-15 seconds |

Content search is slower than filename search (which is sub-millisecond). For the fastest experience, narrow results with filename filters first, then apply content search.

### Limitations

- **No regex in content**: content search matches literal text only. For regex searches, pipe results to `grep`: `deepfinder "*.swift" --0 | xargs -0 grep -l "pattern"`
- **No binary search**: compiled code, images, and archives are skipped. Use `strings` or specialized tools for binary analysis.
- **No PDF/content extraction**: content search checks raw bytes. PDF text extraction requires the Media metadata module (see [Filter Results](filter-results.md) for `pdf:text:`).
- **64MB cap**: files above this size are silently skipped. If you need to search very large files, use `grep` directly.
- **Concurrent stream limit**: the 8-stream parallelism is optimal for M4+ SSD I/O bandwidth. Adding more streams does not improve throughput.

---

**Next steps:**

| You want to... | Read this |
|---------------|-----------|
| Learn advanced query syntax | [Exact Search](exact-search.md) |
| Filter by file properties | [Filter Results](filter-results.md) |
| Understand the query parser | [Search Syntax Reference](../reference/search-syntax.md) |
| Automate search in scripts | [Scripting](scripting.md) |
