// CIndex implementation — compact, Everything-style
#include "include/CIndex.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>  // strcasecmp, strncasecmp
#include <ctype.h>

// ── Name entry in sorted array ──────────────────────────
typedef struct {
    char*    name;       // lowercased, NFC, null-terminated (owned)
    uint32_t record_id;
} NameSlot;

// ── File metadata ───────────────────────────────────────
typedef struct {
    char*    original_name;  // owned
    char*    path;           // owned
    char*    parent_path;    // owned
    int64_t  size;
    int64_t  created_at;
    int64_t  modified_at;
    uint32_t id;
    bool     is_directory;
} FileMeta;

// ── Path → record index hash entry ──────────────────────
typedef struct {
    char*    path;       // owned key
    uint32_t meta_idx;   // index into metas[] array
    bool     used;
} PathSlot;

// ── Main index struct ───────────────────────────────────
#define NAME_INIT_CAP   131072   // 128K
#define META_INIT_CAP   131072
#define PATH_HASH_CAP   262144   // power of 2
#define MAX_RESULTS     10000

struct CIndex {
    // Sorted name array
    NameSlot* names;
    uint32_t  name_count;
    uint32_t  name_cap;

    // Dense metadata array
    FileMeta* metas;
    uint32_t  meta_count;
    uint32_t  meta_cap;

    // Path → meta index hash
    PathSlot* path_hash;
    uint32_t  path_hash_mask;  // capacity - 1

    // Directory entries count (for fast count)
    uint32_t  file_count;

    // Auto-increment ID
    uint32_t  next_id;
};

// ── Helpers ─────────────────────────────────────────────

static char* strdup_lower(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char*  out = (char*)malloc(len + 1);
    if (!out) return NULL;
    for (size_t i = 0; i < len; i++) {
        out[i] = (char)tolower((unsigned char)s[i]);
    }
    out[len] = '\0';
    return out;
}

static bool str_has_prefix(const char* str, const char* prefix) {
    size_t slen = strlen(str);
    size_t plen = strlen(prefix);
    if (plen > slen) return false;
    return strncasecmp(str, prefix, plen) == 0;
}

static bool str_contains(const char* haystack, const char* needle) {
    // Simple strstr with case-insensitive
    if (!*needle) return true;
    size_t nlen = strlen(needle);
    size_t hlen = strlen(haystack);
    if (nlen > hlen) return false;
    for (size_t i = 0; i <= hlen - nlen; i++) {
        if (strncasecmp(haystack + i, needle, nlen) == 0) return true;
    }
    return false;
}

// FNV-1a hash for paths
static uint32_t path_hash_fn(const char* s) {
    uint32_t h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s; h *= 16777619u; s++; }
    return h;
}

// ── Create / Destroy ────────────────────────────────────

CIndex* cindex_create(void) {
    CIndex* idx = (CIndex*)calloc(1, sizeof(CIndex));
    if (!idx) return NULL;

    idx->name_cap = NAME_INIT_CAP;
    idx->names = (NameSlot*)calloc(idx->name_cap, sizeof(NameSlot));

    idx->meta_cap = META_INIT_CAP;
    idx->metas = (FileMeta*)calloc(idx->meta_cap, sizeof(FileMeta));

    idx->path_hash_mask = PATH_HASH_CAP - 1;
    idx->path_hash = (PathSlot*)calloc(PATH_HASH_CAP, sizeof(PathSlot));

    idx->next_id = 1;
    return idx;
}

void cindex_destroy(CIndex* idx) {
    if (!idx) return;
    for (uint32_t i = 0; i < idx->name_count; i++) free(idx->names[i].name);
    for (uint32_t i = 0; i < idx->meta_count; i++) {
        free(idx->metas[i].original_name);
        free(idx->metas[i].path);
        free(idx->metas[i].parent_path);
    }
    for (uint32_t i = 0; i <= idx->path_hash_mask; i++) {
        free(idx->path_hash[i].path);
    }
    free(idx->names);
    free(idx->metas);
    free(idx->path_hash);
    free(idx);
}

// ── Path hash table ─────────────────────────────────────

// Returns meta_idx or UINT32_MAX if not found
static uint32_t path_lookup(CIndex* idx, const char* path) {
    uint32_t h = path_hash_fn(path) & idx->path_hash_mask;
    uint32_t original = h;
    do {
        PathSlot* slot = &idx->path_hash[h];
        if (!slot->used) return UINT32_MAX;
        if (strcmp(slot->path, path) == 0) return slot->meta_idx;
        h = (h + 1) & idx->path_hash_mask;
    } while (h != original);
    return UINT32_MAX;
}

static void path_insert(CIndex* idx, const char* path, uint32_t meta_idx) {
    // Resize if needed (load factor > 0.5)
    uint32_t used = 0;
    for (uint32_t i = 0; i <= idx->path_hash_mask; i++) {
        if (idx->path_hash[i].used) used++;
    }
    if (used > (idx->path_hash_mask + 1) / 2) {
        // Double the hash table (not implemented for simplicity — will degrade on huge indexes)
    }

    uint32_t h = path_hash_fn(path) & idx->path_hash_mask;
    while (idx->path_hash[h].used) {
        // Update existing entry for this path
        if (strcmp(idx->path_hash[h].path, path) == 0) {
            idx->path_hash[h].meta_idx = meta_idx;
            return;
        }
        h = (h + 1) & idx->path_hash_mask;
    }
    idx->path_hash[h].path = strdup(path);
    idx->path_hash[h].meta_idx = meta_idx;
    idx->path_hash[h].used = true;
}

static void path_remove(CIndex* idx, const char* path) {
    uint32_t h = path_hash_fn(path) & idx->path_hash_mask;
    uint32_t original = h;
    do {
        PathSlot* slot = &idx->path_hash[h];
        if (!slot->used) return;
        if (strcmp(slot->path, path) == 0) {
            free(slot->path);
            slot->path = NULL;
            slot->used = false;
            return;
        }
        h = (h + 1) & idx->path_hash_mask;
    } while (h != original);
}

// ── Sorted name array ───────────────────────────────────

// Binary search: find first index where names[i] >= name
static uint32_t name_lower_bound(CIndex* idx, const char* name) {
    uint32_t lo = 0, hi = idx->name_count;
    while (lo < hi) {
        uint32_t mid = (lo + hi) / 2;
        if (strcmp(idx->names[mid].name, name) < 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

static void name_insert_at(CIndex* idx, uint32_t pos, const char* name, uint32_t id) {
    if (idx->name_count >= idx->name_cap) {
        idx->name_cap *= 2;
        idx->names = (NameSlot*)realloc(idx->names, idx->name_cap * sizeof(NameSlot));
    }
    // Shift right
    memmove(&idx->names[pos + 1], &idx->names[pos],
            (idx->name_count - pos) * sizeof(NameSlot));
    idx->names[pos].name = strdup(name);
    idx->names[pos].record_id = id;
    idx->name_count++;
}

static void name_remove(CIndex* idx, const char* name, uint32_t id) {
    uint32_t pos = name_lower_bound(idx, name);
    while (pos < idx->name_count && strcmp(idx->names[pos].name, name) == 0) {
        if (idx->names[pos].record_id == id) {
            free(idx->names[pos].name);
            // Shift left
            if (pos < idx->name_count - 1) {
                memmove(&idx->names[pos], &idx->names[pos + 1],
                        (idx->name_count - pos - 1) * sizeof(NameSlot));
            }
            idx->name_count--;
            return;
        }
        pos++;
    }
}

// ── Insert ──────────────────────────────────────────────

uint32_t cindex_insert(CIndex* idx,
                       const char* name,
                       const char* original_name,
                       const char* path,
                       const char* parent_path,
                       bool is_directory,
                       int64_t size,
                       int64_t created_at,
                       int64_t modified_at)
{
    if (!idx || !name || !path) return 0;

    // Check for existing path (upsert)
    uint32_t existing = path_lookup(idx, path);
    if (existing != UINT32_MAX) {
        FileMeta* m = &idx->metas[existing];
        // Remove old name entry
        char* old_lower = strdup_lower(m->original_name);
        if (old_lower) {
            name_remove(idx, old_lower, m->id);
            free(old_lower);
        }
        free(m->original_name);
        free(m->path);
        free(m->parent_path);

        // Update metadata
        m->original_name = strdup(original_name ? original_name : "");
        m->path = strdup(path);
        m->parent_path = strdup(parent_path ? parent_path : "");
        m->size = size;
        m->created_at = created_at;
        m->modified_at = modified_at;
        m->is_directory = is_directory;

        // Re-insert name
        char* lower = strdup_lower(name);
        uint32_t pos = name_lower_bound(idx, lower);
        name_insert_at(idx, pos, lower, m->id);
        free(lower);
        return m->id;
    }

    // Expand metas if needed
    if (idx->meta_count >= idx->meta_cap) {
        idx->meta_cap *= 2;
        idx->metas = (FileMeta*)realloc(idx->metas, idx->meta_cap * sizeof(FileMeta));
    }

    uint32_t meta_idx = idx->meta_count++;
    uint32_t id = idx->next_id++;

    FileMeta* m = &idx->metas[meta_idx];
    m->id = id;
    m->original_name = strdup(original_name ? original_name : "");
    m->path = strdup(path);
    m->parent_path = strdup(parent_path ? parent_path : "");
    m->size = size;
    m->created_at = created_at;
    m->modified_at = modified_at;
    m->is_directory = is_directory;

    if (!is_directory) idx->file_count++;

    // Insert into path hash
    path_insert(idx, path, meta_idx);

    // Insert into sorted names
    char* lower = strdup_lower(name);
    uint32_t pos = name_lower_bound(idx, lower);
    name_insert_at(idx, pos, lower, id);
    free(lower);

    return id;
}

// ── Remove ──────────────────────────────────────────────

bool cindex_remove(CIndex* idx, uint32_t id) {
    if (!idx) return false;
    // Find meta by ID (linear scan — for dense IDs this is fast enough)
    for (uint32_t i = 0; i < idx->meta_count; i++) {
        if (idx->metas[i].id == id) {
            FileMeta* m = &idx->metas[i];

            // Remove from names
            char* lower = strdup_lower(m->original_name);
            if (lower) {
                name_remove(idx, lower, id);
                free(lower);
            }

            // Remove from path hash
            path_remove(idx, m->path);

            // Free strings
            free(m->original_name);
            free(m->path);
            free(m->parent_path);

            // Compact metas array (swap with last)
            if (i < idx->meta_count - 1) {
                idx->metas[i] = idx->metas[idx->meta_count - 1];
                // Update path hash for the swapped entry
                path_insert(idx, idx->metas[i].path, i);
            }
            idx->meta_count--;
            if (!m->is_directory) idx->file_count--;
            return true;
        }
    }
    return false;
}

bool cindex_remove_by_path(CIndex* idx, const char* path) {
    if (!idx || !path) return false;
    uint32_t meta_idx = path_lookup(idx, path);
    if (meta_idx == UINT32_MAX) return false;
    return cindex_remove(idx, idx->metas[meta_idx].id);
}

// ── Query ───────────────────────────────────────────────

uint32_t cindex_count(const CIndex* idx) {
    return idx ? idx->file_count : 0;
}

uint32_t cindex_search_prefix(const CIndex* idx, const char* prefix,
                              uint32_t** out_ids, uint32_t max_results) {
    if (!idx || !prefix || !out_ids) return 0;
    if (!*prefix) return 0;

    if (max_results == 0) max_results = MAX_RESULTS;

    char* lower = strdup_lower(prefix);
    uint32_t pos = name_lower_bound(idx, lower);

    // Count matches first
    uint32_t count = 0;
    uint32_t i = pos;
    while (i < idx->name_count && str_has_prefix(idx->names[i].name, lower)) {
        count++;
        i++;
        if (max_results > 0 && count >= max_results) break;
    }

    if (count == 0) {
        free(lower);
        *out_ids = NULL;
        return 0;
    }

    *out_ids = (uint32_t*)malloc(count * sizeof(uint32_t));
    i = pos;
    uint32_t j = 0;
    while (i < idx->name_count && str_has_prefix(idx->names[i].name, lower)) {
        (*out_ids)[j++] = idx->names[i].record_id;
        i++;
        if (max_results > 0 && j >= max_results) break;
    }

    free(lower);
    return count;
}

uint32_t cindex_search_substring(const CIndex* idx, const char* substring,
                                 uint32_t** out_ids, uint32_t max_results) {
    if (!idx || !substring || !out_ids) return 0;
    if (!*substring) return 0;

    if (max_results == 0) max_results = MAX_RESULTS;

    char* lower = strdup_lower(substring);

    // First pass: count matches
    uint32_t count = 0;
    for (uint32_t i = 0; i < idx->name_count; i++) {
        if (str_contains(idx->names[i].name, lower)) {
            count++;
            if (max_results > 0 && count >= max_results) break;
        }
    }

    if (count == 0) {
        free(lower);
        *out_ids = NULL;
        return 0;
    }

    *out_ids = (uint32_t*)malloc(count * sizeof(uint32_t));
    uint32_t j = 0;
    for (uint32_t i = 0; i < idx->name_count && j < count; i++) {
        if (str_contains(idx->names[i].name, lower)) {
            (*out_ids)[j++] = idx->names[i].record_id;
        }
    }

    free(lower);
    return count;
}

// ── Metadata accessors ──────────────────────────────────

static FileMeta* find_meta_by_id(CIndex* idx, uint32_t id) {
    for (uint32_t i = 0; i < idx->meta_count; i++) {
        if (idx->metas[i].id == id) return &idx->metas[i];
    }
    return NULL;
}

const char* cindex_get_name(const CIndex* idx, uint32_t id) {
    // Return original_name (display name)
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->original_name : NULL;
}

const char* cindex_get_original_name(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->original_name : NULL;
}

const char* cindex_get_path(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->path : NULL;
}

const char* cindex_get_parent_path(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->parent_path : NULL;
}

bool cindex_is_directory(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->is_directory : false;
}

int64_t cindex_get_size(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->size : 0;
}

int64_t cindex_get_created_at(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->created_at : 0;
}

int64_t cindex_get_modified_at(const CIndex* idx, uint32_t id) {
    FileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->modified_at : 0;
}
