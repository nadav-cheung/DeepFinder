# ADR-001: Monolithic Target vs Multi-Module Package.swift

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

DeepFinder's Package.swift originally defined 6+ Swift targets:

| Original Target        | Type       | Purpose                  |
|------------------------|------------|--------------------------|
| `DeepFinderIndex`      | .target    | Index data structures    |
| `DeepFinderSearch`     | .target    | Search providers         |
| `DeepFinderFS`         | .target    | FSEvent watcher, scanner |
| `DeepFinderPersist`    | .target    | SQLite persistence       |
| `DeepFinderDaemon`     | .executable| Background daemon        |
| `DeepFinderCLI`        | .executable| User-facing CLI          |

Each had its own `Tests/` target, yielding 8+ test targets total.

Two problems emerged:

1. **Slow compilation for small changes.** Swift's incremental compilation works at the file level within a target, but across-target dependency graphs forced re-linking of executables even when only internal implementation changed. The library targets themselves were tiny (2-6 files each), making the target boundary overhead (>100 targets total with tests) dominate.

2. **Inter-target coupling created circular-dependency risk.** `DeepFinderSearch` imported `DeepFinderFS` (for FileScanner results), but `DeepFinderFS` conceptually depended on `DeepFinderIndex` types. Maintaining a clean DAG with many tiny modules required constant vigilance with no real benefit at this scale.

3. **Test target explosion.** 8 test targets meant Xcode scheme management overhead, parallel test configuration complexity, and duplicated test fixtures.

## Decision

**Collapse all library code into a single `DeepFinder` target** with thin executable entry-point targets.

Final structure (current `Package.swift`):

```
Package.swift
├── .library(name: "DeepFinder", targets: ["DeepFinder"])
├── .executable(name: "deepfinder", targets: ["DeepFinderCLI"])
└── .executable(name: "deepfinder-daemon", targets: ["DeepFinderDaemon"])

Targets:
├── .target(name: "DeepFinder", path: "Sources")
│   └── Contains: Index/, Search/, FS/, Persist/, AI/, GUI/
├── .executableTarget(name: "DeepFinderCLI", dependencies: ["DeepFinder"],
│                     path: "Sources/CLIEntry")
├── .executableTarget(name: "DeepFinderDaemon", dependencies: ["DeepFinder"],
│                     path: "Sources/DaemonEntry")
└── .testTarget(name: "DeepFinderTests", dependencies: ["DeepFinder"], path: "Tests")
```

The `Sources/` directory is organized into logical subdirectories (`Index/`, `Search/`, `FS/`, etc.) but they all compile as one module. The two executable entry points (`CLIEntry/`, `DaemonEntry/`) contain only a `main.swift` each and depend on the single library.

## Consequences

**Positive:**

- **Faster incremental builds.** Changes to any `.swift` file in `Sources/` recompile only that file within the `DeepFinder` module. No cross-target re-linking.
- **Simplified dependency management.** No risk of circular imports between sub-modules. All internal types are accessible everywhere without re-export plumbing.
- **Single test target.** `DeepFinderTests` covers everything. Test discovery and parallelization are simpler.
- **Fewer Package.swift lines.** Down from ~80+ lines to 38 lines. Easier to read, easier to audit.

**Negative:**

- **No enforced API boundaries.** The compiler cannot prevent Index types from importing GUI types. We rely on directory conventions and code review to maintain logical layering.
- **Coarser access control.** All internal types are `internal` to the module rather than `public` between sub-modules. If a future library consumer (e.g., a third-party app) wants to embed DeepFinder, we would need to extract a separate target with `public` API.
- **Single monolithic test binary.** Large test suites cannot be split across separate test runners. On M4 hardware, this is not yet a practical concern.

**Mitigation:**

- Directory structure (`Sources/Index/`, `Sources/Search/`, etc.) enforces logical layering.
- CODEOWNERS and code review guard against architectural violations.
- If modular packaging becomes necessary again (e.g., for an SDK distribution), the subdirectory structure makes re-extraction straightforward.

## Related

- [ADR-003](ADR-003-fullsubstringmap-64-char-threshold-trigram-fallback.md) — Search index data structures live inside this monolithic target
- [ADR-004](ADR-004-ai-privacy-boundary-filemetadata-summary.md) — AI module (`Sources/AI/`) benefits from same-target access to Index types
- [ADR-006](ADR-006-fseventwatcher-actor-isolation-model.md) — FSEventWatcher actor in `Sources/FS/` directly calls `InMemoryIndex` actor, made legal by the monolithic target
