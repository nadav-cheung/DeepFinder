// CIndex — Compact file index in C (Everything-style)
// Zero overhead: no ARC, no Swift String, dense arrays.
// 200K files target: ~30MB.
#ifndef CINDEX_H
#define CINDEX_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque index handle
typedef struct CIndex CIndex;

// Create an empty index. Free with cindex_destroy().
CIndex* cindex_create(void);

// Create an empty index with a custom initial path-hash capacity (rounded up
// to a power of two, minimum 16). Primarily for testing resize logic at small
// scale; production should use cindex_create().
CIndex* cindex_create_with_path_cap(uint32_t path_cap);

// Destroy the index and free all memory.
void cindex_destroy(CIndex* idx);

// Insert or update a file. Returns the record ID (auto-assigned on first insert).
// `name` is the NFC-normalized filename (used for search).
// `original_name` is the display name.
// Re-inserting the same `path` updates the existing record (upsert).
uint32_t cindex_insert(CIndex* idx,
                       const char* name,
                       const char* original_name,
                       const char* path,
                       const char* parent_path,
                       bool is_directory,
                       int64_t size,
                       int64_t created_at,
                       int64_t modified_at);

// Remove a file by ID. Returns true if found.
bool cindex_remove(CIndex* idx, uint32_t id);

// Remove a file by path. Returns true if found.
bool cindex_remove_by_path(CIndex* idx, const char* path);

// Number of indexed files (non-directories only).
uint32_t cindex_count(const CIndex* idx);

// Total number of records (files + directories).
uint32_t cindex_total_records(const CIndex* idx);

// Prefix search: find all IDs whose name starts with `prefix` (case-insensitive).
// Returns the number of matches. `out_ids` receives the matching IDs (caller frees with free()).
// Pass `max_results` to limit; 0 = unlimited.
uint32_t cindex_search_prefix(const CIndex* idx, const char* prefix,
                              uint32_t** out_ids, uint32_t max_results);

// Substring search: find all IDs whose name contains `substring` (case-insensitive).
uint32_t cindex_search_substring(const CIndex* idx, const char* substring,
                                 uint32_t** out_ids, uint32_t max_results);

// Iterate all records. Calls `cb` for each record with the record's fields.
// `user_data` is passed through to the callback. Returns the number of records iterated.
// The pointers passed to the callback are valid only for the duration of the callback.
typedef void (*cindex_iterate_cb)(
    uint32_t id, const char* name, const char* original_name,
    const char* path, const char* parent_path,
    bool is_directory, int64_t size, int64_t created_at, int64_t modified_at,
    void* user_data
);
uint32_t cindex_iterate(const CIndex* idx, cindex_iterate_cb cb, void* user_data);

// Get a file's metadata by ID. Returns NULL if not found.
// The returned pointer is valid until the next insert/remove.
const char* cindex_get_original_name(const CIndex* idx, uint32_t id);
const char* cindex_get_path(const CIndex* idx, uint32_t id);
const char* cindex_get_parent_path(const CIndex* idx, uint32_t id);
bool        cindex_is_directory(const CIndex* idx, uint32_t id);
int64_t     cindex_get_size(const CIndex* idx, uint32_t id);
int64_t     cindex_get_created_at(const CIndex* idx, uint32_t id);
int64_t     cindex_get_modified_at(const CIndex* idx, uint32_t id);

#ifdef __cplusplus
}
#endif

// Sub-modules (included after CIndex type definitions)
#include "CParallelScanner.h"

#endif // CINDEX_H
