// CFileScanner — Zero-allocation directory scanner using POSIX fts(3)
// Directly inserts into CIndex, bypassing Swift entirely.
#include "CFileScanner.h"
#include <fts.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <sys/stat.h>

// ── Scanner struct ───────────────────────────────────────

#define MAX_SKIP_NAMES      128
#define MAX_SKIP_FILES      64
#define MAX_SKIP_EXTS       64
#define MAX_SKIP_PATHS      64
#define PROGRESS_INTERVAL   100

struct CFileScanner {
    // Skip lists
    char** skip_names;
    uint32_t skip_names_count;
    char** skip_files;
    uint32_t skip_files_count;
    char** skip_exts;
    uint32_t skip_exts_count;
    char** skip_paths;
    uint32_t skip_paths_count;

    // Settings
    int  max_depth;        // -1 = no limit
    bool follow_symlinks;
};

// ── Helpers ─────────────────────────────────────────────

static char* cstr_copy(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char* out = (char*)malloc(len + 1);
    if (out) memcpy(out, s, len + 1);
    return out;
}

static bool str_eq_nocase(const char* a, const char* b) {
    return strcasecmp(a, b) == 0;
}

static bool str_has_suffix_nocase(const char* str, const char* suffix) {
    size_t slen = strlen(str);
    size_t sufflen = strlen(suffix);
    if (sufflen > slen) return false;
    return strcasecmp(str + slen - sufflen, suffix) == 0;
}

// Check if `path` ends with `suffix` at a component boundary.
// e.g., path="/foo/.git", suffix="/.git" → match
//       path="/foo/.git/objects", suffix="/.git" → match (component boundary after suffix)
//       path="/foo/.gitignore", suffix="/.git" → NO match
static bool path_has_skip_suffix(const char* path, const char* suffix) {
    size_t plen = strlen(path);
    size_t slen = strlen(suffix);
    if (slen > plen) return false;

    // Check if path ends with suffix
    if (strcasecmp(path + plen - slen, suffix) == 0) {
        // Must be at a component boundary
        if (plen == slen) return true;  // exact match
        if (path[plen - slen - 1] == '/') return true;
        return false;
    }

    // Check if suffix appears mid-path as a component: contains(suffix + "/")
    // We search for suffix followed by '/'
    const char* found = path;
    while ((found = strcasestr(found, suffix)) != NULL) {
        if (found[slen] == '/') return true;
        found++;
    }

    return false;
}

static const char* file_extension(const char* name) {
    const char* dot = strrchr(name, '.');
    if (!dot || dot == name || dot[1] == '\0') return NULL;
    return dot + 1;  // skip the dot
}

// ── Create / Destroy ────────────────────────────────────

CFileScanner* cscanner_create(void) {
    CFileScanner* s = (CFileScanner*)calloc(1, sizeof(CFileScanner));
    if (!s) return NULL;
    s->max_depth = -1;  // no limit
    s->follow_symlinks = false;
    return s;
}

void cscanner_destroy(CFileScanner* s) {
    if (!s) return;
    for (uint32_t i = 0; i < s->skip_names_count; i++) free(s->skip_names[i]);
    for (uint32_t i = 0; i < s->skip_files_count; i++) free(s->skip_files[i]);
    for (uint32_t i = 0; i < s->skip_exts_count; i++) free(s->skip_exts[i]);
    for (uint32_t i = 0; i < s->skip_paths_count; i++) free(s->skip_paths[i]);
    free(s->skip_names);
    free(s->skip_files);
    free(s->skip_exts);
    free(s->skip_paths);
    free(s);
}

// ── Configuration setters ──────────────────────────────

void cscanner_set_skip_names(CFileScanner* s, const char* const* names, uint32_t count) {
    if (!s || !names || count == 0) return;
    if (count > MAX_SKIP_NAMES) count = MAX_SKIP_NAMES;
    s->skip_names = (char**)calloc(count, sizeof(char*));
    for (uint32_t i = 0; i < count; i++) {
        s->skip_names[i] = cstr_copy(names[i]);
    }
    s->skip_names_count = count;
}

void cscanner_set_skip_files(CFileScanner* s, const char* const* files, uint32_t count) {
    if (!s || !files || count == 0) return;
    if (count > MAX_SKIP_FILES) count = MAX_SKIP_FILES;
    s->skip_files = (char**)calloc(count, sizeof(char*));
    for (uint32_t i = 0; i < count; i++) {
        s->skip_files[i] = cstr_copy(files[i]);
    }
    s->skip_files_count = count;
}

void cscanner_set_skip_extensions(CFileScanner* s, const char* const* exts, uint32_t count) {
    if (!s || !exts || count == 0) return;
    if (count > MAX_SKIP_EXTS) count = MAX_SKIP_EXTS;
    s->skip_exts = (char**)calloc(count, sizeof(char*));
    for (uint32_t i = 0; i < count; i++) {
        s->skip_exts[i] = cstr_copy(exts[i]);
    }
    s->skip_exts_count = count;
}

void cscanner_set_skip_paths(CFileScanner* s, const char* const* paths, uint32_t count) {
    if (!s || !paths || count == 0) return;
    if (count > MAX_SKIP_PATHS) count = MAX_SKIP_PATHS;
    s->skip_paths = (char**)calloc(count, sizeof(char*));
    for (uint32_t i = 0; i < count; i++) {
        s->skip_paths[i] = cstr_copy(paths[i]);
    }
    s->skip_paths_count = count;
}

void cscanner_set_max_depth(CFileScanner* s, int max_depth) {
    if (s) s->max_depth = max_depth;
}

void cscanner_set_follow_symlinks(CFileScanner* s, bool follow) {
    if (s) s->follow_symlinks = follow;
}

// ── Skip checking ───────────────────────────────────────

static bool should_skip(CFileScanner* s, const FTSENT* ent) {
    const char* name = ent->fts_name;
    const char* path = ent->fts_path;

    // Skip dot and dot-dot
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
        return true;
    }

    // Check skip names (directory names to skip)
    for (uint32_t i = 0; i < s->skip_names_count; i++) {
        if (str_eq_nocase(name, s->skip_names[i])) return true;
    }

    // Check skip files (file basenames to skip)
    for (uint32_t i = 0; i < s->skip_files_count; i++) {
        if (str_eq_nocase(name, s->skip_files[i])) return true;
    }

    // Check skip extensions
    const char* ext = file_extension(name);
    if (ext) {
        for (uint32_t i = 0; i < s->skip_exts_count; i++) {
            if (str_eq_nocase(ext, s->skip_exts[i])) return true;
        }
    }

    // Check skip paths (path suffixes)
    for (uint32_t i = 0; i < s->skip_paths_count; i++) {
        if (path_has_skip_suffix(path, s->skip_paths[i])) return true;
    }

    return false;
}

// ── Scan ─────────────────────────────────────────────────

uint32_t cscanner_scan(CFileScanner* s, CIndex* idx, const char* root_path,
                       cscanner_progress_cb progress_cb,
                       cscanner_error_cb error_cb,
                       void* user_data) {
    if (!s || !idx || !root_path) return 0;

    char* path_argv[2];
    path_argv[0] = (char*)root_path;  // fts_open takes char* const*, won't modify
    path_argv[1] = NULL;

    int fts_options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV;
    if (!s->follow_symlinks) {
        // FTS_PHYSICAL already prevents symlink following
    }

    FTS* fts = fts_open(path_argv, fts_options, NULL);
    if (!fts) {
        if (error_cb) error_cb(root_path, "fts_open failed", user_data);
        return 0;
    }

    uint32_t files_scanned = 0;
    uint32_t dirs_scanned = 0;
    uint32_t skipped = 0;
    uint32_t errors = 0;

    FTSENT* ent;
    while ((ent = fts_read(fts)) != NULL) {
        // Check for errors on this entry
        if (ent->fts_info == FTS_ERR || ent->fts_info == FTS_DNR) {
            errors++;
            if (error_cb) {
                char reason[256];
                snprintf(reason, sizeof(reason), "%s", strerror(ent->fts_errno));
                error_cb(ent->fts_path, reason, user_data);
            }
            // fts_set to skip this directory if it couldn't be read
            if (ent->fts_info == FTS_DNR) {
                fts_set(fts, ent, FTS_SKIP);
            }
            continue;
        }

        // Only process regular files, directories, and symlinks
        bool is_dir = (ent->fts_info == FTS_D || ent->fts_info == FTS_DC || ent->fts_info == FTS_DOT);
        bool is_file = (ent->fts_info == FTS_F);
        bool is_symlink = (ent->fts_info == FTS_SL || ent->fts_info == FTS_SLNONE);

        if (!is_dir && !is_file && !is_symlink) continue;

        // Skip symlinks if not following
        if (is_symlink && !s->follow_symlinks) continue;

        // Check depth limit
        if (s->max_depth >= 0 && ent->fts_level > s->max_depth) {
            if (is_dir) fts_set(fts, ent, FTS_SKIP);
            continue;
        }

        // Check skip patterns
        if (should_skip(s, ent)) {
            skipped++;
            if (is_dir) fts_set(fts, ent, FTS_SKIP);
            continue;
        }

        // Get stat info
        struct stat* st = ent->fts_statp;
        int64_t file_size = 0;
        int64_t created_at = 0;
        int64_t modified_at = 0;
        bool is_directory = false;
        bool is_regular = false;

        if (st) {
            file_size = (int64_t)st->st_size;
            // macOS: st_birthtime is the creation time
#ifdef __APPLE__
            created_at = (int64_t)st->st_birthtime;
#else
            created_at = (int64_t)st->st_ctime;
#endif
            modified_at = (int64_t)st->st_mtime;
            is_directory = S_ISDIR(st->st_mode);
            is_regular = S_ISREG(st->st_mode);
        }

        // If stat failed, infer from fts_info
        if (!st) {
            is_directory = is_dir;
            is_regular = is_file;
        }

        // Only index regular files and directories (skip symlinks, sockets, etc.)
        if (!is_regular && !is_directory) continue;

        // Extract parent path from fts_path
        // fts_path is the full path from root; we need dirname
        const char* full_path = ent->fts_path;
        const char* file_name = ent->fts_name;

        // Build parent path by copying full_path and truncating at the last '/'
        char parent_path[4096];
        size_t plen = strlen(full_path);
        size_t nlen = strlen(file_name);
        size_t parent_len = plen - nlen;
        if (parent_len > 0 && full_path[parent_len - 1] == '/') parent_len--;
        if (parent_len >= sizeof(parent_path)) parent_len = sizeof(parent_path) - 1;
        if (parent_len > 0) {
            memcpy(parent_path, full_path, parent_len);
            parent_path[parent_len] = '\0';
        } else {
            parent_path[0] = '/';
            parent_path[1] = '\0';
        }

        // Insert into CIndex (uses the index mutex internally)
        cindex_insert(idx,
                      file_name,           // name (NFC-normalized by caller or here?)
                      file_name,           // original_name (same as name for now)
                      full_path,           // path
                      parent_path,         // parent_path
                      is_directory,
                      is_directory ? 0 : file_size,
                      created_at,
                      modified_at);

        if (is_directory) {
            dirs_scanned++;
        } else {
            files_scanned++;
            // Progress callback every N files
            if (files_scanned % PROGRESS_INTERVAL == 0 && progress_cb) {
                if (!progress_cb(files_scanned, dirs_scanned, user_data)) {
                    // User requested cancellation
                    fts_close(fts);
                    return files_scanned;
                }
            }
        }
    }

    fts_close(fts);

    // Final progress callback with total count
    if (progress_cb) {
        progress_cb(files_scanned, dirs_scanned, user_data);
    }

    return files_scanned;
}
