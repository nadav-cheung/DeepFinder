// CIndex implementation — compact, Everything-style
#include "CIndex.h"
#include "CTrigramIndex.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>  // strcasecmp, strncasecmp
#include <ctype.h>
#include <pthread.h>

// ── Single-allocation entry ─────────────────────────────
// All per-record strings are inlined in data[] so each record is exactly ONE
// calloc (was: 5 mallocs across FileMeta/NameSlot/PathSlot).
// data[] layout: [name\0][lower_name\0][path\0][parent_path\0]
//   name       = original-case display name (NFC)
//   lower_name = lowercased name, for the sorted prefix array
//   path       = full path (the single copy — path hash points here too)
//   parent_path= full parent path
typedef struct {
    uint32_t id;
    uint32_t name_len;       // bytes of name (excl. NUL)
    uint32_t lower_len;      // bytes of lower_name (excl. NUL)
    uint32_t path_len;       // bytes of path (excl. NUL); parent is the remainder
    int64_t  size;
    int64_t  created_at;
    int64_t  modified_at;
    uint8_t  is_directory;
    char     data[];
} DFileMeta;

static inline const char* dmeta_name(const DFileMeta* m)   { return m->data; }
static inline const char* dmeta_lower(const DFileMeta* m)  { return m->data + m->name_len + 1; }
static inline const char* dmeta_path(const DFileMeta* m)   {
    return m->data + m->name_len + 1 + m->lower_len + 1;
}
static inline const char* dmeta_parent(const DFileMeta* m) {
    return dmeta_path(m) + m->path_len + 1;
}

// One calloc; returns NULL on bad input / OOM. Treats NULL strings as empty.
static DFileMeta* dmeta_create(uint32_t id, const char* name, const char* lower_name,
                               const char* path, const char* parent_path,
                               bool is_directory, int64_t size,
                               int64_t created_at, int64_t modified_at) {
    if (!name)        name        = "";
    if (!lower_name)  lower_name  = "";
    if (!path)        path        = "";
    if (!parent_path) parent_path = "";

    uint32_t name_len   = (uint32_t)strlen(name);
    uint32_t lower_len  = (uint32_t)strlen(lower_name);
    uint32_t path_len   = (uint32_t)strlen(path);
    uint32_t parent_len = (uint32_t)strlen(parent_path);

    size_t total = sizeof(DFileMeta)
                 + (size_t)name_len + 1
                 + (size_t)lower_len + 1
                 + (size_t)path_len + 1
                 + (size_t)parent_len + 1;
    DFileMeta* m = (DFileMeta*)calloc(1, total);
    if (!m) return NULL;

    m->id          = id;
    m->name_len    = name_len;
    m->lower_len   = lower_len;
    m->path_len    = path_len;
    m->size        = size;
    m->created_at  = created_at;
    m->modified_at = modified_at;
    m->is_directory = is_directory ? 1 : 0;

    char* p = m->data;
    memcpy(p, name, name_len);        p[name_len] = '\0';   p += name_len + 1;
    memcpy(p, lower_name, lower_len); p[lower_len] = '\0';  p += lower_len + 1;
    memcpy(p, path, path_len);        p[path_len] = '\0';   p += path_len + 1;
    memcpy(p, parent_path, parent_len); p[parent_len] = '\0';
    return m;
}

// ── Name entry in sorted array ──────────────────────────
// name is NON-OWNING: it points into a DFileMeta.data lower_name.
typedef struct {
    const char* name;
    uint32_t    record_id;
} NameSlot;

// ── Path → record index hash entry ──────────────────────
// path is NON-OWNING: it points into a DFileMeta.data path.
typedef struct {
    const char* path;
    uint32_t    meta_idx;   // index into metas[] array
    bool        used;
} PathSlot;

// ── Main index struct ───────────────────────────────────
#define NAME_INIT_CAP   131072   // 128K
#define META_INIT_CAP   131072
#define PATH_HASH_CAP   262144   // power of 2
#define MAX_RESULTS     10000

struct CIndex {
    // Thread safety
    pthread_mutex_t mutex;

    // Sorted name array
    NameSlot* names;
    uint32_t  name_count;
    uint32_t  name_cap;

    // Dense metadata array: array of pointers to single-allocation entries.
    DFileMeta** metas;
    uint32_t    meta_count;
    uint32_t    meta_cap;

    // id → meta_idx direct map (O(1) lookup). UINT32_MAX = absent.
    // Lazily allocated; grows with next_id. ids never reuse (next_id only grows).
    uint32_t* id_index;
    uint32_t  id_index_cap;

    // Path → meta index hash
    PathSlot* path_hash;
    uint32_t  path_hash_mask;  // capacity - 1
    uint32_t  path_count;      // number of used slots (for O(1) load-factor check)

    // Directory entries count (for fast count)
    uint32_t  file_count;

    // Auto-increment ID
    uint32_t  next_id;

    // Trigram inverted index for O(1)-ish substring search.
    CTrigramIndex* tri;
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

// FNV-1a hash for paths
static uint32_t path_hash_fn(const char* s) {
    uint32_t h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s; h *= 16777619u; s++; }
    return h;
}

// ── Create / Destroy ────────────────────────────────────

CIndex* cindex_create_with_path_cap(uint32_t path_cap) {
    CIndex* idx = (CIndex*)calloc(1, sizeof(CIndex));
    if (!idx) return NULL;

    pthread_mutex_init(&idx->mutex, NULL);

    idx->name_cap = NAME_INIT_CAP;
    idx->names = (NameSlot*)calloc(idx->name_cap, sizeof(NameSlot));

    idx->meta_cap = META_INIT_CAP;
    idx->metas = (DFileMeta**)calloc(idx->meta_cap, sizeof(DFileMeta*));

    // Round path_cap up to a power of two (min 16). The hash table relies on
    // capacity being a power of two so `hash & mask` distributes uniformly.
    uint32_t cap = 16;
    while (cap < path_cap) cap *= 2;
    idx->path_hash_mask = cap - 1;
    idx->path_hash = (PathSlot*)calloc(cap, sizeof(PathSlot));
    // path_count is 0 (calloc-zeroed).

    idx->next_id = 1;

    idx->tri = ctrigram_create();

    return idx;
}

CIndex* cindex_create(void) {
    return cindex_create_with_path_cap(PATH_HASH_CAP);
}

void cindex_destroy(CIndex* idx) {
    if (!idx) return;
    pthread_mutex_lock(&idx->mutex);
    // Each DFileMeta owns all its strings; freeing it frees them. NameSlot.name
    // and PathSlot.path are non-owning pointers into a DFileMeta, so do NOT free
    // them here — just free the arrays.
    for (uint32_t i = 0; i < idx->meta_count; i++) {
        free(idx->metas[i]);
    }
    free(idx->names);
    free(idx->metas);
    free(idx->path_hash);   // array only; path strings owned by DFileMeta
    free(idx->id_index);
    CTrigramIndex* tri = idx->tri;
    pthread_mutex_unlock(&idx->mutex);
    pthread_mutex_destroy(&idx->mutex);
    ctrigram_destroy(tri);
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

// Double the path-hash table and rehash all live entries. Called when load
// factor exceeds 0.5. Runs under the index mutex (caller holds it). On OOM
// the old table is kept (lookups degrade but nothing crashes).
static void path_hash_resize(CIndex* idx) {
    uint32_t old_cap = idx->path_hash_mask + 1;
    uint32_t new_cap = old_cap * 2;
    PathSlot* new_table = (PathSlot*)calloc(new_cap, sizeof(PathSlot));
    if (!new_table) return;

    uint32_t new_mask = new_cap - 1;
    for (uint32_t i = 0; i < old_cap; i++) {
        if (!idx->path_hash[i].used) continue;
        const char* path = idx->path_hash[i].path;
        uint32_t h = path_hash_fn(path) & new_mask;
        while (new_table[h].used) {
            h = (h + 1) & new_mask;
        }
        new_table[h] = idx->path_hash[i];  // moves path ptr + meta_idx + used
    }

    free(idx->path_hash);  // frees the array only; path strings now owned by new_table
    idx->path_hash = new_table;
    idx->path_hash_mask = new_mask;
}

static void path_insert(CIndex* idx, const char* path, uint32_t meta_idx) {
    // Resize before inserting if load factor > 0.5 (tracked incrementally — O(1),
    // replacing the prior O(cap) recount on every insert).
    if (idx->path_count > (idx->path_hash_mask + 1) / 2) {
        path_hash_resize(idx);
    }

    uint32_t h = path_hash_fn(path) & idx->path_hash_mask;
    while (idx->path_hash[h].used) {
        // Update existing entry for this path (no count change).
        if (strcmp(idx->path_hash[h].path, path) == 0) {
            idx->path_hash[h].meta_idx = meta_idx;
            return;
        }
        h = (h + 1) & idx->path_hash_mask;
    }
    idx->path_hash[h].path = path;   // non-owning: points into a DFileMeta
    idx->path_hash[h].meta_idx = meta_idx;
    idx->path_hash[h].used = true;
    idx->path_count++;
}

// Remove `path` from the open-addressing table using backward-shift deletion
// (Knuth TAOCP §6.4, Algorithm R). Naive "mark empty" deletion leaves a gap in
// a collision chain that makes path_lookup stop early and miss later chain-mates;
// cindex_remove_locked's swap-with-last reinsert masks it in some cases but not
// all — a swapped record whose home is in a different bucket leaves the gap, so
// any record that probed past it is lost. Backshift relocates each following
// cluster entry into the gap whenever the gap lies within that entry's legal
// probe range, keeping every cluster contiguous.
static void path_remove(CIndex* idx, const char* path) {
    uint32_t mask = idx->path_hash_mask;

    // 1. Find the slot index holding `path`.
    uint32_t t = path_hash_fn(path) & mask;
    bool found = false;
    for (uint32_t steps = 0, cap = mask + 1; steps < cap; steps++) {
        PathSlot* slot = &idx->path_hash[t];
        if (!slot->used) return;                       // not found
        if (strcmp(slot->path, path) == 0) { found = true; break; }
        t = (t + 1) & mask;
    }
    if (!found) return;

    // 2. Vacate the entry, creating a gap at slot t. The path string is owned
    //    by its DFileMeta — do NOT free it here; just drop the non-owning pointer.
    idx->path_hash[t].path = NULL;
    idx->path_hash[t].used = false;
    idx->path_hash[t].meta_idx = 0;
    idx->path_count--;

    // 3. Walk the cluster past the gap and relocate each entry into the gap when
    //    the gap lies within that entry's legal linear-probe range. The cyclic
    //    test (gap-home) mod m ≤ (j-home) mod m holds iff the gap is on entry j's
    //    probe path, so moving it back fills the gap without breaking invariants.
    uint32_t gap = t;
    uint32_t j = t;
    for (;;) {
        j = (j + 1) & mask;
        PathSlot* js = &idx->path_hash[j];
        if (!js->used) break;                          // end of cluster
        uint32_t home = path_hash_fn(js->path) & mask;
        if (((gap - home) & mask) <= ((j - home) & mask)) {
            idx->path_hash[gap] = *js;                 // relocate (path ptr owned)
            js->path = NULL;
            js->used = false;
            js->meta_idx = 0;
            gap = j;
        }
    }
}

// ── Sorted name array ───────────────────────────────────

// Binary search: find first index where names[i] >= name
static uint32_t name_lower_bound(const CIndex* idx, const char* name) {
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
    // Non-owning: `name` points into a DFileMeta.data lower_name.
    idx->names[pos].name = name;
    idx->names[pos].record_id = id;
    idx->name_count++;
}

static void name_remove(CIndex* idx, const char* name, uint32_t id) {
    uint32_t pos = name_lower_bound(idx, name);
    while (pos < idx->name_count && strcmp(idx->names[pos].name, name) == 0) {
        if (idx->names[pos].record_id == id) {
            // Non-owning name pointer; do NOT free it (owned by DFileMeta).
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

// Forward declaration: id_index_ensure is defined with find_meta_by_id below,
// but cindex_insert uses it before that point.
static void id_index_ensure(CIndex* idx, uint32_t id);

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

    pthread_mutex_lock(&idx->mutex);

    // Pre-build the lowercased name (dmeta_create copies it into the entry).
    char* lower = strdup_lower(name);
    if (!lower) {
        pthread_mutex_unlock(&idx->mutex);
        return 0;
    }

    // Check for existing path (upsert)
    uint32_t existing = path_lookup(idx, path);
    if (existing != UINT32_MAX) {
        DFileMeta* old = idx->metas[existing];
        uint32_t   old_id = old->id;

        // Remove old name + path entries BEFORE freeing old.
        name_remove(idx, dmeta_lower(old), old_id);
        path_remove(idx, dmeta_path(old));

        DFileMeta* m = dmeta_create(old_id, original_name ? original_name : "",
                                    lower, path, parent_path ? parent_path : "",
                                    is_directory, size, created_at, modified_at);
        free(lower);
        if (!m) {
            pthread_mutex_unlock(&idx->mutex);
            return 0;
        }
        free(old);
        idx->metas[existing] = m;

        // Re-insert name + path pointing into the new DFileMeta.
        path_insert(idx, dmeta_path(m), existing);
        uint32_t pos = name_lower_bound(idx, dmeta_lower(m));
        name_insert_at(idx, pos, dmeta_lower(m), m->id);

        // Update trigram index (re-insert updates the stored name for this id).
        // Pass the already-lowercased lower_name; ctrigram_insert now stores a
        // non-owning pointer into DFileMeta.data (no copy).
        if (idx->tri) ctrigram_insert(idx->tri, dmeta_lower(m), m->id);

        pthread_mutex_unlock(&idx->mutex);
        return m->id;
    }

    // Expand metas if needed
    if (idx->meta_count >= idx->meta_cap) {
        idx->meta_cap *= 2;
        idx->metas = (DFileMeta**)realloc(idx->metas, idx->meta_cap * sizeof(DFileMeta*));
    }

    uint32_t meta_idx = idx->meta_count++;
    uint32_t id = idx->next_id++;

    DFileMeta* m = dmeta_create(id, original_name ? original_name : "",
                                lower, path, parent_path ? parent_path : "",
                                is_directory, size, created_at, modified_at);
    free(lower);
    if (!m) {
        // Roll back the meta_count/next_id bump; id_index not yet registered.
        idx->meta_count--;
        idx->next_id--;
        pthread_mutex_unlock(&idx->mutex);
        return 0;
    }

    id_index_ensure(idx, id);
    if (idx->id_index) idx->id_index[id] = meta_idx;

    idx->metas[meta_idx] = m;

    if (!is_directory) idx->file_count++;

    // Insert into path hash + sorted names (both point into the new DFileMeta).
    path_insert(idx, dmeta_path(m), meta_idx);
    uint32_t pos = name_lower_bound(idx, dmeta_lower(m));
    name_insert_at(idx, pos, dmeta_lower(m), id);

    // Insert into trigram index. Pass the already-lowercased lower_name;
    // ctrigram_insert now stores a non-owning pointer into DFileMeta.data (no copy).
    if (idx->tri) ctrigram_insert(idx->tri, dmeta_lower(m), id);

    pthread_mutex_unlock(&idx->mutex);
    return id;
}

// Internal: remove by ID, assumes mutex is already held.
// O(1) via the id→meta_idx direct map. Behavior matches the prior linear scan.
static bool cindex_remove_locked(CIndex* idx, uint32_t id) {
    if (id == 0 || id >= idx->id_index_cap) return false;
    uint32_t i = idx->id_index[id];
    if (i >= idx->meta_count) return false;       // UINT32_MAX or stale
    DFileMeta* m = idx->metas[i];
    if (m->id != id) return false;                // stale

    bool was_directory = m->is_directory != 0;

    // Remove from names + path hash (read pointers out of m, which is still live).
    name_remove(idx, dmeta_lower(m), id);
    path_remove(idx, dmeta_path(m));

    // Remove from trigram index.
    if (idx->tri) ctrigram_remove(idx->tri, id);

    // Clear the removed id from the direct map.
    idx->id_index[id] = UINT32_MAX;

    // Compact metas array (swap with last). If a record was swapped into slot i,
    // fix its id_index mapping and its PathSlot.meta_idx (path string is still the
    // swapped record's own, only the index moved).
    if (i < idx->meta_count - 1) {
        DFileMeta* moved = idx->metas[idx->meta_count - 1];
        idx->metas[i] = moved;
        if (moved->id < idx->id_index_cap) {
            idx->id_index[moved->id] = i;
        }
        path_insert(idx, dmeta_path(moved), i);
    }
    idx->meta_count--;

    // Free the removed DFileMeta LAST — it owns all its strings, and nothing
    // above references it after name_remove/path_remove/path_insert returned.
    free(m);

    if (!was_directory) idx->file_count--;
    return true;
}

bool cindex_remove(CIndex* idx, uint32_t id) {
    if (!idx) return false;
    pthread_mutex_lock(&idx->mutex);
    bool ok = cindex_remove_locked(idx, id);
    pthread_mutex_unlock(&idx->mutex);
    return ok;
}

bool cindex_remove_by_path(CIndex* idx, const char* path) {
    if (!idx || !path) return false;
    pthread_mutex_lock(&idx->mutex);
    uint32_t meta_idx = path_lookup(idx, path);
    bool ok = false;
    if (meta_idx != UINT32_MAX) {
        ok = cindex_remove_locked(idx, idx->metas[meta_idx]->id);
    }
    pthread_mutex_unlock(&idx->mutex);
    return ok;
}

// ── Query ───────────────────────────────────────────────

uint32_t cindex_count(const CIndex* idx) {
    if (!idx) return 0;
    pthread_mutex_lock(&((CIndex*)idx)->mutex);
    uint32_t c = idx->file_count;
    pthread_mutex_unlock(&((CIndex*)idx)->mutex);
    return c;
}

uint32_t cindex_total_records(const CIndex* idx) {
    if (!idx) return 0;
    pthread_mutex_lock(&((CIndex*)idx)->mutex);
    uint32_t c = idx->meta_count;
    pthread_mutex_unlock(&((CIndex*)idx)->mutex);
    return c;
}

uint32_t cindex_search_prefix(const CIndex* idx, const char* prefix,
                              uint32_t** out_ids, uint32_t max_results) {
    if (!idx || !prefix || !out_ids) return 0;
    if (!*prefix) return 0;

    if (max_results == 0) max_results = MAX_RESULTS;

    pthread_mutex_lock(&((CIndex*)idx)->mutex);

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
        pthread_mutex_unlock(&((CIndex*)idx)->mutex);
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
    pthread_mutex_unlock(&((CIndex*)idx)->mutex);
    return count;
}

uint32_t cindex_search_substring(const CIndex* idx, const char* substring,
                                 uint32_t** out_ids, uint32_t max_results) {
    // Contract: *out_ids is NULL on return when no results (matches
    // ctrigram_search), so callers can free(*out_ids) unconditionally.
    if (out_ids) *out_ids = NULL;
    if (!idx || !substring || !out_ids) return 0;
    if (!*substring) return 0;

    // Delegate to the trigram inverted index. Its own mutex serializes access;
    // acquiring the CIndex mutex first (in callers of cindex_remove/insert) and
    // then the trigram mutex inside is a strict, acyclic lock order (the trigram
    // index never calls back into CIndex). Cast away const exactly as the other
    // const query functions do for their mutex acquisition.
    CIndex* mut = (CIndex*)idx;
    if (!mut->tri) return 0;
    return ctrigram_search(mut->tri, substring, out_ids, max_results);
}

// ── Iterate ────────────────────────────────────────────

// Grow id_index so it can hold index `id`. New slots are set to UINT32_MAX
// (absent). Runs under the index mutex (caller holds it). On OOM, leaves
// id_index as-is — find_meta_by_id will treat unmapped ids as absent.
static void id_index_ensure(CIndex* idx, uint32_t id) {
    if (id < idx->id_index_cap) return;
    uint32_t new_cap = idx->id_index_cap > 0 ? idx->id_index_cap : META_INIT_CAP;
    while (new_cap <= id) new_cap *= 2;
    uint32_t* new_arr = (uint32_t*)malloc(new_cap * sizeof(uint32_t));
    if (!new_arr) return;
    // memset 0xFF sets every uint32 to UINT32_MAX (0xFFFFFFFF).
    memset(new_arr, 0xFF, new_cap * sizeof(uint32_t));
    if (idx->id_index) {
        memcpy(new_arr, idx->id_index, idx->id_index_cap * sizeof(uint32_t));
        free(idx->id_index);
    }
    idx->id_index = new_arr;
    idx->id_index_cap = new_cap;
}

static DFileMeta* find_meta_by_id(const CIndex* idx, uint32_t id) {
    if (id == 0 || id >= idx->id_index_cap) return NULL;
    uint32_t mi = idx->id_index[id];
    if (mi >= idx->meta_count) return NULL;  // UINT32_MAX or stale
    DFileMeta* m = idx->metas[mi];
    return m->id == id ? m : NULL;
}

uint32_t cindex_iterate(const CIndex* idx, cindex_iterate_cb cb, void* user_data) {
    if (!idx || !cb) return 0;
    pthread_mutex_lock(&((CIndex*)idx)->mutex);
    uint32_t count = 0;
    for (uint32_t i = 0; i < idx->meta_count; i++) {
        DFileMeta* m = idx->metas[i];
        // name and original_name both = dmeta_name, matching the prior behavior
        // (the lowercased name is for internal search only; callers display the
        // original-case name).
        cb(m->id, dmeta_name(m), dmeta_name(m),
           dmeta_path(m), dmeta_parent(m),
           m->is_directory != 0, m->size, m->created_at, m->modified_at,
           user_data);
        count++;
    }
    pthread_mutex_unlock(&((CIndex*)idx)->mutex);
    return count;
}

// ── Metadata accessors ──────────────────────────────────

const char* cindex_get_original_name(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? dmeta_name(m) : NULL;
}

const char* cindex_get_path(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? dmeta_path(m) : NULL;
}

const char* cindex_get_parent_path(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? dmeta_parent(m) : NULL;
}

bool cindex_is_directory(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? (m->is_directory != 0) : false;
}

int64_t cindex_get_size(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->size : 0;
}

int64_t cindex_get_created_at(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->created_at : 0;
}

int64_t cindex_get_modified_at(const CIndex* idx, uint32_t id) {
    DFileMeta* m = find_meta_by_id((CIndex*)idx, id);
    return m ? m->modified_at : 0;
}
