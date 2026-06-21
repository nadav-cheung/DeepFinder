// CParallelScanner — GCD-based parallel file scanner for macOS
//
// Architecture inspired by rq (github.com/seeyebe/rq):
//   - Work-stealing across top-level directories via atomic counter
//   - Per-worker fts(3) subtree traversal (independent FTS handles)
//   - Batched CIndex insertion (lock once per batch, not per file)
//   - dispatch_apply for zero-boilerplate thread pool
//
// Key difference from rq: uses GCD dispatch_apply instead of custom Win32
// thread pool, and fts(3) bulk traversal instead of per-directory work items.
// fts is a better fit for macOS because it returns stat info in one syscall
// (getdirentriesattr under the hood), avoiding separate stat(2) per file.
#ifndef CPARALLELSCANNER_H
#define CPARALLELSCANNER_H

#include "CIndex.h"
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CParallelScanner CParallelScanner;

// Progress callback. Return false to cancel.
typedef bool (*cpscanner_progress_cb)(uint32_t files, uint32_t dirs,
                                       uint32_t skipped, void* user_data);
typedef void (*cpscanner_error_cb)(const char* path, const char* reason,
                                    void* user_data);

// ── Lifecycle ───────────────────────────────────────────

CParallelScanner* cpscanner_create(void);
void cpscanner_destroy(CParallelScanner* s);

// ── Configuration ───────────────────────────────────────

// Directory names to skip (e.g. ".git", "node_modules").
// `items` is a NULL-terminated array? No — count-based for Swift interop.
void cpscanner_set_skip_names(CParallelScanner* s, const char* const* names,
                              uint32_t count);
void cpscanner_set_skip_files(CParallelScanner* s, const char* const* files,
                              uint32_t count);
void cpscanner_set_skip_extensions(CParallelScanner* s, const char* const* exts,
                                   uint32_t count);
void cpscanner_set_skip_paths(CParallelScanner* s, const char* const* paths,
                              uint32_t count);
void cpscanner_set_max_depth(CParallelScanner* s, int max_depth);
void cpscanner_set_follow_symlinks(CParallelScanner* s, bool follow);

// ── Scan ─────────────────────────────────────────────────

// Scan root_path, inserting all files/dirs into idx.
// Returns total files scanned (excluding dirs and skipped).
// Thread-safe: uses idx->mutex for insertion.
uint32_t cpscanner_scan(CParallelScanner* s, CIndex* idx,
                        const char* root_path,
                        cpscanner_progress_cb progress_cb,
                        cpscanner_error_cb error_cb,
                        void* user_data);

#ifdef __cplusplus
}
#endif

#endif // CPARALLELSCANNER_H
