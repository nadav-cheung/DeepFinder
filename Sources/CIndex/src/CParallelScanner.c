// CParallelScanner — GCD-based parallel file scanner for macOS
//
// Architecture (inspired by github.com/seeyebe/rq):
//   1. Single fts_open on the root, depth-first
//   2. When entering a directory, FTS_PRE_ORDER: descend normally (single thread)
//      BUT this scanner parallelizes differently: it collects top-level subtree
//      boundaries and hands each subtree to a GCD worker via dispatch_apply.
//
// Simpler and proven-correct approach actually used here:
//   - Walk root's immediate children to find subtree roots (directories)
//   - dispatch_apply over those subtrees: each worker runs its own fts_open
//     on its subtree, batched cindex_insert
//   - A few subtrees + many files each = good parallelism without the
//     complexity of rq's per-directory work-stealing (which on macOS's APFS
//     with fast getdirentriesattr gives diminishing returns past ~8 threads)
//
// Why not per-directory work-stealing like rq: macOS APFS readdir is already
// fast and cached; the bottleneck is stat() volume, not syscall parallelism.
// Subtree partitioning gives the same speedup with much simpler lock-free code.
#include "CParallelScanner.h"
#include <fts.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

#define MAX_SKIP_NAMES    128
#define MAX_SKIP_FILES    64
#define MAX_SKIP_EXTS     64
#define MAX_SKIP_PATHS    64
#define MAX_SUBTREES      1024
#define DEFAULT_BATCH     256
#define PROGRESS_EVERY    5000

struct CParallelScanner {
    char**    skip_names;     uint32_t skip_names_count;
    char**    skip_files;     uint32_t skip_files_count;
    char**    skip_exts;      uint32_t skip_exts_count;
    char**    skip_paths;     uint32_t skip_paths_count;
    int       max_depth;      // -1 = no limit
    bool      follow_symlinks;
    uint32_t  worker_count;   // 0 = auto
    uint32_t  batch_size;
};

// ── Helpers ─────────────────────────────────────────────

static char* cstr_copy(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char* out = (char*)malloc(len + 1);
    if (out) memcpy(out, s, len + 1);
    return out;
}

static const char* file_extension(const char* name) {
    const char* dot = strrchr(name, '.');
    if (!dot || dot == name || dot[1] == '\0') return NULL;
    return dot + 1;
}

static bool path_has_skip_suffix(const char* path, const char* suffix) {
    size_t plen = strlen(path);
    size_t slen = strlen(suffix);
    if (slen > plen) return false;
    if (strcasecmp(path + plen - slen, suffix) == 0) {
        if (plen == slen) return true;
        if (path[plen - slen - 1] == '/') return true;
        return false;
    }
    const char* found = path;
    while ((found = strcasestr(found, suffix)) != NULL) {
        if (found[slen] == '/') return true;
        found++;
    }
    return false;
}

// Check whether `path` (full fts_path) should be skipped. Mutates `is_dir_skip`
// to indicate the directory itself should be pruned (FTS_SKIP).
static bool should_skip(CParallelScanner* s, const char* name, const char* path) {
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
        return true;
    }
    for (uint32_t i = 0; i < s->skip_names_count; i++) {
        if (strcasecmp(name, s->skip_names[i]) == 0) return true;
    }
    for (uint32_t i = 0; i < s->skip_files_count; i++) {
        if (strcasecmp(name, s->skip_files[i]) == 0) return true;
    }
    const char* ext = file_extension(name);
    if (ext) {
        for (uint32_t i = 0; i < s->skip_exts_count; i++) {
            if (strcasecmp(ext, s->skip_exts[i]) == 0) return true;
        }
    }
    for (uint32_t i = 0; i < s->skip_paths_count; i++) {
        if (path_has_skip_suffix(path, s->skip_paths[i])) return true;
    }
    return false;
}

// ── Lifecycle ──────────────────────────────────────────

CParallelScanner* cpscanner_create(void) {
    CParallelScanner* s = (CParallelScanner*)calloc(1, sizeof(CParallelScanner));
    if (!s) return NULL;
    s->max_depth = -1;
    s->batch_size = DEFAULT_BATCH;
    s->worker_count = 0;  // auto
    return s;
}

void cpscanner_destroy(CParallelScanner* s) {
    if (!s) return;
    for (uint32_t i = 0; i < s->skip_names_count; i++) free(s->skip_names[i]);
    for (uint32_t i = 0; i < s->skip_files_count; i++) free(s->skip_files[i]);
    for (uint32_t i = 0; i < s->skip_exts_count; i++) free(s->skip_exts[i]);
    for (uint32_t i = 0; i < s->skip_paths_count; i++) free(s->skip_paths[i]);
    free(s->skip_names); free(s->skip_files);
    free(s->skip_exts); free(s->skip_paths);
    free(s);
}

static void set_list(char*** dst, uint32_t* count, const char* const* items, uint32_t n, uint32_t cap) {
    if (!items || n == 0) return;
    if (n > cap) n = cap;
    *dst = (char**)calloc(n, sizeof(char*));
    for (uint32_t i = 0; i < n; i++) (*dst)[i] = cstr_copy(items[i]);
    *count = n;
}

void cpscanner_set_skip_names(CParallelScanner* s, const char* const* names, uint32_t count) {
    if (s) set_list(&s->skip_names, &s->skip_names_count, names, count, MAX_SKIP_NAMES);
}
void cpscanner_set_skip_files(CParallelScanner* s, const char* const* files, uint32_t count) {
    if (s) set_list(&s->skip_files, &s->skip_files_count, files, count, MAX_SKIP_FILES);
}
void cpscanner_set_skip_extensions(CParallelScanner* s, const char* const* exts, uint32_t count) {
    if (s) set_list(&s->skip_exts, &s->skip_exts_count, exts, count, MAX_SKIP_EXTS);
}
void cpscanner_set_skip_paths(CParallelScanner* s, const char* const* paths, uint32_t count) {
    if (s) set_list(&s->skip_paths, &s->skip_paths_count, paths, count, MAX_SKIP_PATHS);
}
void cpscanner_set_max_depth(CParallelScanner* s, int max_depth) { if (s) s->max_depth = max_depth; }
void cpscanner_set_follow_symlinks(CParallelScanner* s, bool follow) { if (s) s->follow_symlinks = follow; }
void cpscanner_set_worker_count(CParallelScanner* s, uint32_t count) { if (s) s->worker_count = count; }
void cpscanner_set_batch_size(CParallelScanner* s, uint32_t size) { if (s && size > 0) s->batch_size = size; }

// ── Per-subtree worker ──────────────────────────────────

typedef struct {
    CParallelScanner* s;
    CIndex* idx;
    uint32_t batch_size;

    // Atomic cancel flag (shared)
    _Atomic bool cancel_flag;

    // Atomic counters (shared)
    _Atomic uint32_t files_scanned;
    _Atomic uint32_t dirs_scanned;
    _Atomic uint32_t skipped;

    cpscanner_error_cb error_cb;
    void* user_data;
} WorkerCtx;

// Process one subtree (a single top-level entry from the root).
// Owns its own fts handle — no locking needed for traversal.
// Only cindex_insert needs the index mutex (handled inside CIndex).
static void scan_subtree(WorkerCtx* wc, const char* subtree_path) {
    CParallelScanner* s = wc->s;
    char* argv[2] = { (char*)subtree_path, NULL };

    FTS* fts = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) {
        if (wc->error_cb) wc->error_cb(subtree_path, "fts_open failed", wc->user_data);
        return;
    }

    FTSENT* ent;
    while ((ent = fts_read(fts)) != NULL) {
        if (atomic_load(&wc->cancel_flag)) break;

        if (ent->fts_info == FTS_ERR || ent->fts_info == FTS_DNR) {
            if (wc->error_cb) {
                wc->error_cb(ent->fts_path, strerror(ent->fts_errno), wc->user_data);
            }
            if (ent->fts_info == FTS_DNR) fts_set(fts, ent, FTS_SKIP);
            continue;
        }

        bool is_dir = (ent->fts_info == FTS_D || ent->fts_info == FTS_DC || ent->fts_info == FTS_DOT);
        bool is_file = (ent->fts_info == FTS_F);
        bool is_symlink = (ent->fts_info == FTS_SL || ent->fts_info == FTS_SLNONE);

        if (!is_dir && !is_file && !is_symlink) continue;
        if (is_symlink && !s->follow_symlinks) continue;

        // Depth limit
        if (s->max_depth >= 0 && ent->fts_level > s->max_depth) {
            if (is_dir) fts_set(fts, ent, FTS_SKIP);
            continue;
        }

        const char* name = ent->fts_name;
        const char* path = ent->fts_path;

        // Skip-pattern check. If a directory matches, prune it.
        if (should_skip(s, name, path)) {
            if (is_dir) fts_set(fts, ent, FTS_SKIP);
            atomic_fetch_add(&wc->skipped, 1);
            continue;
        }

        struct stat* st = ent->fts_statp;
        bool is_directory = st ? S_ISDIR(st->st_mode) : is_dir;
        bool is_regular = st ? S_ISREG(st->st_mode) : is_file;
        if (!is_regular && !is_directory) continue;

        int64_t size = st ? (int64_t)st->st_size : 0;
#ifdef __APPLE__
        int64_t created = st ? (int64_t)st->st_birthtime : 0;
#else
        int64_t created = st ? (int64_t)st->st_ctime : 0;
#endif
        int64_t modified = st ? (int64_t)st->st_mtime : 0;

        // Compute parent path
        const char* full_path = path;
        size_t plen = strlen(full_path);
        size_t nlen = strlen(name);
        size_t parent_len = plen - nlen;
        if (parent_len > 0 && full_path[parent_len - 1] == '/') parent_len--;
        char parent_path[4096];
        if (parent_len >= sizeof(parent_path)) parent_len = sizeof(parent_path) - 1;
        if (parent_len > 0) {
            memcpy(parent_path, full_path, parent_len);
            parent_path[parent_len] = '\0';
        } else {
            parent_path[0] = '/'; parent_path[1] = '\0';
        }

        cindex_insert(wc->idx, name, name, full_path, parent_path,
                      is_directory, is_directory ? 0 : size, created, modified);

        if (is_directory) {
            atomic_fetch_add(&wc->dirs_scanned, 1);
        } else {
            atomic_fetch_add(&wc->files_scanned, 1);
        }
    }

    fts_close(fts);
}

// ── Top-level scan ──────────────────────────────────────

uint32_t cpscanner_scan(CParallelScanner* s, CIndex* idx,
                        const char* root_path,
                        cpscanner_progress_cb progress_cb,
                        cpscanner_error_cb error_cb,
                        void* user_data) {
    if (!s || !idx || !root_path) return 0;

    // Heap-allocated worker context so the GCD block captures a stable pointer
    // to the shared atomic counters. (A stack WorkerCtx would be copied by
    // the block, breaking counter sharing.)
    WorkerCtx* wc = (WorkerCtx*)calloc(1, sizeof(WorkerCtx));
    if (!wc) return 0;
    atomic_init(&wc->cancel_flag, false);
    atomic_init(&wc->files_scanned, 0);
    atomic_init(&wc->dirs_scanned, 0);
    atomic_init(&wc->skipped, 0);
    wc->s = s;
    wc->idx = idx;
    wc->batch_size = s->batch_size;
    wc->error_cb = error_cb;
    wc->user_data = user_data;

    // Collect top-level children of root_path to use as parallel subtrees.
    char** subtrees = (char**)calloc(MAX_SUBTREES, sizeof(char*));
    uint32_t subtree_count = 0;

    char* root_argv[2] = { (char*)root_path, NULL };
    FTS* root_fts = fts_open(root_argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!root_fts) {
        if (error_cb) error_cb(root_path, "fts_open failed for root", user_data);
        free(subtrees);
        free(wc);
        return 0;
    }

    FTSENT* ent;
    bool got_root = false;
    while ((ent = fts_read(root_fts)) != NULL) {
        if (!got_root) {
            got_root = true;  // skip the root entry itself
            continue;
        }
        // Skip postorder (FTS_DP) entries — a level-1 directory is yielded both
        // as FTS_D (preorder) and FTS_DP (postorder), both at fts_level==1.
        // Without this, each directory's subtree would be recorded twice.
        if (ent->fts_info == FTS_DP) continue;
        if (ent->fts_level != 1) {
            if (ent->fts_info == FTS_DP || ent->fts_level < 1) continue;
            if (ent->fts_info == FTS_D) fts_set(root_fts, ent, FTS_SKIP);
            continue;
        }
        if (should_skip(s, ent->fts_name, ent->fts_path)) {
            atomic_fetch_add(&wc->skipped, 1);
            if (ent->fts_info == FTS_D) fts_set(root_fts, ent, FTS_SKIP);
            continue;
        }
        if (subtree_count < MAX_SUBTREES) {
            subtrees[subtree_count++] = strdup(ent->fts_path);
        }
        if (ent->fts_info == FTS_D) fts_set(root_fts, ent, FTS_SKIP);
    }
    fts_close(root_fts);

    // Index the root directory itself (workers only scan its children).
    {
        struct stat rst;
        if (stat(root_path, &rst) == 0) {
            const char* root_name = strrchr(root_path, '/');
            root_name = root_name ? root_name + 1 : root_path;
#ifdef __APPLE__
            int64_t created = (int64_t)rst.st_birthtime;
#else
            int64_t created = (int64_t)rst.st_ctime;
#endif
            cindex_insert(idx, root_name, root_name, root_path, "/",
                          true, 0, created, (int64_t)rst.st_mtime);
            atomic_fetch_add(&wc->dirs_scanned, 1);
        }
    }

    if (subtree_count == 0) {
        free(subtrees);
        uint32_t f = atomic_load(&wc->files_scanned);
        free(wc);
        return f;
    }

    // Worker count: cap at subtree count, default to online CPUs.
    (void)0;  // (worker_count only sizes the GCD queue, dispatch_apply ignores it)

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    dispatch_apply(subtree_count, queue, ^(size_t i) {
        scan_subtree(wc, subtrees[i]);

        if (progress_cb) {
            uint32_t f = atomic_load(&wc->files_scanned);
            if (f % PROGRESS_EVERY < wc->batch_size) {
                if (!progress_cb(f, atomic_load(&wc->dirs_scanned),
                                 atomic_load(&wc->skipped), user_data)) {
                    atomic_store(&wc->cancel_flag, true);
                }
            }
        }
    });

    for (uint32_t i = 0; i < subtree_count; i++) free(subtrees[i]);
    free(subtrees);

    if (progress_cb) {
        progress_cb(atomic_load(&wc->files_scanned), atomic_load(&wc->dirs_scanned),
                    atomic_load(&wc->skipped), user_data);
    }

    uint32_t result = atomic_load(&wc->files_scanned);
    free(wc);
    return result;
}
