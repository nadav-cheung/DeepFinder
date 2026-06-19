# Index Engine Refactor — Phase 0 (Bug Fixes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two latent CIndex bugs — B1 (path hash table never resizes → probe-chain growth / infinite-loop risk above ~128K paths) and B2 (`find_meta_by_id` is O(n) linear scan → every `cindex_get_*` call scans the whole metadata array) — with full TDD coverage.

**Architecture:** Both fixes are internal to the C backend (`Sources/CIndex/src/CIndex.c`). B1 adds a `path_count` field (replacing an O(cap)-per-insert recount) and a `path_hash_resize()` rehash on load-factor >0.5. B2 adds an `id_index[]` direct-mapped array (id → meta_idx) maintained through insert/remove/swap-with-last, making `find_meta_by_id` O(1). A test-only `cindex_create_with_path_cap()` constructor lets resize logic be exercised at small scale. No public API changes except a thin `InMemoryIndex.record(for:)` convenience (needed to benchmark B2).

**Tech Stack:** C (CIndex backend), Swift (InMemoryIndex actor wrapper), Swift Testing (`@Test` / `#expect` / `ContinuousClock`), zero external deps.

**Scope:** This plan covers **Phase 0 only**. Phases P1–P5 of the refactor (single-alloc `DFileMeta` layout, string dedup, binary `index.bin` persistence replacing SQLite, SQLite→binary migration, integration) are deferred to separate `writing-plans` passes — one per phase — after P0 ships and is validated. See "Subsequent Phases" at the end.

**Spec:** `docs/superpowers/specs/2026-06-20-index-engine-refactor-design.md` §1.2, §3.4, §3.5, §4.2, §4.3, §9 (P0).

---

## File Structure

- **Modify:** `Sources/CIndex/src/CIndex.c` — both fixes live here (path hash resize + id_index)
- **Modify:** `Sources/CIndex/include/CIndex.h` — declare `cindex_create_with_path_cap`
- **Modify:** `Sources/Index/InMemoryIndex.swift` — add test init + `record(for:)` wrapper
- **Create:** `Tests/IndexTests/CIndexHashResizeTests.swift` — B1 regression test
- **Create:** `Tests/IndexTests/CIndexLookupTests.swift` — B2 correctness + O(1) perf test

All C changes are behind the existing `InMemoryIndex` Swift API; no DaemonMain/FSEventWatcher/GUI changes in P0.

---

## Task 1: Add test-configurable path-hash capacity constructor

**Why first:** the B1 regression test must force a resize at small scale, which requires creating an index with a tiny path-hash capacity. This task adds that capability with no behavior change for the default path.

**Files:**
- Modify: `Sources/CIndex/include/CIndex.h:14` (after `cindex_create` declaration)
- Modify: `Sources/CIndex/src/CIndex.c:99` (`cindex_create`) and add new function
- Test: `Tests/IndexTests/CIndexHashResizeTests.swift` (new)

- [ ] **Step 1: Declare the new constructor in the header**

In `Sources/CIndex/include/CIndex.h`, replace:

```c
// Create an empty index. Free with cindex_destroy().
CIndex* cindex_create(void);
```

with:

```c
// Create an empty index. Free with cindex_destroy().
CIndex* cindex_create(void);

// Create an empty index with a custom initial path-hash capacity (rounded up
// to a power of two, minimum 16). Primarily for testing resize logic at small
// scale; production should use cindex_create().
CIndex* cindex_create_with_path_cap(uint32_t path_cap);
```

- [ ] **Step 2: Write a sanity test that uses the small-cap constructor**

Create `Tests/IndexTests/CIndexHashResizeTests.swift`:

```swift
import Testing
import Foundation
@testable import DeepFinderIndex

@Suite("CIndex path hash")
struct CIndexHashResizeTests {

    @Test("Small-cap constructor builds a working index")
    func smallCapConstructorWorks() async {
        let index = InMemoryIndex(pathHashCap: 16)
        await index.insert(
            name: "hello.txt",
            path: "/tmp/hello.txt",
            parentPath: "/tmp",
            isDirectory: false,
            extension: "txt"
        )
        let results = await index.searchSubstring(query: "hello")
        #expect(results.count == 1)
        #expect(results.first?.path == "/tmp/hello.txt")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails (constructor not yet implemented)**

Run: `swift test --filter CIndexHashResizeTests`
Expected: FAIL — compiler error `'InMemoryIndex' has no member `init(pathHashCap:)'` (and `cindex_create_with_path_cap` unresolved). This confirms the test exercises the new API.

- [ ] **Step 4: Implement `cindex_create_with_path_cap` and refactor `cindex_create`**

In `Sources/CIndex/src/CIndex.c`, replace the existing `cindex_create` (lines 99–119) with:

```c
CIndex* cindex_create_with_path_cap(uint32_t path_cap) {
    CIndex* idx = (CIndex*)calloc(1, sizeof(CIndex));
    if (!idx) return NULL;

    pthread_mutex_init(&idx->mutex, NULL);

    idx->name_cap = NAME_INIT_CAP;
    idx->names = (NameSlot*)calloc(idx->name_cap, sizeof(NameSlot));

    idx->meta_cap = META_INIT_CAP;
    idx->metas = (FileMeta*)calloc(idx->meta_cap, sizeof(FileMeta));

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
```

- [ ] **Step 5: Add the Swift test init**

In `Sources/Index/InMemoryIndex.swift`, after the existing `public init()` (line 15–17), add:

```swift
    /// Create an index with a custom initial path-hash capacity. For testing
    /// resize logic at small scale; production uses `init()`.
    internal init(pathHashCap: UInt32) {
        _idx = cindex_create_with_path_cap(pathHashCap)
    }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter CIndexHashResizeTests`
Expected: PASS — `smallCapConstructorWorks` green.

- [ ] **Step 7: Commit**

```bash
git add Sources/CIndex/src/CIndex.c Sources/CIndex/include/CIndex.h Sources/Index/InMemoryIndex.swift Tests/IndexTests/CIndexHashResizeTests.swift
git commit -m "feat(CIndex): add test-configurable path-hash capacity constructor"
```

---

## Task 2: B1 — implement path-hash resize

**Files:**
- Modify: `Sources/CIndex/src/CIndex.c` — struct field, resize fn, `path_insert`, `path_remove`
- Test: `Tests/IndexTests/CIndexHashResizeTests.swift` (add test)

- [ ] **Step 1: Write the failing resize regression test**

Append to `Tests/IndexTests/CIndexHashResizeTests.swift` (inside the `struct`):

```swift
    @Test("Path hash resizes past capacity without hang or loss", .bug)
    func pathHashResizesBeyondCapacity() async {
        let index = InMemoryIndex(pathHashCap: 16)

        // Insert 200 unique paths. Load factor crosses 0.5 at 9 entries, so the
        // 16-slot table must resize repeatedly (16→32→64→128→256). Under the
        // unfixed code the table fills at 16 entries and the 17th insert hangs
        // (probe loop wraps forever) — that hang IS the bug.
        for i in 0..<200 {
            await index.insert(
                name: "file_\(i).txt",
                path: "/tmp/resize/\(i)/file_\(i).txt",
                parentPath: "/tmp/resize/\(i)",
                isDirectory: false,
                extension: "txt"
            )
        }
        let total = await index.totalRecords
        #expect(total == 200, "all 200 records must survive resize")

        // Upsert an existing path: path_lookup must still find it post-resize,
        // updating in place rather than duplicating.
        await index.insert(
            name: "file_0.txt",
            path: "/tmp/resize/0/file_0.txt",
            parentPath: "/tmp/resize/0",
            isDirectory: false,
            size: 999,
            extension: "txt"
        )
        #expect(await index.totalRecords == 200, "upsert must not duplicate")

        // Remove by path: path_remove must still work post-resize.
        let removed = await index.removeByPath("/tmp/resize/1/file_1.txt")
        #expect(removed == true)
        #expect(await index.totalRecords == 199)
    }
```

- [ ] **Step 2: Run the test to verify it fails (confirms the bug)**

Run: `swift test --filter CIndexHashResizeTests`
Expected: **The test hangs** (it never completes). This is the bug manifesting — the 17th insert enters an infinite probe loop once the 16-slot table is full. Kill the run after ~10 seconds (Ctrl-C). The hang confirms B1.

- [ ] **Step 3: Add a `path_count` field to track load factor in O(1)**

In `Sources/CIndex/src/CIndex.c`, in `struct CIndex` (the path-hash section, around line 55–57), replace:

```c
    // Path → meta index hash
    PathSlot* path_hash;
    uint32_t  path_hash_mask;  // capacity - 1
```

with:

```c
    // Path → meta index hash
    PathSlot* path_hash;
    uint32_t  path_hash_mask;  // capacity - 1
    uint32_t  path_count;      // number of used slots (for O(1) load-factor check)
```

(`calloc` in `cindex_create_with_path_cap` already zero-initializes `path_count`.)

- [ ] **Step 4: Implement `path_hash_resize`**

In `Sources/CIndex/src/CIndex.c`, immediately before `static void path_insert` (line 158), add:

```c
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
```

- [ ] **Step 5: Rewrite `path_insert` to resize + maintain `path_count`**

In `Sources/CIndex/src/CIndex.c`, replace the entire `path_insert` function (lines 158–180) with:

```c
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
    idx->path_hash[h].path = strdup(path);
    idx->path_hash[h].meta_idx = meta_idx;
    idx->path_hash[h].used = true;
    idx->path_count++;
}
```

- [ ] **Step 6: Decrement `path_count` in `path_remove`**

In `Sources/CIndex/src/CIndex.c`, in `path_remove` (lines 182–196), replace:

```c
        if (strcmp(slot->path, path) == 0) {
            free(slot->path);
            slot->path = NULL;
            slot->used = false;
            return;
        }
```

with:

```c
        if (strcmp(slot->path, path) == 0) {
            free(slot->path);
            slot->path = NULL;
            slot->used = false;
            idx->path_count--;
            return;
        }
```

- [ ] **Step 7: Run the resize test to verify it passes**

Run: `swift test --filter CIndexHashResizeTests`
Expected: PASS — both `smallCapConstructorWorks` and `pathHashResizesBeyondCapacity` green. No hang.

- [ ] **Step 8: Commit**

```bash
git add Sources/CIndex/src/CIndex.c Tests/IndexTests/CIndexHashResizeTests.swift
git commit -m "fix(CIndex): resize path hash on load factor >0.5 (B1)

Previously path_insert recounted used slots in O(cap) and left the resize
body empty, so above ~128K unique paths probe chains grew unboundedly and
a full table caused an infinite probe loop. Now: O(1) path_count field,
path_hash_resize doubles+rehashes at load factor >0.5."
```

---

## Task 3: B2 — id→meta direct map (O(1) `find_meta_by_id`)

**Files:**
- Modify: `Sources/CIndex/src/CIndex.c` — struct fields, `id_index_ensure`, `find_meta_by_id`, insert/remove bookkeeping, destroy
- Modify: `Sources/Index/InMemoryIndex.swift` — add `record(for:)`
- Test: `Tests/IndexTests/CIndexLookupTests.swift` (new)

- [ ] **Step 1: Add the `record(for:)` Swift wrapper (needed by the B2 test)**

In `Sources/Index/InMemoryIndex.swift`, immediately after the private `_lookup` method (line 400, before the closing `}` of the actor), add:

```swift
    /// Look up a single record by ID. O(1) (backed by the C id→meta direct map).
    public func record(for id: UInt32) -> FileRecord? {
        _lookup(id: id)
    }
```

- [ ] **Step 2: Write the failing correctness test (bookkeeping after swap-with-last)**

Create `Tests/IndexTests/CIndexLookupTests.swift`:

```swift
import Testing
import Foundation
@testable import DeepFinderIndex

@Suite("CIndex id lookup")
struct CIndexLookupTests {

    @Test("id→meta lookup correct after swap-with-last removal", .bug)
    func lookupCorrectAfterSwapRemoval() async {
        let index = InMemoryIndex()
        // cindex_insert assigns auto-increment ids 1..4 in insertion order.
        for n in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            await index.insert(
                name: n,
                path: "/tmp/\(n)",
                parentPath: "/tmp",
                isDirectory: false,
                extension: "txt"
            )
        }

        // Remove id 2 (b.txt). cindex_remove swaps the last record (d.txt, id 4)
        // into the freed slot — the id_index must track that move.
        await index.remove(id: 2)

        // d.txt (id 4) relocated to a new array index; must still resolve.
        #expect(await index.record(for: 4)?.path == "/tmp/d.txt")
        #expect(await index.record(for: 1)?.path == "/tmp/a.txt")
        #expect(await index.record(for: 3)?.path == "/tmp/c.txt")
        // Removed id resolves to nil.
        #expect(await index.record(for: 2) == nil)
        // Non-existent id resolves to nil.
        #expect(await index.record(for: 999) == nil)
    }
}
```

- [ ] **Step 3: Write the failing O(1) performance test**

Append to `Tests/IndexTests/CIndexLookupTests.swift` (inside the `struct`):

```swift
    @Test("get-by-id is O(1) on a 50K index")
    func lookupIsO1() async {
        // buildIndex inserts 50K records; C assigns ids 1..50000 in order.
        let index = await PerformanceFixtures.buildIndex(count: 50_000)
        let ids: [UInt32] = stride(from: 1, to: 50_000, by: 5).map { UInt32($0) }

        // Warm up (first call may fault in pages).
        for id in ids.prefix(100) { _ = await index.record(for: id) }

        let start = ContinuousClock.now
        for id in ids { _ = await index.record(for: id) }
        let ms = (ContinuousClock.now - start) / .milliseconds(1)

        // O(1): ~tens of µs total. O(n) at 50K: 10K lookups × 50K iterations
        // each → many seconds. 50ms sits >1000× above O(1) and >50× below O(n),
        // so it cleanly separates the two regardless of machine speed.
        #expect(ms < 50, "id lookup must be O(1); got \(ms)ms for \(ids.count) lookups")
        print("[Benchmark] get-by-id \(ids.count)× on 50K index: \(String(format: "%.2f", ms))ms")
    }
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --filter CIndexLookupTests`
Expected:
- `lookupCorrectAfterSwapRemoval`: **FAIL** — `record(for:)` returns the wrong record after removal (or nil for id 4), because the linear-scan `find_meta_by_id` still works for correctness BUT... note: the linear scan is actually *correct* here, so this test may PASS against old code. That's expected — this test guards the **new** id_index bookkeeping, not the original bug. The original bug is caught by the perf test below.
- `lookupIsO1`: **FAIL** — `ms` exceeds 50ms because `find_meta_by_id` linear-scans 50K entries per lookup (10K lookups × 50K = 500M iterations).

If `lookupIsO1` does not fail (i.e. passes), the machine is very fast — lower the index size to 50_000 (already) and re-check; the linear scan at 50K reliably exceeds 50ms for 10K lookups.

- [ ] **Step 5: Add `id_index` fields to the struct**

In `Sources/CIndex/src/CIndex.c`, in `struct CIndex` (the metadata-array section, around line 50–53), replace:

```c
    // Dense metadata array
    FileMeta* metas;
    uint32_t  meta_count;
    uint32_t  meta_cap;
```

with:

```c
    // Dense metadata array
    FileMeta* metas;
    uint32_t  meta_count;
    uint32_t  meta_cap;

    // id → meta_idx direct map (O(1) lookup). UINT32_MAX = absent.
    // Lazily allocated; grows with next_id. ids never reuse (next_id only grows).
    uint32_t* id_index;
    uint32_t  id_index_cap;
```

- [ ] **Step 6: Add `id_index_ensure` helper**

In `Sources/CIndex/src/CIndex.c`, immediately before `static FileMeta* find_meta_by_id` (line 483), add:

```c
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
```

- [ ] **Step 7: Rewrite `find_meta_by_id` to O(1)**

In `Sources/CIndex/src/CIndex.c`, replace `find_meta_by_id` (lines 483–488) with:

```c
static FileMeta* find_meta_by_id(const CIndex* idx, uint32_t id) {
    if (id == 0 || id >= idx->id_index_cap) return NULL;
    uint32_t mi = idx->id_index[id];
    if (mi >= idx->meta_count) return NULL;  // UINT32_MAX or stale
    FileMeta* m = (FileMeta*)&idx->metas[mi];
    return m->id == id ? m : NULL;
}
```

(`mi >= meta_count` covers the `UINT32_MAX` absent case since `meta_count` is always far below `UINT32_MAX`. The `m->id == id` check defends against stale mappings; a mismatch returns NULL rather than silently returning the wrong record.)

- [ ] **Step 8: Register new ids in `cindex_insert`**

In `Sources/CIndex/src/CIndex.c`, in `cindex_insert`'s new-record path, replace (lines 302–306):

```c
    uint32_t meta_idx = idx->meta_count++;
    uint32_t id = idx->next_id++;

    FileMeta* m = &idx->metas[meta_idx];
    m->id = id;
```

with:

```c
    uint32_t meta_idx = idx->meta_count++;
    uint32_t id = idx->next_id++;

    id_index_ensure(idx, id);
    if (idx->id_index) idx->id_index[id] = meta_idx;

    FileMeta* m = &idx->metas[meta_idx];
    m->id = id;
```

- [ ] **Step 9: Maintain `id_index` through swap-with-last in `cindex_remove_locked`**

In `Sources/CIndex/src/CIndex.c`, in `cindex_remove_locked` (the swap block, lines 361–367), replace:

```c
            // Compact metas array (swap with last)
            if (i < idx->meta_count - 1) {
                idx->metas[i] = idx->metas[idx->meta_count - 1];
                // Update path hash for the swapped entry
                path_insert(idx, idx->metas[i].path, i);
            }
            idx->meta_count--;
```

with:

```c
            // Clear the removed id from the direct map.
            if (idx->id_index && id < idx->id_index_cap) {
                idx->id_index[id] = UINT32_MAX;
            }

            // Compact metas array (swap with last)
            if (i < idx->meta_count - 1) {
                idx->metas[i] = idx->metas[idx->meta_count - 1];
                // The swapped record (now at index i) must point its id here.
                if (idx->id_index && idx->metas[i].id < idx->id_index_cap) {
                    idx->id_index[idx->metas[i].id] = i;
                }
                // Update path hash for the swapped entry
                path_insert(idx, idx->metas[i].path, i);
            }
            idx->meta_count--;
```

- [ ] **Step 10: Free `id_index` in `cindex_destroy`**

In `Sources/CIndex/src/CIndex.c`, in `cindex_destroy`, replace (lines 133–135):

```c
    free(idx->names);
    free(idx->metas);
    free(idx->path_hash);
```

with:

```c
    free(idx->names);
    free(idx->metas);
    free(idx->path_hash);
    free(idx->id_index);
```

- [ ] **Step 11: Run the B2 tests to verify they pass**

Run: `swift test --filter CIndexLookupTests`
Expected: PASS — `lookupCorrectAfterSwapRemoval` and `lookupIsO1` both green; the benchmark print shows single-digit ms (or less) for 10K lookups.

- [ ] **Step 12: Commit**

```bash
git add Sources/CIndex/src/CIndex.c Sources/Index/InMemoryIndex.swift Tests/IndexTests/CIndexLookupTests.swift
git commit -m "fix(CIndex): O(1) id→meta direct map (B2)

find_meta_by_id was an O(n) linear scan of the metadata array — every
cindex_get_* (path/name/size/...) paid it, so a search returning K results
over N records cost K*N scans. Now an id_index[] direct-mapped array,
maintained through insert and swap-with-last removal, makes lookups O(1)."
```

---

## Task 4: Full regression + verification

**Files:** none modified (verification only)

- [ ] **Step 1: Run the full test suite (do not use multi-suite --filter — it crashes Swift Testing)**

Run: `./scripts/run-tests.sh`
Expected: ALL tests pass, including existing `InMemoryIndexTests`, `CTrigramIndexTests`, `FileRecordTests`, `SearchTests`, `DaemonTests`, plus the new P0 tests.

- [ ] **Step 2: Verify the build is clean for all targets**

Run: `swift build`
Expected: builds with no errors or warnings introduced by P0.

- [ ] **Step 3: Spot-check no public API regression**

Confirm `InMemoryIndex()` (default init) still works and the daemon/CLI search path is unaffected — the two fixes are internal to CIndex. Manually (optional): `swift run deepfinder "test"` from a running daemon and confirm normal results.

- [ ] **Step 4: Final commit if any verification surfaced changes**

(Usually none — this task is verification. Only commit if a fix was needed.)

```bash
git status   # confirm clean
```

---

## Self-Review

**Spec coverage (§1.2, §3.4, §3.5, §4.2, §4.3, §9 P0):**
- B1 path hash resize (§3.5, §4.3) → Task 2 ✓
- B2 id→idx map (§3.4, §4.2) → Task 3 ✓
- Test strategy P0 (§9: hash-resize test, O(1) measure) → Tasks 2 & 3 ✓
- No public API change beyond `record(for:)` convenience → noted ✓

**Placeholder scan:** none — every code step contains complete C/Swift. The `.bug` trait on the two regression tests is a Swift Testing built-in (links a known bug); if the toolchain rejects it, drop the trait — the test still works.

**Type/signature consistency:**
- `cindex_create_with_path_cap(uint32_t)` declared (Task 1 Step 1) and defined (Task 1 Step 4) — match ✓
- `InMemoryIndex(pathHashCap: UInt32)` (Task 1 Step 5) used by Task 2 Step 1 ✓
- `record(for: UInt32) -> FileRecord?` (Task 3 Step 1) used by Task 3 Steps 2–3 ✓
- `id_index_ensure`, `path_hash_resize`, `path_count`, `id_index` — defined once, used consistently ✓

**Discovered during P0 (not in scope — flag, do not fix here):**
- `path_remove` deletes slots without tombstones/backshift-shift, so deleting a slot in the middle of a collision chain can cause subsequent `path_lookup` to miss entries that probed past it. Resize + rehash (Task 2) does not depend on this, so P0 is unaffected, but this is a latent correctness bug for workloads with path removal + collisions. Recommend a dedicated task/plan (tombstones or Robin Hood backshift) before P1.
- `cindex_remove_locked` still linear-scans to find the removed record by id (line 335). Now that `id_index` exists, this could be O(1) too — minor optimization for a follow-up, not required for P0 correctness.

---

## Subsequent Phases (each gets its own writing-plans pass)

Do NOT implement these in this plan. After P0 ships and the full suite is green, open a new plan per phase:

- **P1 — single-alloc `DFileMeta`:** replace `FileMeta` + `NameSlot` + `PathSlot` (5 malloc/record) with one `calloc`'d flexible-array-member struct (spec §3.1, §4.1). Depends on B2's `id_index` (entries addressed by id).
- **P2 — string dedup:** filename 3→≤2 (shared lowercase buffer between Trie + trigram), path 2→1 (spec §3.2, §3.3, §4.4). Builds on P1's entry layout.
- **P3 — binary `index.bin` persistence:** replace `IndexPersistence` SQLite impl with `BinaryIndex` behind the same API; carry entries + optional trigram postings + metadata + path encryption + cursor (spec §3.6, §4.5, §7).
- **P4 — SQLite→binary migration:** one-time read of legacy `index.db` → write `index.bin` (spec §4.6, §6).
- **P5 — integration/regression + doc updates:** REQ_CHANGE_LOG `CHG-2026-06-20-01`, metadata-filter design §7 rewrite (binary substrate), CLAUDE.md persistence section (spec §8).
- **Cross-cutting:** resolve the `path_remove` tombstone bug (discovered above) — can be its own small plan before or during P1.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-20-index-engine-refactor-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
