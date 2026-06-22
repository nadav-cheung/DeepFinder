// CTrigramIndex — Standalone trigram inverted index in C (Everything-style).
// Byte-level trigrams over lowercased names => CJK-native (no PinyinIndex needed).
// Flat posting lists with binary-searched PostingBlock index; lazy pending buffer
// flushed via sort+merge. Two-pointer intersection from the shortest posting list,
// then strncasecmp verification against the caller's lowercased names (the index
// stores non-owning pointers — it does not copy name bytes).
//
// SPDX-License-Identifier: MIT
#ifndef CTRIGRAMINDEX_H
#define CTRIGRAMINDEX_H

#include "CIndex.h"   // pulls in <stdint.h>, <stdbool.h>, <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque trigram index handle.
typedef struct CTrigramIndex CTrigramIndex;

// Create an empty trigram index. Free with ctrigram_destroy().
CTrigramIndex* ctrigram_create(void);

// Destroy the index and free all memory. NULL-safe.
void ctrigram_destroy(CTrigramIndex* ti);

// Insert (or re-insert) a name. `id` is opaque and returned verbatim by search.
// Re-inserting the same id updates the stored name. Thread-safe.
//
// CONTRACT: `name` must be ALREADY LOWERCASED by the caller and STABLE for the
// lifetime of the index. The trigram index stores a NON-OWNING pointer to `name`
// (it does not copy it) — the caller owns the bytes and must keep them alive
// (e.g. in a DFileMeta.data lower_name slot) for as long as this id is indexed.
void ctrigram_insert(CTrigramIndex* ti, const char* name, uint32_t id);

// Tombstone the record with the given id. The stored non-owning name pointer is
// cleared (NOT freed — the caller still owns it). Returns true if the id was
// present. Thread-safe.
bool ctrigram_remove(CTrigramIndex* ti, uint32_t id);

// Search for ids whose stored name contains `query` (case-insensitive).
// For queries of length >= 3, trigram intersection + name verification is used.
// For shorter queries, the names are linearly scanned.
// On success, writes a malloc'd array of matching ids into *out_ids (caller free()s)
// and returns its length. max_results == 0 means unlimited. Thread-safe.
uint32_t ctrigram_search(CTrigramIndex* ti, const char* query,
                         uint32_t** out_ids, uint32_t max_results);

// Number of documents currently indexed.
uint32_t ctrigram_doc_count(const CTrigramIndex* ti);

#ifdef __cplusplus
}
#endif

#endif // CTRIGRAMINDEX_H
