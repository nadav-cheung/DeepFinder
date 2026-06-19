# libdfindex -- DeepFinder C Index Core

A standalone, pure-C (C17) macOS file indexer and search engine. The core data
structures powering [DeepFinder](https://github.com/nadaviv/DeepFinder), an
Everything-style instant file search for macOS. MIT-licensed, zero
dependencies beyond libSystem.

## What It Is

libdfindex provides three integrated layers:

| Layer | API | What it does |
|-------|-----|--------------|
| **CIndex** | `cindex_*` | Everything-style sorted-array prefix search. Dense `NameSlot[]` sorted by lowercased filename, binary-searched for O(log n) prefix matching. Inverted trigram index (byte-level, CJK-native) for O(1)-ish substring search. Dense metadata array with FNV-1a path hash for O(1) upsert/removal. Thread-safe via pthread mutex. |
| **CFileScanner** | `cscanner_*` | Single-threaded directory scanner using POSIX `fts(3)`. Zero Swift/Objective-C allocation -- writes directly into a `CIndex`. Configurable skip lists (names, files, extensions, path suffixes), depth limit, symlink policy. |
| **CParallelScanner** | `cpscanner_*` | GCD-based parallel scanner. Architecture inspired by [rq](https://github.com/seeyebe/rq): top-level subtree partitioning with per-worker `fts(3)` handles, work-stealing via GCD `dispatch_apply`, batched `cindex_insert` to amortize mutex contention. Same configuration surface as CFileScanner, plus worker count and batch size. |
| **CTrigramIndex** | `ctrigram_*` | Standalone byte-level trigram inverted index. Flat posting lists with binary-searched `PostingBlock` index; lazy pending buffer flushed via sort+merge. Two-pointer intersection from the shortest posting list, then `strncasecmp` verification against an arena of lowercased names. CJK-friendly (bytes >= 0x80 preserved as-is). |

### Data Structures

- **Sorted Name Array** (`NameSlot[]`): binary search over lowercased filenames. O(log n) prefix lookup, O(k) result scan.
- **Trigram Inverted Index**: byte-level trigrams over lowercased names. For queries >= 3 bytes: trigram intersection + arena verification. For queries < 3 bytes: linear arena scan. Handles names up to 255 bytes.
- **Path Hash Table**: FNV-1a hash, open addressing, linear probing. O(1) path-to-record lookups for upsert/removal.
- **Dense Metadata Array** (`FileMeta[]`): all file metadata (path, parent, size, timestamps) in a contiguously allocated array indexed by meta index.

### Concurrency Model

- `CIndex`: single `pthread_mutex_t` protecting all read/write paths. All public functions are thread-safe.
- `CParallelScanner`: per-worker `fts(3)` handles (lock-free traversal), atomic progress counters, batched `cindex_insert` calls (mutex held once per batch, not per file).
- `CTrigramIndex`: its own `pthread_mutex_t`, acquired inside CIndex's lock (acyclic lock order -- trigram never calls back into CIndex).

## Public C API

### CIndex

```c
CIndex*   cindex_create(void);
void      cindex_destroy(CIndex* idx);

// Insert/update a file. Returns auto-assigned record ID.
uint32_t  cindex_insert(CIndex* idx, const char* name,
                        const char* original_name, const char* path,
                        const char* parent_path, bool is_directory,
                        int64_t size, int64_t created_at, int64_t modified_at);

bool      cindex_remove(CIndex* idx, uint32_t id);
bool      cindex_remove_by_path(CIndex* idx, const char* path);

uint32_t  cindex_count(const CIndex* idx);          // non-directory files
uint32_t  cindex_total_records(const CIndex* idx);  // files + directories
uint32_t  cindex_next_id(const CIndex* idx);

// Search. Caller frees *out_ids with free().
uint32_t  cindex_search_prefix(const CIndex* idx, const char* prefix,
                               uint32_t** out_ids, uint32_t max_results);
uint32_t  cindex_search_substring(const CIndex* idx, const char* substring,
                                  uint32_t** out_ids, uint32_t max_results);

// Iteration and per-record access.
uint32_t  cindex_iterate(const CIndex* idx, cindex_iterate_cb cb, void* user_data);

CRecordCopy  cindex_copy_record(const CIndex* idx, uint32_t id);
void         cindex_free_record_copy(CRecordCopy* r);

const char*  cindex_get_path(const CIndex* idx, uint32_t id);
const char*  cindex_get_name(const CIndex* idx, uint32_t id);
// ... plus get_original_name, get_parent_path, is_directory,
//     get_size, get_created_at, get_modified_at
```

### CParallelScanner

```c
CParallelScanner*  cpscanner_create(void);
void               cpscanner_destroy(CParallelScanner* s);

void  cpscanner_set_skip_names(CParallelScanner* s, const char* const* names, uint32_t count);
void  cpscanner_set_skip_files(CParallelScanner* s, const char* const* files, uint32_t count);
void  cpscanner_set_skip_extensions(CParallelScanner* s, const char* const* exts, uint32_t count);
void  cpscanner_set_skip_paths(CParallelScanner* s, const char* const* paths, uint32_t count);
void  cpscanner_set_max_depth(CParallelScanner* s, int max_depth);
void  cpscanner_set_follow_symlinks(CParallelScanner* s, bool follow);
void  cpscanner_set_worker_count(CParallelScanner* s, uint32_t count);
void  cpscanner_set_batch_size(CParallelScanner* s, uint32_t size);

uint32_t  cpscanner_scan(CParallelScanner* s, CIndex* idx,
                         const char* root_path,
                         cpscanner_progress_cb progress_cb,
                         cpscanner_error_cb error_cb,
                         void* user_data);
```

### CTrigramIndex (standalone)

```c
CTrigramIndex*  ctrigram_create(void);
void            ctrigram_destroy(CTrigramIndex* ti);

void        ctrigram_insert(CTrigramIndex* ti, const char* name, uint32_t id);
bool        ctrigram_remove(CTrigramIndex* ti, uint32_t id);
uint32_t    ctrigram_search(CTrigramIndex* ti, const char* query,
                            uint32_t** out_ids, uint32_t max_results);
const char* ctrigram_name(CTrigramIndex* ti, uint32_t id);
uint32_t    ctrigram_doc_count(const CTrigramIndex* ti);
void        ctrigram_flush(CTrigramIndex* ti);
```

## Standalone Build

```bash
cd Sources/CIndex
make          # builds libdfindex.a + dfdemo
make lib      # just libdfindex.a
make demo     # just dfdemo
make clean    # remove build artifacts
```

The Makefile produces:
- `libdfindex.a` -- static library (CIndex + CFileScanner + CParallelScanner + CTrigramIndex)
- `dfdemo` -- standalone demo: scans a directory, then substring-searches it

## Demo

```bash
./dfdemo ~/Documents "report"
# Scans ~/Documents (skipping .git, node_modules, .DS_Store)
# Prints all paths containing "report" (case-insensitive)
```

## Benchmarks

Measured on an Apple M4 Max (16-core), macOS 26, 160K indexed files.

| Metric | Single-threaded | Parallel (GCD) | Notes |
|--------|----------------|----------------|-------|
| Full scan (160K files) | ~8 s | ~4 s | Subtree partitioning via GCD `dispatch_apply` |
| SQLite reload + trigram rebuild | — | <1 s | In-memory index rebuild from persisted DB |

Substring query latency (via `deepfinder` CLI, includes binary launch + IPC round-trip):

| Query | Type | Total CLI | In-memory (est.) | Results |
|-------|------|-----------|-------------------|---------|
| `"readme"` | prefix (NameSlot) | ~350 ms | <10 μs | binary search O(log n) |
| `"adme"` | substring (trigram) | ~350 ms | <100 μs | 3 trigrams → merge-join + verify |
| `"楠"` | CJK trigram (3 bytes) | ~350 ms | <100 μs | byte-level: UTF-8 trigram = native |
| `"config"` | substring (trigram) | ~350 ms | <100 μs | 6 trigrams → merge-join + verify |

*CLI total includes ~300 ms Swift binary launch + ~50 ms IPC round-trip. In-memory search latency is sub-millisecond for all query types. Trigrams match prefix search speed because the trigram block binary search is O(log 32K blocks) ≈ 15 steps, and posting lists for filenames are short. CJK queries work natively via byte-level trigrams over UTF-8 — PinyinIndex removed.*

Memory (160K files):

| Component | Size | Notes |
|-----------|------|-------|
| CIndex core (NameSlot + FileMeta + PathSlot) | ~18 MB | Everything-style sorted arrays |
| Trigram arena (lowercased names) | ~5 MB | 160K × ~30 bytes/name |
| Trigram postings | ~6 MB | flat uint32_t, no compression |
| Trigram blocks | <1 MB | 32K unique trigrams × 12 bytes |
| **Total RSS** | **~30 MB** | matches design target |

## Requirements

- **macOS 26+ (Tahoe)**, Apple Silicon (arm64)
- Xcode 16+ or Command Line Tools (for `cc`, `ar`)
- **Full Disk Access** (System Settings > Privacy & Security) if scanning protected directories (`~/Documents`, `~/Desktop`, `~/Downloads`)

## Architecture Credits

- **rq** ([github.com/seeyebe/rq](https://github.com/seeyebe/rq)) -- inspired the subtree-partitioning parallel walk strategy. CParallelScanner adapts the work-stealing concept to macOS via GCD `dispatch_apply` instead of a custom Win32 thread pool, and uses `fts(3)` bulk traversal instead of per-directory work items.
- **xgrep / lattice trigram index** -- inspired the byte-level trigram inverted index design: flat posting lists, binary-searched block index, lazy sort+merge flush, and two-pointer intersection with arena-side verification.

## License

MIT -- see [LICENSE](LICENSE).
