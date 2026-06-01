# ADR-002: IPC Protocol Design (4-Byte Length Prefix + JSON vs Newline-Delimited)

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

The DeepFinder daemon communicates with CLI and GUI clients over a Unix domain socket at `~/.deep-finder/ipc.sock`. We needed a framing protocol that:

1. **Works over a stream socket.** Unix domain sockets (SOCK_STREAM) are byte streams, not message-oriented. The receiver needs a way to find message boundaries.
2. **Is trivially debuggable.** Operators should be able to inspect traffic with `nc -U ~/.deep-finder/ipc.sock`.
3. **Supports structured data.** Messages include queries, results, stats, configuration, and cancellations -- each with different payload shapes.
4. **Allows forward compatibility.** New CLI versions must detect when talking to an older daemon and vice versa.

Two framing approaches were considered:

**Option A: 4-byte big-endian length prefix + JSON body**
```
[4 bytes: UInt32 big-endian payload length][N bytes: JSON payload]
```

**Option B: Newline-delimited JSON (NDJSON)**
```
{"kind":"query","query":"report.pdf","limit":100}\n
```

## Decision

**Chose Option A: 4-byte big-endian length prefix + JSON body.**

Implemented in `Sources/Daemon/IPCProtocol.swift` as the `IPCFraming` enum:

- `addLengthPrefix(to:)` — prepends a 4-byte `UInt32` big-endian length header
- `stripLengthPrefix(from:)` — reads the header, validates the payload is complete, returns payload only
- `encode<T: Codable>(_:)` / `decode<T: Codable>(_:from:)` — convenience wrappers combining framing + JSON coding

The `IPCRequest` and `IPCResponse` enums use a `kind` discriminator field for polymorphic encoding, plus an `ipcProtocolVersion` field (currently `1`) embedded in every request for forward-compatibility detection.

## Consequences

**Positive:**

- **Deterministic framing.** The 4-byte length prefix is unambiguous. The receiver knows exactly how many bytes to read before attempting JSON parsing. No risk of splitting on a `\n` that appears inside a JSON string.
- **Binary-safe.** JSON payloads containing multi-byte UTF-8 characters (common in file paths with Chinese, Japanese, or emoji names) do not risk false delimiter matches.
- **Efficient.** One `read()` of the length prefix tells the receiver exactly how much more to read. No byte-by-byte scanning for newlines.
- **Debuggable.** The JSON body is human-readable. `nc -U` can still display it (though you see the binary header as 4 garbage bytes first). For debugging, the daemon can also log decoded messages.
- **Forward-compatible.** The `ipcProtocolVersion` field is checked before message processing. An old daemon receiving a v2 request can return a clear error rather than crashing on unknown fields.

**Negative:**

- **Not strictly newline-compatible.** `nc -U` output shows 4 binary header bytes before each JSON message. Slightly less convenient for ad-hoc debugging than pure NDJSON.
- **Extra encoding step.** Length-prefix framing requires the sender to know the full payload size before writing. With NDJSON, you could stream-write incrementally. In practice, our messages are small (kilobytes at most) and buffered in memory anyway.
- **Endianness coupling.** The `bigEndian` convention must be consistent on both sides. Since both CLI and daemon run on the same macOS arm64 machine, this is moot, but would matter for a remote IPC extension.

**Alternative considered but rejected:**

NDJSON was rejected because:
- JSON strings can contain literal `\n` characters (e.g., in file paths or error messages), which would falsely trigger message boundaries unless we mandated escaping, adding complexity.
- Byte-by-byte scanning for `\n` is marginally less efficient than reading a length prefix.
- The "just pipe to `nc`" debugging benefit of NDJSON was not deemed worth the robustness tradeoff.
