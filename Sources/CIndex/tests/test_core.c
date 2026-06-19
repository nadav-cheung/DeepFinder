// test_core.c — Pure-C test suite for libdfindex (no Swift, no test framework).
//
// Build & run:  cd Sources/CIndex && make test
// Exits 0 on success, 1 on any failure.
#include "dfindex.h"   // umbrella

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ── Tiny test harness ────────────────────────────────────
static int g_fail = 0;

#define TEST(name) static void name(void)
#define RUN(t) do { fputs("  " #t " ... ", stderr); t(); fputs("ok\n", stderr); } while (0)

#define EXPECT(cond, ...) do {                                  \
    if (!(cond)) {                                              \
        g_fail++;                                               \
        fputs("FAIL\n", stderr);                                \
        fprintf(stderr, "    %s:%d: ", __FILE__, __LINE__);     \
        fprintf(stderr, __VA_ARGS__);                           \
        fputc('\n', stderr);                                    \
        return;                                                 \
    }                                                           \
} while (0)

// ── Helpers ──────────────────────────────────────────────
static CIndex* make_index_with(const char* const* names, const char* const* paths, int n) {
    CIndex* idx = cindex_create();
    for (int i = 0; i < n; i++) {
        cindex_insert(idx, names[i], names[i], paths[i], "/",
                      false, 100, 1000, 2000);
    }
    return idx;
}

// True iff `id` is present in the result array.
static bool id_in_results(uint32_t* ids, uint32_t count, uint32_t id) {
    for (uint32_t i = 0; i < count; i++) if (ids[i] == id) return true;
    return false;
}

// ── Tests ────────────────────────────────────────────────

TEST(test_prefix_search) {
    const char* names[] = {"readme.md", "report.pdf", "notes.txt"};
    const char* paths[] = {"/a/readme.md", "/a/report.pdf", "/a/notes.txt"};
    CIndex* idx = make_index_with(names, paths, 3);

    uint32_t* ids = NULL;
    uint32_t n = cindex_search_prefix(idx, "read", &ids, 0);
    EXPECT(n == 1, "prefix 'read' expected 1 result, got %u", n);
    uint32_t readme_id = ids[0];
    free(ids);

    // No match.
    n = cindex_search_prefix(idx, "zzz", &ids, 0);
    EXPECT(n == 0, "prefix 'zzz' expected 0 results, got %u", n);
    free(ids);

    cindex_destroy(idx);
    (void)readme_id;
}

TEST(test_substring_trigram) {
    const char* names[] = {"readme.md", "ADMET_REFERENCE.md", "todo.txt"};
    const char* paths[] = {"/a/readme.md", "/a/ADMET.md", "/a/todo.txt"};
    CIndex* idx = make_index_with(names, paths, 3);

    // True substring, not prefix: "adme" matches readme + ADMET (case-insensitive).
    uint32_t* ids = NULL;
    uint32_t n = cindex_search_substring(idx, "adme", &ids, 0);
    EXPECT(n == 2, "substring 'adme' expected 2, got %u", n);
    free(ids);

    // Case-insensitive suffix.
    n = cindex_search_substring(idx, "MD", &ids, 0);
    EXPECT(n >= 2, "substring 'MD' expected >=2, got %u", n);
    free(ids);

    // No match.
    n = cindex_search_substring(idx, "zzzznone", &ids, 0);
    EXPECT(n == 0, "substring 'zzzznone' expected 0, got %u", n);
    free(ids);

    cindex_destroy(idx);
}

TEST(test_substring_cjk) {
    // Byte-level trigrams => CJK works natively.
    const char* names[] = {"张楠报告.pdf", "测试文件.txt"};
    const char* paths[] = {"/a/张楠报告.pdf", "/a/测试文件.txt"};
    CIndex* idx = make_index_with(names, paths, 2);

    uint32_t* ids = NULL;
    uint32_t n = cindex_search_substring(idx, "张楠", &ids, 0);
    EXPECT(n == 1, "CJK '张楠' expected 1, got %u", n);
    free(ids);

    n = cindex_search_substring(idx, "报告", &ids, 0);
    EXPECT(n == 1, "CJK '报告' expected 1, got %u", n);
    free(ids);

    n = cindex_search_substring(idx, "测试", &ids, 0);
    EXPECT(n == 1, "CJK '测试' expected 1, got %u", n);
    free(ids);

    cindex_destroy(idx);
}

TEST(test_short_query_linear_scan) {
    // Queries < 3 bytes fall back to arena linear scan.
    const char* names[] = {"ab.txt", "cab.log"};
    const char* paths[] = {"/a/ab.txt", "/a/cab.log"};
    CIndex* idx = make_index_with(names, paths, 2);

    uint32_t* ids = NULL;
    uint32_t n = cindex_search_substring(idx, "ab", &ids, 0);
    EXPECT(n == 2, "short 'ab' expected 2, got %u", n);
    free(ids);

    // Empty query must not crash.
    n = cindex_search_substring(idx, "", &ids, 0);
    EXPECT(n == 0, "empty query expected 0, got %u", n);
    free(ids);

    cindex_destroy(idx);
}

TEST(test_remove) {
    CIndex* idx = cindex_create();
    uint32_t id = cindex_insert(idx, "readme.md", "readme.md", "/a/readme.md",
                                "/", false, 100, 1000, 2000);

    uint32_t* ids = NULL;
    uint32_t n = cindex_search_substring(idx, "readme", &ids, 0);
    free(ids);
    EXPECT(n == 1, "before remove expected 1, got %u", n);

    bool removed = cindex_remove(idx, id);
    EXPECT(removed, "cindex_remove returned false for existing id");

    n = cindex_search_substring(idx, "readme", &ids, 0);
    free(ids);
    EXPECT(n == 0, "after remove expected 0, got %u", n);

    cindex_destroy(idx);
}

TEST(test_standalone_ctrigram) {
    // Use CTrigramIndex directly, independent of CIndex.
    CTrigramIndex* ti = ctrigram_create();
    ctrigram_insert(ti, "readme.txt", 10);
    ctrigram_insert(ti, "report.pdf", 20);
    ctrigram_insert(ti, "notes.txt", 30);

    EXPECT(ctrigram_doc_count(ti) == 3, "doc_count expected 3, got %u",
           ctrigram_doc_count(ti));

    uint32_t* ids = NULL;
    uint32_t n = ctrigram_search(ti, "adme", &ids, 0);  // matches readme only
    EXPECT(n == 1, "standalone 'adme' expected 1, got %u", n);
    bool ok = (n == 1) && id_in_results(ids, n, 10);
    free(ids);
    EXPECT(ok, "standalone 'adme' did not return id 10");

    // Remove.
    bool removed = ctrigram_remove(ti, 10);
    EXPECT(removed, "ctrigram_remove(10) returned false");
    n = ctrigram_search(ti, "adme", &ids, 0);
    free(ids);
    EXPECT(n == 0, "after remove 'adme' expected 0, got %u", n);

    ctrigram_destroy(ti);
}

TEST(test_upsert_update) {
    // Re-inserting the same path updates the record.
    CIndex* idx = cindex_create();
    cindex_insert(idx, "old.txt", "old.txt", "/a/x.txt", "/", false, 1, 1, 1);
    cindex_insert(idx, "new.txt", "new.txt", "/a/x.txt", "/", false, 1, 1, 1);

    uint32_t* ids = NULL;
    uint32_t n = cindex_search_substring(idx, "old", &ids, 0);
    free(ids);
    EXPECT(n == 0, "after upsert 'old' should be gone, got %u", n);

    n = cindex_search_substring(idx, "new", &ids, 0);
    free(ids);
    EXPECT(n == 1, "after upsert 'new' expected 1, got %u", n);

    cindex_destroy(idx);
}

// ── Main ─────────────────────────────────────────────────
int main(void) {
    fputs("libdfindex test suite\n", stderr);

    RUN(test_prefix_search);
    RUN(test_substring_trigram);
    RUN(test_substring_cjk);
    RUN(test_short_query_linear_scan);
    RUN(test_remove);
    RUN(test_standalone_ctrigram);
    RUN(test_upsert_update);

    fprintf(stderr, "\n%d passed, %d failed\n", 7 - g_fail, g_fail);
    return g_fail == 0 ? 0 : 1;
}
