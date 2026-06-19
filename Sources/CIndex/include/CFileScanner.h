// CFileScanner — Zero-allocation directory scanner using POSIX fts(3)
// Directly inserts into CIndex, bypassing Swift String/URL/FileRecord entirely.
#ifndef CFILESCANNER_H
#define CFILESCANNER_H

#include "CIndex.h"
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque scanner handle
typedef struct CFileScanner CFileScanner;

// Progress callback: called periodically with files_scanned count.
// Return false to cancel the scan.
typedef bool (*cscanner_progress_cb)(uint32_t files_scanned, uint32_t dirs_scanned, void* user_data);

// Error callback: called for permission errors and other non-fatal issues.
typedef void (*cscanner_error_cb)(const char* path, const char* reason, void* user_data);

// Create a scanner. Free with cscanner_destroy().
CFileScanner* cscanner_create(void);

// Destroy the scanner and free all memory.
void cscanner_destroy(CFileScanner* s);

// ── Configuration ───────────────────────────────────────

// Set directory names to skip (e.g., ".git", "node_modules").
// `names` is a NULL-terminated array of strings. Caller retains ownership.
void cscanner_set_skip_names(CFileScanner* s, const char* const* names, uint32_t count);

// Set file basenames to skip (e.g., ".DS_Store").
void cscanner_set_skip_files(CFileScanner* s, const char* const* files, uint32_t count);

// Set file extensions to skip (e.g., "o", "pyc").
void cscanner_set_skip_extensions(CFileScanner* s, const char* const* exts, uint32_t count);

// Set path suffixes to skip (e.g., "/Library/Caches"). When a path ends with
// one of these suffixes at a component boundary, it and its descendants are skipped.
void cscanner_set_skip_paths(CFileScanner* s, const char* const* paths, uint32_t count);

// Set maximum directory depth (0 = root only). Negative = no limit.
void cscanner_set_max_depth(CFileScanner* s, int max_depth);

// Set whether to follow symbolic links. Default: false.
void cscanner_set_follow_symlinks(CFileScanner* s, bool follow);

// ── Scan ─────────────────────────────────────────────────

// Scan a root path, inserting all found files/directories into `idx`.
// Calls `progress_cb` every 100 files; return false from it to cancel.
// Calls `error_cb` for non-fatal errors (permission denied, etc.).
// Returns the number of files scanned (excluding directories and skipped items).
// This function is synchronous and thread-safe (uses the index mutex).
uint32_t cscanner_scan(CFileScanner* s, CIndex* idx, const char* root_path,
                       cscanner_progress_cb progress_cb,
                       cscanner_error_cb error_cb,
                       void* user_data);

#ifdef __cplusplus
}
#endif

#endif // CFILESCANNER_H
