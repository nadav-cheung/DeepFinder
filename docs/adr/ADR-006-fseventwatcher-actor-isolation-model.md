# ADR-006: FSEventWatcher + Actor Isolation Model

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

DeepFinder needs real-time filesystem monitoring to keep the in-memory index synchronized with disk. The Apple API for this is FSEvents (`FSEventStreamCreate`), which delivers batches of file change events via a **synchronous C callback** on a background dispatch queue.

This creates an impedance mismatch with Swift's structured concurrency model:

1. **FSEventStream callbacks are synchronous and run on an arbitrary queue.** They cannot use `await` -- there is no async context.
2. **Index mutations require cross-actor `await`.** `InMemoryIndex` is an `actor`. All insert/remove/update operations must be called with `await`.
3. **Event batches can arrive rapidly.** During bulk operations (e.g., `git checkout`, `npm install`), thousands of events may arrive in sub-second intervals. The index must process them without backpressure building up.

The naive solution -- calling `await` from the synchronous callback by spinning up a `Task {}` per event -- has two problems:
- Creates unbounded concurrency: thousands of simultaneous Tasks competing for the `InMemoryIndex` actor.
- No ordering guarantee: events may be processed out of order, causing index state inconsistencies (a "delete" processed before its preceding "create" could orphan a record).

## Decision

**Use an `AsyncStream` event pipe to bridge the synchronous FSEvents callback into Swift concurrency, with the `FSEventWatcher` itself modeled as an `actor`.**

Architecture (`Sources/FS/FSEventWatcher.swift`):

```
FSEventStream callback (sync, arbitrary queue)
    │
    │  eventContinuation.yield(EventBatch)
    ▼
AsyncStream<EventBatch>  (in-process pipe)
    │
    │  for await batch in stream
    ▼
FSEventWatcher actor  (serial event processing)
    │
    │  await index.insert/remove/update
    ▼
InMemoryIndex actor  (serial index mutations)
```

Key design elements:

1. **`FSEventWatcher` is an `actor`.** All mutable state (watched paths, index state, retry counters, restart timestamps) is protected by actor isolation. No locks, no dispatch queues, no data races.

2. **`AsyncStream<EventBatch>` bridges sync to async.** The synchronous event handler calls `eventContinuation.yield(EventBatch)`. A background `Task` drains the stream with `for await batch in stream`, providing an async context where `await` is valid. The stream is created via `AsyncStream.makeStream()` in `startEventProcessingLoop()`.

3. **Serial event processing.** The `for await` loop processes events one batch at a time, in order. Each event in the batch is processed sequentially with `await`. This preserves event ordering (a "create" is always processed before a subsequent "delete" on the same path).

4. **Bounded concurrency.** The event pipe is the only path into the processing loop. There is exactly one processing Task, so at most one batch is being processed at any time.

5. **Failure resilience with state machine.** The `IndexState` enum tracks the watcher lifecycle: `stale -> verifying -> live -> error -> polling`. On stream failure, exponential backoff retry (2s initial, 60s max, +/-20% jitter, up to 5 attempts). After 5 failed retries, degrade to 30s polling. If 3+ restarts within 10 minutes, also degrade to polling to avoid thrashing.

6. **Cursor persistence.** `FSEventStreamEventId` is saved to SQLite at `stopWatching()` for crash recovery. On restart, `sinceEventID` replays missed events.

## Consequences

**Positive:**

- **Clean async bridge.** `AsyncStream` is the standard Swift concurrency primitive for bridging callback-based APIs into async sequences. No third-party dependencies, no custom reactive streams.
- **Actor isolation guarantees.** The Swift compiler enforces that all mutable state access to `FSEventWatcher` happens on the actor's executor. No `@unchecked Sendable` hacks.
- **Event ordering preserved.** Serial batch processing within a single Task ensures that rapid create-delete pairs on the same path are handled correctly.
- **Graceful degradation.** The retry + polling fallback ensures the system is never permanently blind to filesystem changes, even under persistent FSEvents failures.
- **Testable.** `FileSystemEventStream` is a protocol. Tests inject a `MockEventStream` that fires synthetic events synchronously, verifying the watcher's event-handling logic without real filesystem I/O.

**Negative:**

- **Backpressure is implicit.** `AsyncStream` with the default unbounded buffering policy could accumulate events faster than they're processed. In practice, `EventBatch` objects are small (arrays of path strings) and the processing loop is fast (actor calls with no I/O). During pathological bursts (100K+ events), memory could spike. A future enhancement could use `AsyncStream` with a `.bufferingOldest` policy and a bounded buffer.
- **Single processing loop = single bottleneck.** All events funnel through one serial Task. During bulk operations, event processing latency may increase. However, the alternative (parallel event processing) would require careful ordering logic and conflict resolution. Serial processing is correct by construction.
- **Retry jitter is not cryptographically random.** `Double.random(in:)` is used for jitter calculation. For a local daemon, this is acceptable. A future security-sensitive context might require `SystemRandomNumberGenerator`.
- **Actor reentrancy awareness required.** `FSEventWatcher` methods use `await` to call into `InMemoryIndex`, which suspends the actor. During suspension, other messages could interleave. The current implementation avoids this issue because the processing loop is a linear `for await` -- no other task sends messages to the watcher during processing.

**Alternatives considered and rejected:**

- **`Task {}` per event in the callback:** Rejected for unbounded concurrency and ordering violations.
- **`DispatchQueue` with a lock around index state:** Rejected because `InMemoryIndex` is already an actor; wrapping it in a lock defeats the purpose and creates deadlock risk with bidirectional actor+lock calls.
- **`OSAllocatedUnfairLock` + `class` for FSEventWatcher:** Rejected because actor isolation provides the same guarantee with compiler enforcement. A manually-locked class is error-prone (forgotten unlocks, lock ordering).
- **Combine `PassthroughSubject`:** Rejected to maintain the zero-external-dependency policy. `AsyncStream` is built into the Swift standard library.
- **`AsyncChannel` (swift-async-algorithms):** Would work but requires an external dependency on swift-async-algorithms. The built-in `AsyncStream` is sufficient for a single-producer, single-consumer pipe.
