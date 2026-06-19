// demo.c — Standalone macOS C program demonstrating libdfindex
// Build: cd Sources/CIndex && make demo
// Usage: ./dfdemo <dir> <query>
#include "../include/CIndex.h"
#include "../include/CParallelScanner.h"
#include <stdio.h>
#include <stdlib.h>

static bool progress_cb(uint32_t files, uint32_t dirs, uint32_t skipped,
                        void* user_data) {
    (void)user_data;
    fprintf(stderr, "\r  %u files, %u dirs, %u skipped",
            files, dirs, skipped);
    fflush(stderr);
    return true;
}

static void error_cb(const char* path, const char* reason, void* user_data) {
    (void)user_data;
    fprintf(stderr, "\rerror: %s: %s\n", path, reason);
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: dfdemo <dir> <query>\n");
        return 1;
    }

    const char* root  = argv[1];
    const char* query = argv[2];

    CIndex* idx = cindex_create();
    if (!idx) {
        fprintf(stderr, "error: cindex_create failed\n");
        return 1;
    }

    CParallelScanner* scanner = cpscanner_create();
    if (!scanner) {
        fprintf(stderr, "error: cpscanner_create failed\n");
        cindex_destroy(idx);
        return 1;
    }

    const char* skip_names[] = {".git", "node_modules"};
    cpscanner_set_skip_names(scanner, skip_names, 2);

    const char* skip_files[] = {".DS_Store"};
    cpscanner_set_skip_files(scanner, skip_files, 1);

    fprintf(stderr, "Scanning %s ...\n", root);
    uint32_t scanned = cpscanner_scan(scanner, idx, root,
                                       progress_cb, error_cb, NULL);
    fprintf(stderr, "\nScanned %u files total.\n", scanned);

    fprintf(stderr, "Searching for \"%s\" ...\n", query);
    uint32_t* ids = NULL;
    uint32_t count = cindex_search_substring(idx, query, &ids, 0);
    fprintf(stderr, "Found %u matches.\n", count);

    for (uint32_t i = 0; i < count; i++) {
        const char* path = cindex_get_path(idx, ids[i]);
        if (path) printf("%s\n", path);
    }

    free(ids);
    cpscanner_destroy(scanner);
    cindex_destroy(idx);
    return 0;
}
