# Beta 0.0.1: Debug Mode + Remaining Fixes

**Date**: 2026-06-19
**Scope**: CLI v0.0.1 beta readiness (v0.1–v1.5, no GUI/AI)

## Work Items

### D1: Debug/Info Logging Infrastructure (NEW)
- **Why**: Beta needs enough logs to diagnose user issues without reproducing locally
- **Design**:
  - `Sources/Core/Logger.swift` — file + stderr dual-output logger
  - Log levels: `debug`, `info`, `warn`, `error`
  - Format: `[2026-06-19T10:30:00.123Z] [INFO] [daemon] message`
  - Daemon: logs to `~/.deep-finder/logs/deepfinder.log` (rotating: 10MB × 5 files)
  - CLI: `--debug` flag enables stderr debug output
  - Config: `deepfinder config set debug true` for persistent enable
  - Wire into: DaemonMain, IPCServer, SearchCoordinator, FileScanner, FSEventWatcher, CLI main paths
- **Files**: `Sources/Core/Logger.swift` (new), `Sources/Index/Constants.swift` (+Logging section), `Sources/CLI/ArgParser.swift` (+`--debug`), `Sources/Daemon/DaemonMain.swift`, `Sources/Daemon/IPCServer.swift`, `Sources/Search/SearchCoordinator.swift`

### M3: Fuzzy Suggestion on Zero Results
- **Current**: FuzzyCorrector exists but never triggered in search flow
- **Fix**: When search returns 0 results, run fuzzy correction against index terms, suggest to user
- **Files**: `Sources/CLI/SingleShot.swift`, `Sources/CLI/REPL.swift`, `Sources/CLI/FuzzyCorrection.swift`

### M4: Exit Code Consistency Audit
- **Spec**: 0=success, 1=no results, 2=daemon error, 3=query error
- **Fix**: Audit all return paths in CLIMain, ConfigCommands, DaemonCommands, SingleShot
- **Files**: `Sources/CLI/CLIMain.swift`, `Sources/CLI/ConfigCommands.swift`, `Sources/CLI/DaemonCommands.swift`, `Sources/CLI/SingleShot.swift`

### #17: SQLite Duplicate Record Cleanup
- **Current**: B3 path-based upsert prevents NEW duplicates; old DBs may still have dupes
- **Fix**: Add dedup step in DaemonMain startup after loading records
- **Files**: `Sources/Daemon/DaemonMain.swift`, `Sources/Persist/IndexPersistence.swift`

### #18: Exclude Worktree/Temp Dirs from Scan
- **Current**: Skips `.git`, `node_modules`, `.Trash`, `.Spotlight-V100`, `/System`, `/Library`
- **Missing**: `.claude/worktrees`, `.build`, `.swiftpm`, `DerivedData`, `/tmp`, `/private/var`
- **Fix**: Add to `Constants.Scan.alwaysSkippedNames` and `alwaysExcludedPrefixes`
- **Files**: `Sources/Index/Constants.swift`

### #19: DaemonTests Isolation
- **Current**: Tests may conflict with running production daemon
- **Fix**: Use unique socket/PID paths in test environment
- **Files**: `Tests/DaemonTests/`

### #20: REPL Non-Interactive Test Coverage
- **Current**: REPL requires tty, hard to test
- **Fix**: Add command-piping mode for testability
- **Files**: `Sources/CLI/REPL.swift`, `Tests/CLITests/REPLTests.swift`

## Verification Plan
1. `swift build` — all targets compile
2. `swift test` — all tests pass
3. `./scripts/deepfinder-reset.sh` — clean install
4. `deepfinder daemon status` — verify progress display
5. `deepfinder "test"` — verify search works
6. `deepfinder "test" --debug` — verify debug logs on stderr
7. `deepfinder "xyznonexistent"` — verify fuzzy suggestion
8. `tail -f ~/.deep-finder/logs/deepfinder.log` — verify daemon logs
