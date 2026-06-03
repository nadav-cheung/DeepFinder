# ADR-007: Zero External Dependencies

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

DeepFinder is a macOS file search tool. The Swift ecosystem has a rich set of third-party packages: GRDB.swift for SQLite, SwiftNIO for networking, swift-argument-parser for CLI, Alamofire for HTTP, and many more. Adding a dependency is as simple as adding a line to `Package.swift`.

However, every external dependency introduces:
- **Supply-chain risk**: a compromised dependency update could inject malicious code into the build.
- **Version lock-in**: dependency version conflicts can block Swift toolchain upgrades.
- **Audit surface**: each dependency's full source tree becomes part of the security boundary.
- **Adoption friction**: `swift package resolve` must download and verify every dependency before the first build.
- **Binary size**: transitive dependencies can inflate the final binary.

For a tool that requires Full Disk Access and runs as a background daemon, the trust model is especially sensitive. Users must trust that DeepFinder does not exfiltrate their file metadata. Zero external dependencies means the entire codebase can be audited by reading the repository — no hidden code from package resolution.

## Decision

**Zero external dependencies.** All functionality uses Apple's built-in frameworks only: Foundation, CoreServices, Carbon, SQLite3 (system libsqlite3.dylib), Darwin, NaturalLanguage, Vision, Speech, AVFoundation, SwiftUI.

No CocoaPods. No SPM remote dependencies. No vendored third-party source code.

## Alternatives Considered

### A. GRDB.swift for SQLite

GRDB.swift provides a type-safe Swift interface to SQLite with automatic migrations, observation, and query building.

**Rejected because**: DeepFinder uses raw SQLite3 C API directly. The persistence layer (`Sources/Persist/IndexPersistence.swift`) needs fine-grained control over WAL mode, batch commits, and custom checkpointing. GRDB.swift abstracts these details behind its own connection pool. Additionally, the `SQLITE_DBCONFIG_DEFENSIVE` flag and direct `sqlite3_wal_checkpoint_v2` calls are only available via the C API.

### B. SwiftNIO for IPC

SwiftNIO provides a high-performance, event-driven networking framework.

**Rejected because**: DeepFinder's IPC protocol is a simple Unix domain socket with a 4-byte length prefix and JSON body. The implementation in `Sources/Daemon/IPCServer.swift` and `Sources/Daemon/IPCClient.swift` is under 500 lines total using Darwin's `socket()`, `bind()`, `listen()`, and `accept()` syscalls. SwiftNIO would add tens of thousands of lines of dependency for no meaningful benefit.

### C. swift-argument-parser for CLI

Apple's swift-argument-parser provides declarative CLI argument parsing with automatic help generation.

**Rejected because**: DeepFinder's CLI argument parsing (`Sources/CLI/ArgParser.swift`) uses manual `CommandLine.arguments` parsing — a straightforward state machine under 200 lines. The zero-dependency guarantee is more valuable than the convenience of declarative parsing. Additionally, manual parsing allows DeepFinder to handle edge cases (like bare query strings without flags) that swift-argument-parser's strict mode would reject.

## Consequences

### Positive

- **Zero supply-chain risk**: no third-party code executes during build or runtime.
- **Trivially auditable**: the entire codebase is in one repository. `git clone && swift build` is the full supply chain.
- **Instant adoption**: no `swift package resolve` step. Builds are deterministic.
- **Smaller binary**: no linked third-party libraries.
- **No version conflicts**: Swift toolchain upgrades never break because a dependency hasn't been updated.
- **Security posture**: audit surface = project source code. Nothing more.

### Negative

- **More code to write**: every feature must be built from Apple frameworks' lower-level APIs.
- **No community bug fixes**: bugs in DeepFinder's SQLite usage, IPC, or argument parsing must be fixed in-house.
- **Reinventing wheels**: some functionality (e.g., CLI help formatting) duplicates what off-the-shelf packages provide.
- **Harder to attract contributors**: developers familiar with popular Swift packages may find the codebase unfamiliar.

### Mitigation

The project compensates by:
1. Using system-provided libraries (`libsqlite3.dylib`) rather than bundling SQLite — security patches come via macOS updates.
2. Keeping implementations minimal (200-line argument parser, 500-line IPC) so maintenance burden is low.
3. Documenting architectural decisions (these ADRs) so contributors understand WHY each wheel was reinvented.
