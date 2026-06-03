# ADR-010: Unix Domain Sockets for IPC Transport

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

The daemon + thin client architecture (ADR-008) requires an inter-process communication transport between the daemon and its CLI/GUI clients. The transport must be:

- **Local-only**: the daemon should never be reachable from other machines.
- **Low-latency**: every query and result crosses the transport. 1M+ queries/day means even microsecond overhead matters.
- **Debuggable**: developers must be able to inspect and manually test the protocol.
- **Simple**: the implementation must be maintainable without external dependencies (ADR-007).
- **Access-controlled**: only the owning user should be able to connect to the daemon.

## Decision

**Unix domain socket (AF_UNIX, SOCK_STREAM)** at `~/.deep-finder/session/ipc.sock`.

Protocol framing: 4-byte network-byte-order (big-endian) length prefix, followed by a UTF-8 JSON payload. The length prefix excludes itself (4 bytes) — it is the byte count of the JSON payload only.

The socket file is created with permissions `0600` (owner read/write only). The daemon additionally validates that the connecting process has the same UID via `getpeereid()` (see ADR-006 for actor isolation discussion around this syscall).

The protocol version is negotiated in the first message. Current version: `1`. The `IPCFraming` enum in `Sources/Daemon/IPCFraming.swift` defines the wire format.

## Alternatives Considered

### A. XPC (Apple's Recommended IPC)

XPC is Apple's recommended IPC mechanism for macOS daemons. It provides automatic service lifecycle via launchd, Mach port-based transport, and built-in security (endpoint authentication).

**Rejected because**:
- XPC requires Mach service registration in the app's `Info.plist` and launchd integration. This makes the daemon harder to run standalone for debugging.
- The CLI binary is not an XPC client — it would need a parallel IPC mechanism anyway, defeating the "unified transport" goal.
- XPC debugging requires `debugserver` attachment through launchd. Unix sockets can be trivially tested with `nc -U` and `echo | nc`.
- XPC adds complexity (asynchronous callback model, `xpc_connection_create_mach_service`, error handling) that is unnecessary for a simple request/response protocol over a local socket.

### B. TCP Loopback (localhost)

The daemon listens on `127.0.0.1:{port}` and clients connect via TCP.

**Rejected because**:
- Port management: finding an available port, avoiding conflicts with other local services, handling port reuse after daemon restart.
- Port discovery: clients need to know which port the daemon is using. This requires either a well-known port (conflict-prone) or a side channel (like writing the port to a file — which is essentially what the Unix socket path already does).
- Marginally higher overhead: TCP stack processing (even on loopback) adds framing and congestion control overhead that Unix domain sockets bypass.
- Security: loopback is accessible to any process on the machine that can open a TCP connection. Unix domain socket permissions restrict access to the owning user via filesystem ACLs.

### C. Named Pipes (FIFOs)

Two named pipes (one for requests, one for responses) at well-known paths.

**Rejected because**:
- FIFOs are unidirectional — one pipe per direction means two file descriptors per connection.
- Multiple simultaneous clients require per-client FIFOs or multiplexing, adding complexity.
- FIFOs block on open until both ends connect, complicating connection lifecycle.
- No built-in framing — the protocol would need delimiters or length prefixes, same as Unix sockets but with more plumbing.

## Consequences

### Positive

- **Standard Unix mechanism**: every Unix developer understands sockets. The protocol is teachable in 5 minutes.
- **Debuggable**: `nc -U ~/.deep-finder/session/ipc.sock` for interactive testing. JSON payloads can be crafted by hand.
- **No port conflicts**: the filesystem path is the only namespace. No port scanning or allocation.
- **OS-enforced access control**: socket file permissions (`0600`) restrict access to the owning user. No additional authentication layer needed.
- **No encryption needed**: local-only transport. Data never leaves the machine.
- **Zero configuration**: clients hard-code the socket path. No port discovery, no service registry.

### Negative

- **Stale socket file**: if the daemon crashes without cleanup, the socket file remains on disk. The next daemon start must detect and remove it.
- **No built-in service discovery**: clients must know the socket path. (Mitigated by hard-coding a well-known path.)
- **No built-in encryption**: acceptable for local-only IPC. If remote access is ever needed, this transport would need to be replaced or wrapped in TLS.
- **Filesystem-dependent**: the socket lives in `~/.deep-finder/session/`. If that directory is on a network filesystem with broken Unix socket support, the daemon won't start.

### Mitigation

- Stale socket detection: `IPCServer.start()` checks the PID file. If the PID is not a running process, the stale socket is removed before binding.
- Well-known path: `Constants.IPCSocketPath` is the single source of truth. Both daemon and clients reference this constant.
- `getpeereid()` check: validates that the connecting process belongs to the same UID before processing any messages.
