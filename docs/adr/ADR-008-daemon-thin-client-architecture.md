# ADR-008: Daemon + Thin Client Architecture

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

DeepFinder is inspired by Windows Everything, which uses a background service (`Everything.exe` with `-svc` flag) holding an in-memory index, and a thin search client. This architecture enables sub-millisecond query latency: the index is already in memory when the user types, so there is no filesystem scan at query time.

On macOS, there are several patterns for background services:
- **LaunchAgent/daemon**: a persistent process managed by launchd, communicating via Unix domain sockets or XPC.
- **XPC Service**: embedded in an app bundle, managed by launchd, communicating via XPC C API.
- **Single-process**: the GUI app loads and maintains the index in its own process space.
- **HTTP server**: the daemon exposes a REST API on localhost.

Each pattern has different trade-offs for startup latency, memory sharing, crash isolation, debuggability, and distribution complexity.

## Decision

**Background daemon + thin client architecture.**

A persistent daemon (`deepfinder-daemon`) holds the full in-memory index. The CLI (`deepfinder`) and GUI (`DeepFinder.app`) are thin clients that connect to the daemon via a Unix domain socket at `~/.deep-finder/session/ipc.sock`.

The daemon:
- Runs as a LaunchAgent (user-scoped, no root required).
- Loads the SQLite-persisted `FileRecord[]` on startup and rebuilds in-memory index structures.
- Monitors the filesystem via FSEvents.
- Serves queries from CLI and GUI clients via IPC.

The clients:
- CLI (`deepfinder`): single-shot queries or interactive REPL. Connects on first query, auto-starts daemon if not running.
- GUI (`DeepFinder.app`): NSPanel search interface. Connects on hotkey activation, displays streaming results.

The protocol: 4-byte network-byte-order length prefix followed by UTF-8 JSON payload. Request/response model with `queryId` for cancellation and streaming.

## Alternatives Considered

### A. Single-Process Architecture

The GUI app or CLI loads the index in-process. No daemon. No IPC.

**Rejected because:**
- **Startup latency**: loading 1M+ FileRecords and building Trie/FullSubstringMap on every CLI invocation would take seconds, not milliseconds.
- **No shared state**: CLI and GUI cannot share the same index. Each would need its own.
- **Memory duplication**: two index copies if both CLI and GUI are used.
- **No background indexing**: FSEvents monitoring stops when the CLI/GUI exits.

### B. XPC Service

The daemon is an XPC service embedded in the app bundle, managed by launchd.

**Rejected because:**
- **CLI can't be a thin XPC client**: XPC services are tightly coupled to their hosting app's bundle. The CLI would need a separate mechanism to reach the daemon.
- **Debugging complexity**: XPC services require `debugserver` attachment through launchd. Unix sockets can be tested with `nc -U`.
- **Mach service registration**: requires a reverse-DNS service name in the app's plist. Adds distribution complexity for a tool that already needs careful plist management for Full Disk Access.
- **Vendor lock-in**: XPC is Apple-only. While DeepFinder is macOS-only, Unix sockets are a more portable pattern if the architecture is ever adapted.

### C. HTTP Server (localhost REST API)

The daemon listens on `localhost:{port}` with a JSON REST API.

**Rejected because:**
- **Port management**: finding an available port, avoiding conflicts, and handling port changes on restart.
- **TLS complexity**: localhost HTTP is unencrypted by default. Adding TLS means certificate management for a local-only connection.
- **Overhead**: HTTP headers, status codes, and connection setup add latency to every query compared to raw Unix socket + length-prefixed JSON.
- **Discovery**: clients need to discover the port number (file-based or broadcast).

## Consequences

### Positive

- **Sub-millisecond queries**: the index is already in memory when the client connects.
- **~1ms CLI startup**: the thin client only does argument parsing + IPC connect.
- **Crash isolation**: daemon crash does not kill the GUI or CLI. The CLI auto-reconnects.
- **Single index**: CLI and GUI share one daemon, one index, one FSEvents stream.
- **Clean separation**: indexing logic lives only in the daemon. Clients are pure presentation.
- **Debuggable**: `nc -U ~/.deep-finder/session/ipc.sock` for manual protocol testing. JSON payloads are human-readable.

### Negative

- **IPC overhead**: every query crosses a process boundary via socket I/O.
- **Socket lifecycle**: stale socket file on unclean daemon shutdown must be cleaned up.
- **Two binaries**: users must install both `deepfinder` and `deepfinder-daemon`.
- **LaunchAgent management**: users must understand LaunchAgent lifecycle (install, uninstall, load, unload) for auto-start.

### Mitigation

- IPC overhead is negligible (~microseconds) for local Unix sockets — the bottleneck is search algorithm performance, not transport.
- Stale socket cleanup is automatic: `daemon start` checks whether the PID in `daemon.pid` is alive before binding.
- The `deepfinder install` / `deepfinder uninstall` commands abstract LaunchAgent management behind simple verbs.
