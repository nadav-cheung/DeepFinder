# ADR-011: Actor-Based Concurrency Model

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

DeepFinder's daemon process holds a large in-memory index with four separate data structures (Trie, FullSubstringMap, TrigramIndex, PinyinIndex) that must be accessed concurrently by:

1. **FSEventWatcher** — continuously mutating the index as filesystem events arrive (~hundreds per second during bulk operations like `git checkout` or `npm install`).
2. **SearchCoordinator** — reading the index in response to user queries from CLI and GUI clients (sub-millisecond latency target).
3. **FileScanner** — writing records during initial scan (millions of inserts on first run).
4. **IPCServer** — reading stats (record count, memory usage) to serve daemon status requests.

This is a classic single-writer, multi-reader problem with a twist: the "writer" (FSEventWatcher) produces a firehose of mutations, and the "readers" (search queries) must never block or return inconsistent intermediate state.

Before Swift 5.5 introduced actors and structured concurrency, macOS developers had three main options for shared-mutable-state protection: Grand Central Dispatch serial queues, `NSLock`/`pthread_mutex_t`, or `OSAllocatedUnfairLock`. Each comes with well-known footguns: deadlocks from lock ordering, forgotten unlocks, priority inversion, and the absence of compile-time enforcement.

Swift actors provide a new option: compiler-enforced isolation that guarantees no data race can occur on actor-isolated state. The Swift 6 language mode (which DeepFinder targets) makes these guarantees even stronger with strict sendability checking.

## Decision

**Use Swift actors as the primary concurrency primitive for all mutable shared state.** The three core components are modeled as actors:

1. **`InMemoryIndex`** (`Sources/Index/InMemoryIndex.swift:48`) — owns the four index structures (Trie, FullSubstringMap, TrigramIndex, PinyinIndex) plus the `FileRecord` store (`records: [UInt32: FileRecord]`) and path-to-ID mapping. All insert/remove/search operations are actor-isolated. The sub-index structures are value types (structs), so no internal locking is needed — only the actor's serial executor provides mutual exclusion.

    ```swift
    actor InMemoryIndex {
        private var records: [UInt32: FileRecord] = [:]
        private var pathToID: [String: UInt32] = [:]
        private var trie = Trie<UnicodeScalar, Set<UInt32>>()
        private var substringMap = FullSubstringMap()
        private var trigramIndex = TrigramIndex()
        private var pinyinIndex = PinyinIndex()

        func insert(_ record: FileRecord) { /* ... */ }
        func search(query: String) -> [FileRecord] { /* hybrid search across all 4 structures */ }
        func allRecords() -> [FileRecord] { Array(records.values) }
    }
    ```

2. **`SearchCoordinator`** (`Sources/Search/SearchCoordinator.swift:46`) — orchestrates multi-provider search with cancellation and deduplication. Dispatches queries to all registered providers concurrently via `withTaskGroup`, collects results, deduplicates by `FileRecord.id`, applies filters, sorts by relevance, and caps at `resultLimit`. NOT `@MainActor` — works in both daemon and GUI contexts.

3. **`FSEventWatcher`** (`Sources/FS/FSEventWatcher.swift`) — bridges the synchronous FSEvents C callback into Swift structured concurrency via an internal `AsyncStream<EventBatch>` pipe. The synchronous callback yields event batches into the stream; a background `Task` drains them with `for await`, providing an async context where `await index.insert(...)` is valid. All mutable state (watched paths, index state, retry counters, restart timestamps) is actor-isolated.

The **actor ensemble** is orchestrated by `DaemonMain.run()` (`Sources/Daemon/DaemonMain.swift:379`):

```
DaemonMain (final class)
  ├── InMemoryIndex (actor)
  │     ├── Trie<UnicodeScalar, Set<UInt32>> (struct, COW)
  │     ├── FullSubstringMap (struct)
  │     ├── TrigramIndex (struct)
  │     └── PinyinIndex (struct)
  ├── SearchCoordinator (actor)
  │     └── FileIndexProvider → InMemoryIndex
  ├── FSEventWatcher (actor)
  │     ├── FileSystemEventStream → FSEventStreamImpl
  │     ├── InMemoryIndex (cross-actor await)
  │     └── IndexPersistence (cursor save/load)
  └── IPCServer (actor)
        └── SearchCoordinator (cross-actor await)
```

The dependency direction is one-way and acyclic: `DaemonMain → IPCServer → SearchCoordinator → InMemoryIndex`. No actor calls back into a caller — all communication is request/response through `await`.

## Alternatives Considered

### A. DispatchQueue Serial Queues

Each component gets its own serial `DispatchQueue`. Mutable state is accessed inside `queue.sync {}` or `queue.async {}` blocks.

**Rejected because:**
- **No compile-time safety.** Forgetting to wrap a property access in `queue.sync` is a data race that compiles silently. Swift actors make this a compile error.
- **Deadlock risk with cross-queue calls.** If queue A's block calls `queueB.sync {}` and queue B's block calls `queueA.sync {}`, you get a deadlock. Actors avoid this by allowing reentrancy (suspension points release the executor).
- **No async/await integration.** Calling `await` from a queue block requires hoisting into a `Task`, losing the queue's serial ordering guarantee.
- **Boilerplate.** Every property needs a `queue.sync` wrapper or a private backing field with a computed getter/setter that dispatches. Actors eliminate this: `actor` keyword + direct property access.

### B. NSLock / pthread_mutex_t / OSAllocatedUnfairLock

Each component wraps its mutable state in a lock. Methods acquire the lock at entry and release at exit.

**Rejected because:**
- **Forgotten unlocks.** A `return` statement added in a later refactor could skip the `unlock()` call. Swift's `defer { lock.unlock() }` mitigates this but is still manual and error-prone.
- **Lock ordering deadlocks.** If `InMemoryIndex.search()` (holding the index lock) needs to access `FSEventWatcher` state (holding the watcher lock), and `FSEventWatcher.processBatch()` does the reverse, you get a deadlock. Actors avoid this because `await` across actors releases the executor.
- **No integration with Swift concurrency.** Holding a lock across an `await` is a runtime error (Swift's cooperative thread pool can't make progress while a lock is held). Actors are designed for this: `await` suspends the actor, allowing other messages to be processed.
- **Performance on contended locks.** `OSAllocatedUnfairLock` is fast for uncontended access, but under contention (search queries arriving while FSEvents are being processed), threads spin and waste CPU. Actors queue work on a serial executor without spinning.

### C. Single DispatchQueue + Class with @unchecked Sendable

Everything runs on one serial queue. The daemon is a single class marked `@unchecked Sendable`.

**Rejected because:**
- **No parallelism between search and indexing.** A long search (e.g., content search scanning files) would block FSEvents processing. Separate actors allow search and indexing to make progress independently (the executor can interleave work at `await` points).
- **Fake concurrency guarantee.** `@unchecked Sendable` tells the compiler "trust me, I handled thread safety." It provides zero safety. Actors provide a proved safety guarantee.
- **Monolithic concurrency domain.** One queue for everything means one bottleneck. Actor-per-component allows the runtime to schedule work optimally.

## Consequences

### Positive

- **Compile-time data race safety.** The Swift 6 compiler rejects any code that accesses actor-isolated state from outside the actor without `await`. This catches entire categories of bugs at build time.
- **Deadlock prevention by design.** Actors use cooperative concurrency with reentrancy: when an actor method calls `await`, the executor is released and can process other messages. There is no "hold and wait" — the precondition for deadlock.
- **Natural separation of concerns.** Each actor owns exactly its domain. `InMemoryIndex` owns index state. `SearchCoordinator` owns provider coordination. `FSEventWatcher` owns filesystem event processing. No shared locks, no lock ordering, no confusion about who owns what.
- **No manual synchronization.** Zero `NSLock`, zero `pthread_mutex_t`, zero `DispatchQueue.sync`, zero `OSAllocatedUnfairLock`. All synchronization is the `actor` keyword and `await`.
- **Clean async/await integration.** Cross-actor calls read like synchronous code: `await index.insert(record)`. The control flow is linear and obvious.
- **Testable in isolation.** Each actor can be instantiated and tested independently. `MockEventStream` implements `FileSystemEventStream` to test `FSEventWatcher` without real FSEvents. The `InMemoryIndex` can be tested directly without a daemon.

### Negative

- **Actor reentrancy.** An actor method that calls `await` suspends and allows other messages to be processed before resuming. This means actor state can change between the `await` and the next line. For example, if `InMemoryIndex.insert()` called `await` between checking for an existing record and writing, another insertion could interleave. DeepFinder mitigates this by keeping actor methods synchronous (no internal `await` calls) where possible — `InMemoryIndex.insert()`, `remove()`, and `search()` are all synchronous methods that complete without suspension. Cross-actor `await` happens only at the call site (e.g., `await index.insert(record)` from `FSEventWatcher`), not inside the actor method.

- **Async call overhead.** Every cross-actor call requires a suspension point and executor handoff. For millions of insertions during initial scan, this adds measurable overhead compared to direct method calls. Mitigation: the initial scan batches records and inserts them sequentially (one `await` per record), not in a tight loop — the overhead is negligible compared to filesystem I/O. For production search queries, the actor hop is microseconds out of a sub-millisecond total query time.

- **Strict sendability requirements.** Swift 6 requires that all values passed across actor boundaries be `Sendable`. `FileRecord`, `SearchResult`, `SearchQuery`, and all IPC message types must explicitly conform to `Sendable`. This requires discipline but catches real bugs (e.g., accidentally sharing a mutable reference type across actors).

- **Actor hopping in the critical path.** A user query from CLI traverses: `IPCClient (Task) → IPCServer (actor) → SearchCoordinator (actor) → FileIndexProvider → InMemoryIndex (actor)`. This is two actor hops (IPCServer → SearchCoordinator, SearchCoordinator → InMemoryIndex). Each hop is a suspension and executor handoff. The total latency is still <1ms because Swift actors use a lightweight cooperative executor, not OS threads.

### Mitigation

1. **Synchronous actor methods where possible.** `InMemoryIndex.insert()`, `remove()`, and `search()` are fully synchronous — they complete without any internal `await`. This eliminates reentrancy concerns inside the index.
2. **Value-type index structures.** Trie, FullSubstringMap, TrigramIndex, and PinyinIndex are all structs. They are copied by value and cannot be shared accidentally. No `Sendable` conformance needed; no internal synchronization needed.
3. **AsyncStream for callback bridging.** The FSEventWatcher's `AsyncStream` pipe is the only place where synchronous code (the FSEvents C callback) meets async code. It is a single-producer, single-consumer pipe with clear ownership boundaries.
4. **Task.detached for blocking calls.** `FSEventStreamImpl.start()` uses `queue.sync` internally (it wraps the C FSEvents API which requires a dispatch queue). The `FSEventWatcher.attemptStartOrRetry()` method hoists this off the actor via `Task.detached`, preventing the synchronous `queue.sync` from blocking the Swift concurrency cooperative thread pool.

## Codebase Examples

### Cross-actor search flow (IPC → SearchCoordinator → InMemoryIndex)

From `SearchCoordinator.search()` (`Sources/Search/SearchCoordinator.swift:82`):

```swift
func search(query rawQuery: String, filters: [SearchFilter] = []) async -> [SearchResult] {
    // Cancel previous in-flight query across all providers
    await withTaskGroup(of: Void.self) { group in
        for provider in providers {
            group.addTask { await provider.cancel(queryID: previousID) }
        }
    }

    // Dispatch to all providers concurrently
    let allResults = await withTaskGroup(of: [SearchResult].self) { group in
        for provider in providers {
            group.addTask {
                let sequence = await provider.search(query: query)
                var results: [SearchResult] = []
                for await result in sequence { results.append(result) }
                return results
            }
        }
        // ...
    }
    // Deduplicate, filter, sort, cap...
}
```

### AsyncStream bridge for FSEvents (callback → actor)

From `FSEventWatcher.startEventProcessingLoop()` (`Sources/FS/FSEventWatcher.swift:212`):

```swift
private func startEventProcessingLoop() {
    let (stream, continuation) = AsyncStream<EventBatch>.makeStream()
    self.eventContinuation = continuation

    processingTask = Task { [weak self] in
        for await batch in stream {
            await self?.processEventBatch(batch.events)
        }
    }
}
```

The synchronous FSEvents callback calls `continuation.yield(EventBatch(events: events))`. The processing `Task` drains them with full async/await support, enabling cross-actor calls to `InMemoryIndex`.

### Actor ensemble orchestration (DaemonMain)

From `DaemonMain.run()` (`Sources/Daemon/DaemonMain.swift:379`):

```swift
let index = InMemoryIndex()
// Rebuild from persistence
for record in records { await index.insert(record) }

let coordinator = SearchCoordinator(providers: [FileIndexProvider(index: index)])
let ipcServer = IPCServer(socketPath: ..., coordinator: coordinator, ...)
try await ipcServer.start()

let watcher = FSEventWatcher(eventStream: eventStream, index: index, persistence: persistence)
try await watcher.startWatching(paths: ["/"], sinceEventID: cursor ?? 0)
```

The three actors (`InMemoryIndex`, `SearchCoordinator`, `FSEventWatcher`) are created and wired together in `DaemonMain.run()`. They operate independently, communicating only through `await` calls. The daemon's lifecycle is: create actors → wire dependencies → start services → suspend until shutdown signal.

## Related

- [ADR-006](ADR-006-fseventwatcher-actor-isolation-model.md) — FSEventWatcher's actor isolation and AsyncStream pipe design
- [ADR-008](ADR-008-daemon-thin-client-architecture.md) — Daemon + thin client architecture
- [ADR-012](ADR-012-fsevents-monitoring.md) — FSEvents as the event source
- [ADR-013](ADR-013-hybrid-index-structure.md) — Index data structures protected by actor isolation
