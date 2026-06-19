# Search Pipeline Fix Plan

**Date**: 2026-06-19
**Branch**: refactor/oss-quality-audit
**Trigger**: CLI full-function test — 5 confirmed defects + 5 minor issues

## Fixes

### B1 — Modifier-only queries return empty
- **Root cause**: `SearchCoordinator.search` guard `!rawQuery.isEmpty else { return [] }` bails before filters applied
- **Fix**: In IPCServer `.query` handler, when `textOnlyQuery` is `""` and `filters` is non-empty, substitute `cleanQuery = "*"` to trigger FileIndexProvider wildcard scan + filter
- **Files**: `Sources/Daemon/IPCServer.swift` (~line 541)
- **Risk**: Low — wildcard fallback is already the production path for `*.ext` queries

### B2 — Boolean operators never evaluated
- **Root cause**: `QueryParser` builds AST (`.or`/`.not` nodes) but daemon only consumes `modifierPairs` + `textOnlyQuery`; `parsed.terms` has zero production consumers
- **Fix**: Add `searchWithBooleanAST(parsed:filters:)` to `SearchCoordinator` that recursively evaluates the AST:
  - `.and([children])` → intersect positive children, subtract `.not` children
  - `.or([children])` → union all children
  - `.text(s)` → provider search via `searchLeaf(query:)`
  - `.wildcard/.regex` → delegated to `searchLeaf`
  - `.modifier/.pathQualifier` → skipped (handled by filters)
  - In IPCServer, detect boolean ops (`.or`/`.not` anywhere in AST), dispatch to new method
- **Files**: `Sources/Search/SearchCoordinator.swift` (+~80 lines), `Sources/Daemon/IPCServer.swift` (~10 lines)
- **Risk**: Medium — new code path; simple queries use existing fast path, only boolean queries take new path

### B3 — Duplicate indexing (same path ×13 record IDs)
- **Root cause**: InMemoryIndex has no path→id mapping; repeated scan/FSEvents passes append new records without upsert
- **Fix**: Add path-to-ID index in InMemoryIndex; on insert, if path already exists, update existing record (upsert) instead of appending
- **Files**: `Sources/Index/InMemoryIndex.swift`
- **Risk**: Medium — core data structure change; must maintain invariants across all index operations

### B4 — `--offset` broken
- **Root cause**: offset applied client-side (`dropFirst`) after daemon already truncated to `--limit` → offset ≥ effective results = empty
- **Fix**: Add `offset: Int?` parameter to `IPCRequest.query(query:limit:offset:)`; apply offset server-side in daemon before limit truncation; remove client-side dropFirst
- **Files**: `Sources/Daemon/IPCProtocol.swift`, `Sources/Daemon/IPCServer.swift`, `Sources/CLI/SingleShot.swift`
- **Risk**: Low — backward-compatible IPC change (optional field)

### B5 — `dupe` IPC overflow (236 MB response)
- **Root cause**: Duplicate scan returns unbounded results across entire index with no server-side cap
- **Fix**: Cap duplicate groups at `Constants.Daemon.maxResults` (1000) before returning over IPC
- **Files**: `Sources/Daemon/IPCServer.swift` (dupe handler, ~line 572)
- **Risk**: Low — just adds a `prefix` cap

### M1 — `config get <unknown>` returns exit 0
- **Fix**: In `ConfigCommandRunner.get`, return non-zero exit code for unknown keys
- **Files**: `Sources/CLI/ConfigCommands.swift`

### M2 — `config set <unknown>` returns "OK" but not persisted
- **Fix**: Validate key against known config keys before setting; reject unknown
- **Files**: `Sources/CLI/ConfigCommands.swift`

### M3 — Fuzzy suggestions never returned
- **Root cause**: Suggest dictionary likely empty — needs population from indexed filenames
- **Fix**: In daemon's suggest handler, use a frequency-based term dictionary built from index; or use the index's autocomplete/suggest capability
- **Files**: `Sources/Daemon/IPCServer.swift` (suggest handler), `Sources/Index/InMemoryIndex.swift`

### M4 — Exit code inconsistency (0 vs 1 for no-results)
- **Fix**: Audit all empty-result paths, ensure consistent exit 1
- **Files**: `Sources/CLI/SingleShot.swift`, `Sources/CLI/CLIMain.swift`

## Implementation Order

1. B1 (modifier-only) — 2 lines, no risk
2. B2 (boolean) — SearchCoordinator + IPCServer
3. B3 (duplicate indexing) — InMemoryIndex
4. B4 (offset) — IPC protocol + client + daemon
5. B5 (dupe cap) — 1 line in IPCServer
6. M1+M2 (config) — ConfigCommands
7. M3 (fuzzy) — suggest dictionary
8. M4 (exit codes) — audit
9. Build + test all
