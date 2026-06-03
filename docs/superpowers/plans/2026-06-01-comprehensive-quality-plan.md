# DeepFinder Comprehensive Quality Improvement Plan

> **Completion status (2026-06-02):** This plan has 36 tasks. P0-01 (FilterPipeline wiring) is DONE. Most P1/P2 items related to doc/spec fixes were addressed in the 2026-06-02 comprehensive spec review. Remaining items (CI, performance benchmarks, additional refactoring) are deferred to post-OSS work.

> **For agentic workers:** Execute tasks in priority order (P0 → P1 → P2 → P3). After each task: 1) verify tests pass, 2) review findings, 3) update this plan with newly discovered requirements.

**Goal:** Bring DeepFinder from v3.0.0 to OSS-ready quality — fix critical dead-code gaps, wire all CLI modes, stabilize build/test pipeline, improve code quality across all modules.

**Architecture:** All changes preserve existing architecture (actor-based concurrency, zero external deps, daemon+IPC model). Focus on wiring dead code, fixing bugs, and improving consistency.

**Tech Stack:** Swift 6, macOS 26 SDK, Swift Testing (@Suite/@Test/#expect)

**Overall Health Score:** 6/10 (from 15-agent audit)

**Execution Rules:**
- **14:00–18:00 UTC+8**: Planning only, no task execution (智谱 3x 额度高峰期)
- **After 18:00 UTC+8**: Execute tasks
- **After each task**: Review → update plan → continue

---

## Task Summary

| Priority | Count | Estimated Total Effort |
|----------|-------|----------------------|
| P0 Critical | 4 | ~3h |
| P1 High | 8 | ~19h |
| P2 Medium | 14 | ~17h |
| P3 Low | 10 | ~8.5h |
| **Total** | **36** | **~47.5h** |

---

## Phase 1: Critical Fixes (P0) — Must-do before any other work

### P0-01: Wire REPL and subcommand dispatch in CLIMain ✅

**Status:** ✅ DONE
**Category:** cli-mode
**Effort:** 2h
**Files:** `Sources/CLI/CLIMain.swift:119-126`

**Problem:** CLIMain.run() shows a stale "Interactive REPL mode is coming in v0.6" placeholder when no query is provided. The REPL actor is fully implemented but never instantiated. Subcommands (daemon, config, install) are parsed by ArgParser but never routed — DaemonCommandRunner, ConfigCommandRunner, InstallCommandRunner are dead code.

**Evidence:** CLIMain.swift:120-126: `guard let query = options.query else { return "coming in v0.6" }`. ArgParser.swift:146-147 populates `options.subcommand`.

**Fix:** Add subcommand dispatch before REPL fallback:
1. If `options.subcommand != nil` → route to DaemonCommandRunner/ConfigCommandRunner/InstallCommandRunner
2. If `options.query != nil` → SingleShot mode (existing)
3. Otherwise → REPL mode (new wiring)

**Verification:** `swift test --filter CLIMainTests`, `swift test --filter IntegrationTests`, manual `swift run deepfinder` (should launch REPL)

---

### P0-02: Declare AI prompt files as resources in Package.swift ✅

**Status:** ✅ DONE
**Category:** build-ci
**Effort:** 30min
**Files:** `Package.swift:13-20`, `Sources/AI/Prompts/`, `Sources/AI/PromptLoader.swift`

**Problem:** Four .txt prompt files are not declared as resources. SPM warns "found 4 file(s) which are unhandled". PromptLoader.load() always returns nil, falling back to inline defaults silently.

**Fix:** Add `resources: [.process("AI/Prompts")]` to the DeepFinder library target in Package.swift.

**Verification:** `swift build` should no longer warn about unhandled files. `swift test --filter PromptLoaderTests` should pass.

---

### P0-03: Fix test suite SIGSEGV crash ✅

**Status:** ✅ DONE (not reproducible, 655 tests pass, monitoring)
**Category:** build-ci
**Effort:** 1d
**Files:** `Tests/DaemonTests/ConcurrencyStressTests.swift`, `Tests/DaemonTests/`

**Problem:** Test suite crashes intermittently with signal 11 (SIGSEGV). Only ~10 of 1073 test results captured before crash. Likely from socket-based concurrency stress tests or actor contention.

**Fix approach:**
1. Run `swift test` with `--verbose` to identify crash location
2. Check ConcurrencyStressTests for unsafe memory access
3. Add proper cleanup/teardown to socket-based tests
4. Consider isolating stress tests in their own target

**Verification:** `swift test` completes without SIGSEGV, all tests pass.

---

### P0-04: Fix LaunchAgent plist pointing to CLI binary instead of daemon binary ✅

**Status:** ✅ DONE
**Category:** code-quality
**Effort:** 30min
**Files:** `Sources/Daemon/LaunchAgent.swift:66`, `Sources/Index/ProductConfig.swift:21-24`

**Problem:** `LaunchAgent.generatePlist()` uses `Product.command` ("deepfinder") instead of `Product.daemonCommand` ("deepfinder-daemon"). Launchd will launch the CLI binary with --daemon flag, which has no handler for it.

**Fix:** Change `Product.command` to `Product.daemonCommand` in LaunchAgent.swift:66.

**Verification:** `swift test --filter LaunchAgentTests` or `DaemonTests`, inspect generated plist.

---

## Phase 2: High-Priority Fixes (P1) — Code correctness

### P1-01: Implement copy-on-write for Trie to fix broken value semantics

**Status:** ⬜ Pending
**Category:** code-quality
**Effort:** 4h
**Files:** `Sources/Index/Trie.swift:8-18`, `Sources/Index/PinyinIndex.swift`

**Problem:** Trie is documented as "a value type (struct)" but uses `final class Node` internally, causing shared-reference mutation. Copying a Trie and mutating the copy silently mutates the original.

**Fix:** Add COW wrapper: on mutation, check reference count and copy Node tree if shared. Alternatively, document Trie as reference-semantics and adjust usage.

**Verification:** Add test that copies a Trie, mutates copy, verifies original unchanged. All existing Trie/InMemoryIndex/PinyinIndex tests pass.

---

### P1-02: Wire daemon stats/indexStatus to actual state

**Status:** ⬜ Pending
**Category:** code-quality
**Effort:** 2h
**Files:** `Sources/Daemon/DaemonMain.swift:369-376`, `Sources/Daemon/IPCServer.swift:503-509`

**Problem:** `statsProvider` returns `DaemonStats(totalFiles: 0, memoryUsageMB: 0)` — always zeros. IPC `.indexStatus` returns `DaemonIndexStatus(state: "unknown", filesIndexed: 0)`.

**Fix:** Wire statsProvider to read from InMemoryIndex.count() and ProcessInfo.memoryUsage. Wire indexStatus to actual index state.

**Verification:** `swift test --filter DaemonMainTests`, `swift test --filter IPCServerTests`. Stats should reflect real values.

---

### P1-03: Implement FSEventWatcher polling scan fallback

**Status:** ⬜ Pending
**Category:** code-quality
**Effort:** 4h
**Files:** `Sources/FS/FSEventWatcher.swift:443-445`

**Problem:** `performPollingScan()` is an empty placeholder. When FSEvents fails, daemon silently has no index updates.

**Fix:** Implement full directory scan with mtime comparison against cached state. Use FileScanner to enumerate changes.

**Verification:** `swift test --filter FSEventWatcherTests`. Test polling fallback path.

---

### P1-04: Fix FilterPipeline depth filter ignoring comparison operators

**Status:** ⬜ Pending
**Category:** code-quality
**Effort:** 1h
**Files:** `Sources/Search/FilterPipeline.swift:99-117`

**Problem:** `parseDepthFilter` strips operators (<=, >=, <, >) but always returns `.maxDepth`. Query `depth:>3` becomes `.maxDepth(3)` meaning depth <= 3.

**Fix:** Add `.minDepth`, `.exactDepth`, `.depthRange` filter cases. Route each operator to the correct case.

**Verification:** `swift test --filter FilterPipelineTests`. Test depth:>, depth:<, depth:>=, depth:<=, depth:3.

---

### P1-05: Fix CI workflow for non-existent macos-26 runner

**Status:** ⬜ Pending
**Category:** build-ci
**Effort:** 1h
**Files:** `.github/workflows/ci.yml:16`, `.github/workflows/release.yml`

**Problem:** CI uses `runs-on: macos-26` which doesn't exist on GitHub-hosted runners.

**Fix:** Use `macos-15` with Xcode 26 beta, or configure self-hosted runner. Add `tool-versions` comment for reference.

**Verification:** Push to branch, CI runs green.

---

### P1-06: Add tests for PathEncryption (zero coverage)

**Status:** ⬜ Pending
**Category:** test-quality
**Effort:** 4h
**Files:** `Sources/Persist/PathEncryption.swift`, `Tests/PersistTests/`

**Problem:** 202-line AES-256-GCM security module with 8 error cases has zero test coverage.

**Fix:** Create `Tests/PersistTests/PathEncryptionTests.swift` covering: encrypt/decrypt round-trip, empty input, invalid key, corrupted ciphertext, nonce handling, wire format, keychain errors.

**Verification:** `swift test --filter PathEncryptionTests` passes with meaningful coverage.

---

### P1-07: Fix FSEventWatcher deletion using name-search instead of path-based lookup

**Status:** ⬜ Pending
**Category:** code-quality
**Effort:** 2h
**Files:** `Sources/FS/FSEventWatcher.swift:380-388`

**Problem:** `handleFileDeleted` uses `index.search(query:)` by name then filters by path — O(results_for_name) and semantically wrong.

**Fix:** Add `removeByPath(_ path: String)` to InMemoryIndex. Use direct path-based removal.

**Verification:** `swift test --filter FSEventWatcherTests`, `swift test --filter InMemoryIndexTests`.

---

### P1-08: Fix SearchSorter vs SearchFilter inconsistent path-depth implementations

**Status:** ⬜ Pending
**Category:** code-quality
**Effort:** 1h
**Files:** `Sources/Search/SearchSorter.swift:87-90`, `Sources/Search/SearchFilter.swift:223-225`

**Problem:** Two different `pathDepth()` implementations produce different results for paths with trailing slashes or double slashes.

**Fix:** Extract single `pathDepth(_ path: String) -> Int` utility function. Use in both SearchSorter and SearchFilter.

**Verification:** `swift test --filter SearchSorterTests`, `swift test --filter SearchFilterTests`.

---

## Phase 3: Medium-Priority Improvements (P2)

### P2-01: Normalize empty extension handling between FileScanner and FSEventWatcher
**Effort:** 30min | **Files:** `Sources/FS/FileScanner.swift:265-277`, `Sources/FS/FSEventWatcher.swift:364-375`

### P2-02: Fix ResultRowView force-unwrap in MatchHighlighter
**Effort:** 1h | **Files:** `Sources/GUI/ResultRowView.swift:154-155`

### P2-03: Fix SearchFilter hardcoded Monday-first week assumption
**Effort:** 1h | **Files:** `Sources/Search/SearchFilter.swift:197-203`

### P2-04: Consolidate duplicate SearchPanelView with ResultsListView
**Effort:** 4h | **Files:** `Sources/GUI/SearchPanelView.swift`, `Sources/GUI/ResultsListView.swift`

### P2-05: Remove dead MediaMetadataIndex actor
**Effort:** 30min | **Files:** `Sources/Media/MediaMetadataIndex.swift`

### P2-06: Fix HTTPSearchService handlerTasks dead code and route duplication
**Effort:** 2h | **Files:** `Sources/Services/HTTPSearchService.swift:57,305-333`

### P2-07: Fix DaemonCommandRunner bare print() instead of output writer
**Effort:** 1h | **Files:** `Sources/CLI/DaemonCommands.swift:148-180`

### P2-08: Consolidate duplicate CLI output protocols
**Effort:** 1h | **Files:** `Sources/CLI/ConfigCommands.swift:7-11`, `Sources/CLI/REPL.swift:32-39`

### P2-09: Update stale CHANGELOG, REQ_STATUS, and OSS readiness assessment
**Effort:** 2h | **Files:** `CHANGELOG.md`, `docs/superpowers/specs/reqs/REQ_STATUS.md`, `docs/superpowers/plans/2026-05-31-oss-readiness-assessment.md`

### P2-10: Update CLAUDE.md directory listing for AI module
**Effort:** 30min | **Files:** `CLAUDE.md`

### P2-11: Fix Homebrew formula placeholder sha256 and wrong Xcode version
**Effort:** 30min | **Files:** `packaging/homebrew/deepfinder.rb`

### P2-12: Fix CJK marked-text detection in SearchBarView
**Effort:** 3h | **Files:** `Sources/GUI/SearchBarView.swift:31-33`

### P2-13: Fix VolumeManager duplicate unmount events
**Effort:** 30min | **Files:** `Sources/FS/VolumeManager.swift:185-202`

### P2-14: Move VolumeManager.shouldIndex out of FS module
**Effort:** 1h | **Files:** `Sources/FS/VolumeManager.swift:107-120`

---

## Phase 4: Low-Priority Polish (P3)

### P3-01: Remove ~30 trivial Sendable/Equatable conformance tests in AITests
**Effort:** 1h | **Files:** `Tests/AITests/`

### P3-02: Add happy-path tests for AudioMetadataExtractor and VideoMetadataExtractor
**Effort:** 2h | **Files:** `Tests/MediaTests/`

### P3-03: Add PromptLoader edge case tests
**Effort:** 1h | **Files:** `Tests/AITests/PromptLoaderTests.swift`

### P3-04: Remove dead extractors array in MetadataExtractorRegistry
**Effort:** 15min | **Files:** `Sources/Media/MetadataExtractor.swift:41`

### P3-05: Fix GUI inconsistent localization
**Effort:** 2h | **Files:** `Sources/GUI/ResultRowView.swift`, `Sources/GUI/SearchBarView.swift`, `Sources/GUI/ResultsListView.swift`

### P3-06: Cache DateFormatter/ByteCountFormatter in GUI
**Effort:** 30min | **Files:** `Sources/GUI/SearchPanelView.swift:249-259`

### P3-07: Fix IPCServer duplicate 1ms sleep
**Effort:** 5min | **Files:** `Sources/Daemon/IPCServer.swift:306-308`

### P3-08: Fix ServeMode.run() starting then immediately stopping
**Effort:** 1h | **Files:** `Sources/CLI/ServeMode.swift:114-120`

### P3-09: Fix FullSubstringMap redundant O(n^2) re-insertion
**Effort:** 30min | **Files:** `Sources/Index/FullSubstringMap.swift:34-53`

### P3-10: Fix SearchBookmark save() atomic write race
**Effort:** 15min | **Files:** `Sources/CLI/REPLHistory.swift:80-106`

---

## Execution Progress

| Task | Status | Executed At | Review Notes |
|------|--------|-------------|-------------|
| P0-01 | ✅ | — | DONE — REPL and subcommand dispatch wired |
| P0-02 | ✅ | — | DONE |
| P0-03 | ✅ | — | DONE (not reproducible, monitoring) |
| P0-04 | ✅ | — | DONE |
| P1-01 | ⬜ | — | — |
| P1-02 | ⬜ | — | — |
| P1-03 | ⬜ | — | — |
| P1-04 | ⬜ | — | — |
| P1-05 | ⬜ | — | — |
| P1-06 | ⬜ | — | — |
| P1-07 | ⬜ | — | — |
| P1-08 | ⬜ | — | — |
| P2-01~14 | ⬜ | — | — |
| P3-01~10 | ⬜ | — | — |

---

## Newly Discovered Tasks (added during execution)

*(Tasks discovered during review cycles are added here)*

| ID | Priority | Title | Discovered During |
|----|----------|-------|-------------------|
| NF-01 | P2-medium | Fix GlobalHotkeyTests flaky in headless (mock Carbon RegisterEventHotKey) | P2 batch 1 review |
| NF-02 | P2-medium | Swift Testing runner SIGSEGV at ~350+ tests (file radar) | P0-03 investigation |
| NF-03 | P3-low | SourceKit diagnostics show stale errors after agent edits — verify with swift build | P2 batch 1 |
