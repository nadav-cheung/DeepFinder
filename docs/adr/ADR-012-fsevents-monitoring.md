# ADR-012: FSEvents-Based Real-Time File Monitoring

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

DeepFinder must keep its in-memory index synchronized with the filesystem in near-real-time. When a user creates, deletes, renames, or modifies a file, the index should reflect the change within seconds — otherwise search results become stale and users lose trust in the tool.

On macOS, there are four approaches to detecting filesystem changes:

1. **Polling** — periodically scan the filesystem with `FileManager.contentsOfDirectory(atPath:)` or `FileManager.enumerator(at:)`, diff the results against the in-memory index, and apply updates.
2. **kqueue** (`kqueue`/`kevent`) — register per-directory kernel event filters (`EVFILT_VNODE`). The kernel delivers events when a watched directory changes.
3. **FSEvents** (`FSEventStreamCreate`) — register directory trees with the kernel's filesystem event daemon (`fseventsd`). Events are coalesced and delivered in batches via a C callback.
4. **EndpointSecurity** (`es_new_client`) — kernel-level authorization framework that intercepts every filesystem operation (open, create, rename, unlink, etc.) before it completes.

The choice must balance: event latency (how quickly changes appear in the index), CPU overhead (how much the monitoring consumes when idle), coverage (which directories can be monitored), reliability (event delivery guarantees during system sleep/wake), and implementation complexity.

## Decision

**Use FSEvents as the primary real-time monitoring mechanism, with periodic polling as a fallback after repeated FSEvents failures.**

The architecture has three layers:

### Layer 1: `FileSystemEventStream` protocol (`Sources/FS/FileSystemEventStream.swift:50`)

A Swift protocol abstracting the event source. Two implementations exist:

- **`FSEventStreamImpl`** (`Sources/FS/FSEventStreamImpl.swift:19`) — production implementation wrapping `FSEventStreamCreate` with a serial dispatch queue.
- **`MockEventStream`** (`Tests/`) — test implementation that fires synthetic events synchronously, enabling deterministic testing of the watcher's event-handling logic without real filesystem I/O.

### Layer 2: `FSEventStreamImpl` — raw FSEvents wrapper

Configuration:
- **Flags**: `kFSEventStreamCreateFlagUseCFTypes` (required for CFString path extraction), `kFSEventStreamCreateFlagFileEvents` (file-level granularity — get per-file events, not just per-directory), `kFSEventStreamCreateFlagNoDefer` (immediate delivery — no additional coalescing by the daemon), `kFSEventStreamCreateFlagWatchRoot` (monitor the roots themselves, not just their contents).
- **Latency**: 0.5 seconds (`Constants.Scan.fsEventLatency`). This is the minimum coalescing window — FSEvents will wait at least this long before delivering a batch to merge duplicate events on the same file.
- **Dispatch queue**: Serial `DispatchQueue` with QoS `.utility`. The FSEventStream callback runs on this queue. All mutable state (`stream: FSEventStreamRef?`, `_isRunning`, `eventHandler`) is protected by `queue.sync {}` access.

The synchronous C callback extracts paths from the `CFArray` of event paths, pairs each with its `FSEventStreamEventFlags`, and invokes the Swift `eventHandler` closure:

```swift
let impl = Unmanaged<FSEventStreamImpl>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
let pathArray = unsafeBitCast(eventPaths, to: CFArray.self)
for i in 0..<Int(numEvents) {
    let path = unsafeBitCast(CFArrayGetValueAtIndex(pathArray, i), to: CFString.self) as String
    events.append((path: path, flags: eventFlags[i]))
}
impl.eventHandler?(events)
```

### Layer 3: `FSEventWatcher` actor — event processing and lifecycle management

The `FSEventWatcher` actor (`Sources/FS/FSEventWatcher.swift`) bridges the synchronous event stream into Swift structured concurrency and translates raw events into index mutations:

```
FSEventStream callback (sync, dispatch queue)
    │  eventContinuation.yield(EventBatch)
    ▼
AsyncStream<EventBatch>  (in-process pipe)
    │  for await batch in stream
    ▼
FSEventWatcher actor (serial processing)
    │  await index.insert/remove
    ▼
InMemoryIndex actor
```

Key lifecycle behaviors:

- **State machine**: `stale → verifying → live → error → polling`
  - `stale`: index loaded from disk but not monitoring
  - `verifying`: attempting to start the event stream
  - `live`: actively receiving and processing events
  - `error`: stream failed, retrying with backoff
  - `polling`: degraded to periodic scanning after max retries

- **Exponential backoff retry**: Initial 2s delay, doubling each attempt up to 60s max, with +/-20% jitter. After 5 failed attempts, degrades to polling.

- **Burst detection**: If 3+ stream restarts occur within 10 minutes, immediately degrade to polling to avoid thrashing.

- **Cursor persistence**: `FSEventStreamEventId` saved to SQLite via `IndexPersistence.saveEventCursor(_:)` on shutdown. On restart, the stream resumes from `sinceEventID` to replay any events missed during downtime.

- **Dropped event handling**: If `kFSEventStreamEventFlagUserDropped` or `kFSEventStreamEventFlagKernelDropped` flags appear in any event, treat as a full rescan trigger: stop the stream, optionally degrade to polling if restarts are too frequent.

### Polling fallback

When degraded to polling (`IndexState.polling`), the watcher runs `performPollingScan()` every 30 seconds:

1. Snapshot current index state (all paths + modification dates).
2. Walk watched paths with `FileManager.enumerator(at:includingPropertiesForKeys:)`.
3. For each file on disk: if present in index with different `modificationDate`, treat as modified. If absent from index, treat as created.
4. After scan: any index entry not seen on disk is treated as deleted.
5. Apply all diffs to `InMemoryIndex`.

This is a full filesystem walk — expensive but correct. It ensures eventual consistency even if FSEvents is permanently unavailable on a given system configuration.

## Alternatives Considered

### A. Polling Only (FileManager scan every N seconds)

Periodically enumerate all watched directories and diff against the index.

**Rejected because:**
- **Extreme CPU cost.** Walking a filesystem with 1M+ files every 30 seconds means stat-ing 1M files. On a modern Mac with an SSD, this still takes seconds and consumes significant CPU.
- **High latency.** With a 30-second interval, file changes take up to 30 seconds to appear in search results. For interactive use, this is unacceptable.
- **Battery impact.** Continuous I/O from polling prevents the disk from spinning down and keeps the CPU awake.
- **Doesn't scale.** The cost grows linearly with filesystem size. FSEvents cost is O(changes), not O(total files).

### B. kqueue (per-directory kernel events)

Register `EVFILT_VNODE` on every directory in the watched tree. The kernel delivers events when files are added or removed from a directory.

**Rejected because:**
- **Doesn't scale to large directory trees.** A typical macOS home directory has 10,000+ directories. kqueue has a per-process file descriptor limit. Each watched directory consumes a file descriptor. Monitoring 10,000 directories would require adjusting `kern.maxfilesperproc` and risks exhausting the fd table.
- **Recursive watching requires manual tree management.** kqueue doesn't support recursive watching. You must manually discover new directories (from `NOTE_WRITE` events) and register kqueues for them. This is error-prone: missed `NOTE_WRITE` events mean newly created directories go unwatched.
- **No event coalescing.** kqueue delivers every event individually. During `git checkout` (which touches thousands of files), this floods the event loop. FSEvents coalesces events within its latency window, reducing the per-event overhead.
- **No `fseventsd` log replay.** If the daemon stops (crash, upgrade, reboot), kqueue has no mechanism to replay missed events. FSEvents provides `sinceEventID` for exactly this purpose.

### C. EndpointSecurity

Use the `EndpointSecurity` framework (`es_new_client`) to subscribe to filesystem authorization events at the kernel level. This gives per-operation events (open, create, rename, unlink, exchange, etc.) with full path information before the operation completes.

**Rejected because:**
- **Requires System Extension.** EndpointSecurity clients must ship as a System Extension (bundled in an app, approved by the user in System Settings > Privacy & Security). This adds significant distribution and user-experience complexity: users must approve the extension in System Settings, the extension must be signed with a Developer ID and notarized, and the approval UI is intimidating.
- **Requires Full Disk Access anyway.** EndpointSecurity doesn't exempt you from the TCC permission model. DeepFinder already requires Full Disk Access for file metadata reading.
- **Too heavy for a file search tool.** EndpointSecurity is designed for security products (antivirus, EDR, DLP). It intercepts EVERY filesystem operation system-wide — including operations by system daemons, other apps, and the kernel. Filtering this firehose to only file creations/deletions/modifications requires a kernel-level event filter (ES framework's `es_mute_path` or event subscriptions) that is complex to configure correctly.
- **Performance impact.** Every `open()` syscall on the system passes through the ES client. A misconfigured filter imposes overhead on the entire system. FSEvents is passive: it reads from `fseventsd`'s log, which is maintained regardless.
- **No benefit for this use case.** DeepFinder needs "file X changed" — not "process Y opened file X with flags Z." The additional context EndpointSecurity provides is irrelevant.

## Consequences

### Positive

- **Near-real-time updates.** With `kFSEventStreamCreateFlagNoDefer` and a 0.5s latency window, file changes appear in the index within ~2 seconds end-to-end (0.5s coalescing + processing time). Most changes appear faster because FSEvents may deliver before the latency window expires.
- **Low CPU overhead when idle.** FSEvents is passive: it reads from `fseventsd`'s in-kernel event log. When no files are changing, the daemon's FSEvents thread is idle, consuming zero CPU.
- **O(changes), not O(total files).** Only changed files generate events. The cost of monitoring does not grow with the size of the filesystem.
- **Event replay for crash recovery.** `FSEventStreamEventId` persistence means the daemon can resume monitoring after a crash without missing events (within `fseventsd`'s log retention window, typically hours to days).
- **Testable.** `FileSystemEventStream` protocol allows `MockEventStream` injection. Tests can fire synthetic events and verify that the watcher correctly translates them into index mutations.
- **Built into macOS.** No third-party dependencies, no kernel extensions, no special entitlements beyond Full Disk Access (which DeepFinder already needs).
- **Graceful degradation.** The polling fallback ensures the index never goes permanently stale, even under persistent FSEvents failures.

### Negative

- **Coalesced events.** FSEvents coalesces multiple events on the same file within the latency window. A rapid create-delete pair on the same path may be delivered as a single "modified" event or not at all. DeepFinder handles this by re-stat-ing the file on each event: if the file exists, treat as create/modify; if not, treat as delete. This is correct but means the intermediate state (file existed for 200ms) is never observed.
- **No old/new path in rename events.** FSEvents reports renames as a pair of events (delete at old path, create at new path) WITHOUT linking them. There is no `rename(from:to:)` — just two independent events. DeepFinder handles this by: on rename event, check if the file exists at the reported path. If yes, insert/update. If no, remove. This means the rename is seen as a delete+insert, not an atomic rename. The inode is not tracked, so metadata changes during rename may cause a brief inconsistency.
- **No content change detection.** FSEvents reports that a file was "modified" but does not specify WHAT changed (content vs. metadata vs. both). DeepFinder re-stats the file to get updated metadata. Content changes that don't affect metadata (e.g., `echo "text" >> file` where the modification date already matches the current second) may not be detected.
- **Latency on network volumes.** FSEvents relies on `fseventsd` which operates on locally-mounted volumes. Network volumes (AFP, SMB, NFS) may not generate events or may generate them with significant delay. DeepFinder's polling fallback covers this case.
- **Full Disk Access requirement.** FSEvents can monitor any directory, but directories protected by TCC (~/Documents, ~/Desktop, ~/Downloads) require Full Disk Access. Without FDA, FSEvents silently delivers no events for these directories. DeepFinder's documentation and install flow make FDA a requirement.

### Mitigation

1. **Re-stat on every event.** The `handleFileCreated`, `handleFileModified`, and `handleFileRenamed` methods re-read file metadata from disk using `URL.resourceValues(forKeys:)`. This detects the current state regardless of coalescing.
2. **Polling fallback.** The 30-second polling interval after FSEvents failure catches any events missed due to coalescing or network volume limitations.
3. **Cursor persistence.** Saving `FSEventStreamEventId` on every clean shutdown ensures crash recovery can replay missed events.
4. **Burst detection.** The 3-restarts-in-10-minutes threshold prevents the daemon from endlessly retrying against a broken FSEvents configuration.
5. **Root-path watching.** Watching `["/"]` ensures all locally-mounted volumes are covered. External and network volumes are discovered and added dynamically.

## Related

- [ADR-006](ADR-006-fseventwatcher-actor-isolation-model.md) — FSEventWatcher's actor isolation model and AsyncStream bridge
- [ADR-008](ADR-008-daemon-thin-client-architecture.md) — Daemon lifecycle and auto-start
- [ADR-009](ADR-009-sqlite-index-persistence.md) — Cursor persistence via SQLite
- [ADR-011](ADR-011-actor-based-concurrency.md) — Actor-based concurrency model for event processing
