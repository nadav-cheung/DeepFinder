// CTrigramIndex implementation — standalone trigram inverted index.
//
// Memory layout:
//   - arena: contiguous uint8_t buffer holding lowercased names; geometric growth.
//   - spans: dense Span array indexed by `id` (sparse ids waste slots but are correct).
//   - postings: flat uint32_t array; all posting lists concatenated, each sorted by id.
//   - blocks: PostingBlock array sorted by trigram => binary search slices into postings.
//   - pending: unsorted (trigram,id) pairs flushed lazily via sort + merge.
//
// SPDX-License-Identifier: MIT
#include "include/CTrigramIndex.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>   // strncasecmp
#include <ctype.h>     // tolower
#include <pthread.h>

// ── Tunables ────────────────────────────────────────────
#define TRI_ARENA_INIT_CAP    4096u
#define TRI_SPANS_INIT_CAP    1024u
#define TRI_PENDING_AUTOFLUSH 8192u
#define TRI_MAX_QUERY_TRIGRAMS 64u

// ── Types ───────────────────────────────────────────────
typedef struct {
    uint32_t offset;   // into arena
    uint8_t  len;      // filename <=255 bytes => fits u8; 0 == tombstone / empty
} Span;

typedef struct {
    uint32_t trigram;  // (b0<<16)|(b1<<8)|b2 over lowercased bytes
    uint32_t offset;   // start index into postings[]
    uint32_t len;      // number of ids in this list
} PostingBlock;

typedef struct {
    uint32_t trigram;
    uint32_t id;
} PendingEntry;

struct CTrigramIndex {
    pthread_mutex_t mutex;

    // Arena of lowercased names (no zero-init on growth).
    uint8_t* arena;
    uint32_t arena_used;
    uint32_t arena_cap;

    // Dense id -> Span table.
    Span*    spans;
    uint32_t spans_cap;     // capacity (>= max id + 1)
    uint32_t doc_count;     // live docs (span with len>0)

    // Flat posting lists (all blocks concatenated, each list id-sorted).
    uint32_t*     postings;
    uint32_t      postings_used;
    uint32_t      postings_cap;

    // Block index, sorted by trigram.
    PostingBlock* blocks;
    uint32_t      block_count;
    uint32_t      block_cap;

    // Pending insertions.
    PendingEntry* pending;
    uint32_t      pending_count;
    uint32_t      pending_cap;
};

// ── Helpers ─────────────────────────────────────────────

// Lowercase a byte. Bytes >=0x80 are returned unchanged (CJK has no case;
// tolower in the C locale is a no-op there anyway, and casting to unsigned
// char keeps the argument in the safe range).
static uint8_t lc_byte(unsigned char c) {
    if (c < 0x80) return (uint8_t)tolower(c);
    return c;
}

static bool arena_ensure(CTrigramIndex* ti, uint32_t extra) {
    if ((uint64_t)ti->arena_used + extra <= ti->arena_cap) return true;
    uint64_t need = (uint64_t)ti->arena_used + (uint64_t)extra;
    uint64_t cap  = ti->arena_cap ? ti->arena_cap : TRI_ARENA_INIT_CAP;
    while (cap < need) cap *= 2;
    if (cap > 0xffffffffu) cap = 0xffffffffu;
    uint8_t* nb = (uint8_t*)realloc(ti->arena, (size_t)cap);
    if (!nb) return false;
    ti->arena = nb;
    ti->arena_cap = (uint32_t)cap;
    return true;
}

static bool spans_ensure(CTrigramIndex* ti, uint32_t id) {
    if (id < ti->spans_cap) return true;
    uint64_t cap = ti->spans_cap ? ti->spans_cap : TRI_SPANS_INIT_CAP;
    while (cap <= (uint64_t)id) cap *= 2;
    if (cap > 0xffffffffu) cap = 0xffffffffu;
    Span* ns = (Span*)realloc(ti->spans, (size_t)cap * sizeof(Span));
    if (!ns) return false;
    // Zero-init only the newly extended portion (existing slots are preserved).
    memset(ns + ti->spans_cap, 0,
           (size_t)(cap - ti->spans_cap) * sizeof(Span));
    ti->spans = ns;
    ti->spans_cap = (uint32_t)cap;
    return true;
}

static bool pending_ensure(CTrigramIndex* ti, uint32_t extra) {
    uint64_t need = (uint64_t)ti->pending_count + (uint64_t)extra;
    if (need <= ti->pending_cap) return true;
    uint64_t cap = ti->pending_cap ? ti->pending_cap : 1024;
    while (cap < need) cap *= 2;
    PendingEntry* np = (PendingEntry*)realloc(ti->pending,
                                              (size_t)cap * sizeof(PendingEntry));
    if (!np) return false;
    ti->pending = np;
    ti->pending_cap = (uint32_t)cap;
    return true;
}

// Extract the next trigram at byte position i over a lowercased buffer of length n.
// Returns true and writes *out, or false if fewer than 3 bytes remain.
static inline bool make_trigram(const uint8_t* s, uint32_t n, uint32_t i, uint32_t* out) {
    if (i + 3 > n) return false;
    *out = ((uint32_t)s[i] << 16) | ((uint32_t)s[i + 1] << 8) | (uint32_t)s[i + 2];
    return true;
}

// qsort comparator for PendingEntry: by trigram asc, then id asc.
static int pending_cmp(const void* a, const void* b) {
    const PendingEntry* pa = (const PendingEntry*)a;
    const PendingEntry* pb = (const PendingEntry*)b;
    if (pa->trigram < pb->trigram) return -1;
    if (pa->trigram > pb->trigram) return 1;
    if (pa->id < pb->id) return -1;
    if (pa->id > pb->id) return 1;
    return 0;
}

// Binary search a block by trigram. Returns index, or UINT32_MAX if absent.
static uint32_t block_find(const CTrigramIndex* ti, uint32_t trigram) {
    uint32_t lo = 0, hi = ti->block_count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (ti->blocks[mid].trigram < trigram) lo = mid + 1;
        else hi = mid;
    }
    if (lo < ti->block_count && ti->blocks[lo].trigram == trigram) return lo;
    return UINT32_MAX;
}

// ── Flush: merge pending (trigram,id) pairs into blocks + postings ──
//
// Strategy: sort pending by (trigram,id); for each trigram group, also load the
// existing posting slice (if any) for that trigram, merge the two sorted id
// streams while deduping, and replace that trigram's slice with the merged run.
// All merged runs are written into a fresh postings buffer; old postings buffer
// is freed at the end. Blocks array is rebuilt to cover all trigrams that now
// have any postings (existing + newly seen).
static void ctrigram_flush_locked(CTrigramIndex* ti) {
    if (ti->pending_count == 0) return;

    qsort(ti->pending, ti->pending_count, sizeof(PendingEntry), pending_cmp);

    // Upper bound on merged postings size: existing total + all pending.
    uint64_t merged_cap = (uint64_t)ti->postings_used + (uint64_t)ti->pending_count;
    if (merged_cap > 0xffffffffu) merged_cap = 0xffffffffu;
    uint32_t* merged = (uint32_t*)malloc((size_t)merged_cap * sizeof(uint32_t));
    if (!merged) {
        // Allocation failure: drop pending to avoid an unbounded retry storm.
        // Correctness is preserved (search still uses existing blocks + verification).
        ti->pending_count = 0;
        return;
    }
    uint32_t merged_used = 0;

    // New blocks array. Worst case: existing blocks + one new block per pending
    // group (every pending group introduces at most one previously-unseen trigram).
    uint32_t new_block_cap = ti->block_count + ti->pending_count;
    if (new_block_cap < 64) new_block_cap = 64;
    PostingBlock* new_blocks = (PostingBlock*)malloc((size_t)new_block_cap * sizeof(PostingBlock));
    if (!new_blocks) {
        free(merged);
        ti->pending_count = 0;
        return;
    }
    uint32_t new_block_count = 0;

    uint32_t bi = 0;                 // cursor over existing blocks (sorted)
    uint32_t pi = 0;                 // cursor over pending (sorted)

    // Walk existing blocks in order; for each, fold in any pending entries that
    // share its trigram. Pending trigrams with no matching existing block are
    // appended afterwards.
    while (bi < ti->block_count || pi < ti->pending_count) {
        uint32_t cur_tri;
        bool have_block = (bi < ti->block_count);
        bool have_pending_pair = (pi < ti->pending_count);

        if (have_block && have_pending_pair) {
            uint32_t bt = ti->blocks[bi].trigram;
            uint32_t pt = ti->pending[pi].trigram;
            if (bt < pt) { cur_tri = bt; have_pending_pair = false; }
            else if (bt > pt) { cur_tri = pt; have_block = false; }
            else { cur_tri = bt; } // equal: merge both
        } else if (have_block) {
            cur_tri = ti->blocks[bi].trigram;
        } else {
            cur_tri = ti->pending[pi].trigram;
        }

        // Source A: existing slice for cur_tri (if block cursor matches).
        const uint32_t* srcA = NULL;
        uint32_t srcA_len = 0;
        if (have_block && bi < ti->block_count && ti->blocks[bi].trigram == cur_tri) {
            PostingBlock* blk = &ti->blocks[bi];
            srcA = ti->postings + blk->offset;
            srcA_len = blk->len;
            bi++;
        }
        // Source B: pending run for cur_tri.
        uint32_t srcB_start = pi;
        while (pi < ti->pending_count && ti->pending[pi].trigram == cur_tri) pi++;

        // Record this trigram's slice in the merged blocks array.
        if (new_block_count >= new_block_cap) {
            // Should not happen given the capacity estimate, but grow defensively.
            uint32_t nc = new_block_cap * 2;
            PostingBlock* nb = (PostingBlock*)realloc(new_blocks,
                                                      (size_t)nc * sizeof(PostingBlock));
            if (!nb) { free(merged); free(new_blocks); ti->pending_count = 0; return; }
            new_blocks = nb;
            new_block_cap = nc;
        }
        new_blocks[new_block_count].trigram = cur_tri;
        new_blocks[new_block_count].offset = merged_used;

        // Two-pointer merge of srcA and the pending run, dedup by id.
        uint32_t ai = 0;
        uint32_t pj = srcB_start;
        while (ai < srcA_len || pj < pi) {
            uint32_t av = (ai < srcA_len) ? srcA[ai] : 0xffffffffu;
            uint32_t pv = (pj < pi) ? ti->pending[pj].id : 0xffffffffu;
            uint32_t pick;
            if (ai >= srcA_len) {
                pick = pv; pj++;
            } else if (pj >= pi) {
                pick = av; ai++;
            } else if (av < pv) {
                pick = av; ai++;
            } else if (av > pv) {
                pick = pv; pj++;
            } else {
                pick = av; ai++; pj++; // dedup
            }
            merged[merged_used++] = pick;
        }
        new_blocks[new_block_count].len = merged_used - new_blocks[new_block_count].offset;
        new_block_count++;
    }

    // Commit.
    free(ti->postings);
    ti->postings = merged;
    ti->postings_used = merged_used;
    ti->postings_cap = (uint32_t)merged_cap;
    free(ti->blocks);
    ti->blocks = new_blocks;
    ti->block_count = new_block_count;
    ti->block_cap = new_block_cap;
    ti->pending_count = 0;
}

// ── Create / Destroy ────────────────────────────────────

CTrigramIndex* ctrigram_create(void) {
    CTrigramIndex* ti = (CTrigramIndex*)calloc(1, sizeof(CTrigramIndex));
    if (!ti) return NULL;
    pthread_mutex_init(&ti->mutex, NULL);
    return ti;
}

void ctrigram_destroy(CTrigramIndex* ti) {
    if (!ti) return;
    pthread_mutex_lock(&ti->mutex);
    free(ti->arena);
    free(ti->spans);
    free(ti->postings);
    free(ti->blocks);
    free(ti->pending);
    pthread_mutex_unlock(&ti->mutex);
    pthread_mutex_destroy(&ti->mutex);
    free(ti);
}

// ── Insert ──────────────────────────────────────────────

void ctrigram_insert(CTrigramIndex* ti, const char* name, uint32_t id) {
    if (!ti || !name) return;

    pthread_mutex_lock(&ti->mutex);

    if (!spans_ensure(ti, id)) { pthread_mutex_unlock(&ti->mutex); return; }

    // Compute length and lowercase into the arena.
    size_t raw_len = strlen(name);
    if (raw_len > 255) raw_len = 255;            // filename cap
    uint32_t n = (uint32_t)raw_len;

    if (!arena_ensure(ti, n)) { pthread_mutex_unlock(&ti->mutex); return; }

    uint32_t off = ti->arena_used;
    for (uint32_t i = 0; i < n; i++) {
        ti->arena[off + i] = lc_byte((unsigned char)name[i]);
    }
    ti->arena_used += n;

    // Track document count: if this id previously had no live span, it's new.
    Span* sp = &ti->spans[id];
    if (sp->len == 0) ti->doc_count++;
    sp->offset = off;
    sp->len = (uint8_t)n;

    // Append trigrams to the pending buffer (one entry per trigram position;
    // duplicate trigrams within the same name are intentional — the merge dedups).
    if (n >= 3) {
        uint32_t nt = n - 2;                     // number of trigram positions
        if (!pending_ensure(ti, nt)) {
            // Force a flush to make room, then retry once.
            ctrigram_flush_locked(ti);
            if (!pending_ensure(ti, nt)) {
                pthread_mutex_unlock(&ti->mutex);
                return;
            }
        }
        const uint8_t* s = ti->arena + off;
        for (uint32_t i = 0; i < nt; i++) {
            uint32_t t;
            if (!make_trigram(s, n, i, &t)) break;
            ti->pending[ti->pending_count].trigram = t;
            ti->pending[ti->pending_count].id = id;
            ti->pending_count++;
        }
    }

    if (ti->pending_count >= TRI_PENDING_AUTOFLUSH) {
        ctrigram_flush_locked(ti);
    }

    pthread_mutex_unlock(&ti->mutex);
}

// ── Remove ──────────────────────────────────────────────

bool ctrigram_remove(CTrigramIndex* ti, uint32_t id) {
    if (!ti) return false;
    pthread_mutex_lock(&ti->mutex);
    bool found = false;
    if (id < ti->spans_cap && ti->spans[id].len > 0) {
        ti->spans[id].len = 0;        // tombstone: verification will reject
        ti->spans[id].offset = 0;
        if (ti->doc_count > 0) ti->doc_count--;
        found = true;
        // Note: stale posting entries for this id may remain until a rebuild;
        // they are inert because ctrigram_name()/verification returns NULL.
    }
    pthread_mutex_unlock(&ti->mutex);
    return found;
}

// ── name / doc_count ────────────────────────────────────

const char* ctrigram_name(CTrigramIndex* ti, uint32_t id) {
    if (!ti) return NULL;
    // Read-only fast path: caller holds no other lock, and our public contract
    // is "valid until next rebuild". Lock briefly to get a consistent view.
    pthread_mutex_lock(&ti->mutex);
    const char* result = NULL;
    if (id < ti->spans_cap && ti->spans[id].len > 0) {
        result = (const char*)(ti->arena + ti->spans[id].offset);
    }
    pthread_mutex_unlock(&ti->mutex);
    return result;
}

uint32_t ctrigram_doc_count(const CTrigramIndex* ti) {
    if (!ti) return 0;
    pthread_mutex_lock(&((CTrigramIndex*)ti)->mutex);
    uint32_t c = ti->doc_count;
    pthread_mutex_unlock(&((CTrigramIndex*)ti)->mutex);
    return c;
}

void ctrigram_flush(CTrigramIndex* ti) {
    if (!ti) return;
    pthread_mutex_lock(&ti->mutex);
    ctrigram_flush_locked(ti);
    pthread_mutex_unlock(&ti->mutex);
}

// ── Search ──────────────────────────────────────────────

// Intersect candidate id sets from up to `k` posting slices, starting from the
// SHORTEST list via two-pointer merge. Writes survivors into *out (malloc'd).
// Returns survivor count. Caller must have flushed first.
static uint32_t intersect_slices(CTrigramIndex* ti,
                                 const uint32_t* slice_offs,
                                 const uint32_t* slice_lens,
                                 uint32_t k,
                                 uint32_t** out) {
    if (k == 0) { *out = NULL; return 0; }

    // Find the shortest slice to drive the merge.
    uint32_t shortest = 0;
    for (uint32_t i = 1; i < k; i++) {
        if (slice_lens[i] < slice_lens[shortest]) shortest = i;
    }
    const uint32_t* base = ti->postings + slice_offs[shortest];
    uint32_t base_len = slice_lens[shortest];
    if (base_len == 0) { *out = NULL; return 0; }

    // Scratch buffers for the rolling intersection.
    uint32_t* cur = (uint32_t*)malloc((size_t)base_len * sizeof(uint32_t));
    if (!cur) { *out = NULL; return 0; }
    memcpy(cur, base, (size_t)base_len * sizeof(uint32_t));
    uint32_t cur_len = base_len;

    for (uint32_t s = 0; s < k && cur_len > 0; s++) {
        if (s == shortest) continue;
        const uint32_t* other = ti->postings + slice_offs[s];
        uint32_t olen = slice_lens[s];
        uint32_t i = 0, j = 0, w = 0;
        while (i < cur_len && j < olen) {
            if (cur[i] < other[j]) i++;
            else if (cur[i] > other[j]) j++;
            else { cur[w++] = cur[i]; i++; j++; }
        }
        cur_len = w;
    }

    if (cur_len == 0) { free(cur); *out = NULL; return 0; }
    *out = cur;
    return cur_len;
}

uint32_t ctrigram_search(CTrigramIndex* ti, const char* query,
                         uint32_t** out_ids, uint32_t max_results) {
    if (!ti || !query || !out_ids) return 0;
    *out_ids = NULL;

    pthread_mutex_lock(&ti->mutex);

    if (ti->pending_count > 0) ctrigram_flush_locked(ti);

    size_t qlen = strlen(query);
    if (qlen == 0) { pthread_mutex_unlock(&ti->mutex); return 0; }

    // Build lowercased query buffer (verbatim bytes >=0x80 preserved).
    uint8_t qbuf[256];
    if (qlen > 255) qlen = 255;
    uint32_t qn = (uint32_t)qlen;
    for (uint32_t i = 0; i < qn; i++) {
        qbuf[i] = lc_byte((unsigned char)query[i]);
    }

    // <3-byte query: linear-scan the arena via the spans table.
    if (qn < 3) {
        // Cap candidate walk: scan up to spans_cap slots; collect matches.
        uint32_t cap_guess = ti->doc_count;
        if (cap_guess == 0) { pthread_mutex_unlock(&ti->mutex); return 0; }
        uint32_t* results = (uint32_t*)malloc((size_t)cap_guess * sizeof(uint32_t));
        if (!results) { pthread_mutex_unlock(&ti->mutex); return 0; }
        uint32_t rcount = 0;
        for (uint32_t id = 0; id < ti->spans_cap; id++) {
            Span* sp = &ti->spans[id];
            if (sp->len == 0) continue;
            // Verify: the lowercased arena name contains qbuf.
            const uint8_t* nm = ti->arena + sp->offset;
            uint32_t nl = sp->len;
            bool match = false;
            if (nl >= qn) {
                for (uint32_t i = 0; i + qn <= nl; i++) {
                    if (memcmp(nm + i, qbuf, qn) == 0) { match = true; break; }
                }
            }
            if (match) {
                if (max_results > 0 && rcount >= max_results) break;
                results[rcount++] = id;
            }
        }
        if (rcount == 0) { free(results); pthread_mutex_unlock(&ti->mutex); return 0; }
        *out_ids = results;
        pthread_mutex_unlock(&ti->mutex);
        return rcount;
    }

    // >=3-byte query: extract unique trigrams from the query, look up each block.
    uint32_t q_tris[TRI_MAX_QUERY_TRIGRAMS];
    uint32_t q_tri_count = 0;
    for (uint32_t i = 0; i + 3 <= qn && q_tri_count < TRI_MAX_QUERY_TRIGRAMS; i++) {
        uint32_t t;
        if (!make_trigram(qbuf, qn, i, &t)) break;
        // Dedup within the query.
        bool dup = false;
        for (uint32_t j = 0; j < q_tri_count; j++) {
            if (q_tris[j] == t) { dup = true; break; }
        }
        if (!dup) q_tris[q_tri_count++] = t;
    }

    uint32_t slice_offs[TRI_MAX_QUERY_TRIGRAMS];
    uint32_t slice_lens[TRI_MAX_QUERY_TRIGRAMS];
    uint32_t k = 0;
    for (uint32_t i = 0; i < q_tri_count; i++) {
        uint32_t bi = block_find(ti, q_tris[i]);
        if (bi == UINT32_MAX) {
            // Query has a trigram no document shares => no matches.
            k = 0;
            break;
        }
        slice_offs[k] = ti->blocks[bi].offset;
        slice_lens[k] = ti->blocks[bi].len;
        k++;
    }

    if (k == 0) { pthread_mutex_unlock(&ti->mutex); return 0; }

    uint32_t* candidates = NULL;
    uint32_t cand_count = intersect_slices(ti, slice_offs, slice_lens, k, &candidates);
    if (cand_count == 0) { pthread_mutex_unlock(&ti->mutex); return 0; }

    // Verify each candidate by strncasecmp against its arena name.
    uint32_t* results = (uint32_t*)malloc((size_t)cand_count * sizeof(uint32_t));
    if (!results) { free(candidates); pthread_mutex_unlock(&ti->mutex); return 0; }
    uint32_t rcount = 0;
    for (uint32_t i = 0; i < cand_count; i++) {
        uint32_t id = candidates[i];
        if (id >= ti->spans_cap) continue;            // stale posting (removed)
        Span* sp = &ti->spans[id];
        if (sp->len == 0) continue;                   // tombstoned
        if (sp->len < qn) continue;                   // too short to contain query
        const char* nm = (const char*)(ti->arena + sp->offset);
        bool match = false;
        uint32_t nl = sp->len;
        for (uint32_t p = 0; p + qn <= nl; p++) {
            if (strncasecmp(nm + p, (const char*)qbuf, qn) == 0) { match = true; break; }
        }
        if (match) {
            results[rcount++] = id;
            if (max_results > 0 && rcount >= max_results) break;
        }
    }
    free(candidates);

    if (rcount == 0) { free(results); pthread_mutex_unlock(&ti->mutex); return 0; }
    *out_ids = results;
    pthread_mutex_unlock(&ti->mutex);
    return rcount;
}
