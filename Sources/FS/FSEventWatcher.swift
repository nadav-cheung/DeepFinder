import Foundation
import OSLog

/// Index state machine for the file watcher.
///
/// ```
/// stale -> (startWatching) -> verifying -> (stream active) -> live
/// live -> (stop/error) -> stale
/// live -> (stream failure, retrying) -> error
/// error -> (max retries exceeded) -> polling
/// ```
enum IndexState: String, Sendable {
    /// Index loaded from disk but potentially stale.
    case stale
    /// Verifying index against current filesystem.
    case verifying
    /// Actively receiving FSEvents updates.
    case live
    /// FSEvents stream failed, retrying with backoff.
    case error
    /// Degraded to periodic polling after max retries.
    case polling
}

// MARK: - Watcher Errors

/// Errors produced by ``FSEventWatcher`` during stream lifecycle management.
enum FSEventWatcherError: Error, Sendable {
    /// The FSEventStream failed to start.
    case streamStartFailed(reason: String)
    /// Maximum retries exceeded; degraded to polling.
    case maxRetriesExceeded
}

// MARK: - Internal Event Type

/// Wrapper for a batch of raw events, used to pipe events from the
/// synchronous FSEventStream handler into the async processing loop.
private struct EventBatch: Sendable {
    let events: [(path: String, flags: FSEventStreamEventFlags)]
}

// MARK: - FSEventWatcher

/// Real-time file system watcher that translates FSEvents into index updates.
///
/// Coordinates between:
/// - `FileSystemEventStream` (event source — production FSEventStreamImpl or MockEventStream)
/// - `InMemoryIndex` (index mutations — insert/remove/update)
/// - `IndexPersistence` (cursor persistence for restart recovery)
///
/// **Event mapping:**
/// - `created` -> insert FileRecord into index
/// - `deleted` -> remove FileRecord from index
/// - `renamed` -> remove old path + insert new path
/// - `modified` -> re-stat file and update metadata
///
/// **Failure handling:**
/// - Stream start failure: exponential backoff retry (2s initial, 60s max, +/-20% jitter), up to 5 attempts
/// - After 5 failed retries: degrade to polling mode (30s interval)
/// - kFSEventStreamEventFlagUserDropped / KernelDropped during live: restart stream
/// - If 3+ restarts in 10 minutes: degrade to polling
///
/// **Architecture:**
/// The FSEventStream handler is synchronous, but index mutations require cross-actor
/// `await` calls to InMemoryIndex. We bridge this gap with an internal `AsyncStream`
/// event pipe. The synchronous handler enqueues event batches; a background processing
/// loop drains them with proper async/await support.
actor FSEventWatcher {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.nadav.deepfinder.daemon", category: "fswatcher")

    // MARK: - Configuration

    /// Maximum number of retry attempts before degrading to polling.
    static let maxRetryAttempts = 5

    /// Initial retry delay in seconds.
    static let initialRetryDelay: TimeInterval = 2.0

    /// Maximum retry delay in seconds.
    static let maxRetryDelay: TimeInterval = 60.0

    /// Jitter factor (+/-20%).
    static let jitterFactor: Double = 0.2

    /// Polling interval in seconds when degraded.
    static let pollingInterval: TimeInterval = 30.0

    /// Maximum stream restarts within the restart window before degrading to polling.
    static let maxRestartsInWindow = 3

    /// Time window (seconds) for counting restarts.
    static let restartWindow: TimeInterval = 600.0 // 10 minutes

    // MARK: - Dependencies

    private let eventStream: FileSystemEventStream
    private let index: InMemoryIndex
    private let persistence: IndexPersistence

    // MARK: - Event Pipe

    /// Continuation for the internal event pipe.
    private var eventContinuation: AsyncStream<EventBatch>.Continuation?

    /// Task running the event processing loop.
    private var processingTask: Task<Void, Never>?

    // MARK: - Mutable State

    /// Current index state.
    private var _indexState: IndexState = .stale

    /// Paths being watched.
    private var watchedPaths: [String] = []

    /// Current FSEvents cursor for resumption.
    private var currentEventID: UInt64 = 0

    /// Number of consecutive retry attempts.
    private var retryAttemptCount = 0

    /// Whether we've degraded to polling mode.
    private var isPolling = false

    /// Task for the polling timer.
    private var pollingTask: Task<Void, Never>?

    /// Task for retry attempts.
    private var retryTask: Task<Void, Never>?

    /// Timestamps of recent stream restarts (for burst detection).
    private var recentRestarts: [Date] = []

    /// Whether the watcher has been explicitly stopped by the user.
    private var isStopped = true

    // MARK: - Public API

    /// Current index state.
    var indexState: IndexState {
        _indexState
    }

    /// Create a new watcher.
    init(
        eventStream: FileSystemEventStream,
        index: InMemoryIndex,
        persistence: IndexPersistence
    ) {
        self.eventStream = eventStream
        self.index = index
        self.persistence = persistence
    }

    /// Start watching the given paths for file system events.
    ///
    /// - Parameters:
    ///   - paths: Directory paths to monitor for changes.
    ///   - sinceEventID: The last FSEvent ID to resume from. Pass `0` to start from now.
    /// - Throws: `FSEventWatcherError.streamStartFailed` if the event stream cannot be created.
    ///   Note: most start failures are handled internally via retry with backoff rather than thrown.
    func startWatching(paths: [String], sinceEventID: UInt64) async throws {
        watchedPaths = paths
        currentEventID = sinceEventID
        isStopped = false
        retryAttemptCount = 0

        _indexState = .verifying

        // Start the internal event processing loop
        startEventProcessingLoop()

        await attemptStartOrRetry()
    }

    /// Stop watching. Saves cursor to persistence layer.
    func stopWatching() async {
        isStopped = true

        // Cancel retry/polling tasks
        retryTask?.cancel()
        retryTask = nil
        pollingTask?.cancel()
        pollingTask = nil

        // Stop the event stream
        eventStream.stop()

        // Stop the processing loop
        eventContinuation?.finish()
        eventContinuation = nil
        processingTask?.cancel()
        processingTask = nil

        _indexState = .stale

        // Save cursor persistently — await to ensure it's saved before returning
        await persistence.saveEventCursor(currentEventID)
    }

    // MARK: - Event Processing Loop

    /// Start the internal AsyncStream-based event processing loop.
    ///
    /// This creates an `AsyncStream<EventBatch>` that the synchronous event handler
    /// can write to (via `eventContinuation`), and a background Task that reads from
    /// it with full async/await support for cross-actor calls.
    private func startEventProcessingLoop() {
        let (stream, continuation) = AsyncStream<EventBatch>.makeStream()
        self.eventContinuation = continuation

        processingTask = Task { [weak self] in
            for await batch in stream {
                await self?.processEventBatch(batch.events)
            }
        }
    }

    // MARK: - Private: Start / Retry Logic

    /// Attempt to start the event stream, or retry with backoff if it fails.
    ///
    /// Uses `Task.detached` to call `eventStream.start()` off the actor, avoiding
    /// blocking the Swift concurrency cooperative thread pool with `queue.sync`
    /// inside `FSEventStreamImpl`. The continuation is captured locally before
    /// the detached task so no actor-isolated state is accessed from the callback.
    private func attemptStartOrRetry() async {
        guard !isStopped else { return }

        // Capture values before hopping off the actor.
        // AsyncStream.Continuation is Sendable — safe to pass across isolation.
        let continuation = eventContinuation
        let paths = watchedPaths
        let eventID = currentEventID
        let es = eventStream

        // Run the blocking start() call outside the actor.
        let running: Bool = await Task.detached {
            es.start(paths: paths, sinceEventID: eventID) { events in
                continuation?.yield(EventBatch(events: events))
            }
            return es.isRunning
        }.value

        if running {
            _indexState = .live
            retryAttemptCount = 0
            recordRestart()
        } else {
            await handleStreamStartFailure()
        }
    }

    /// Handle a stream start failure.
    private func handleStreamStartFailure() async {
        retryAttemptCount += 1

        if retryAttemptCount >= Self.maxRetryAttempts {
            degradeToPolling()
            return
        }

        _indexState = .error

        let delay = Self.retryDelay(forAttempt: retryAttemptCount)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.attemptStartOrRetry()
        }
    }

    /// Calculate exponential backoff delay with jitter.
    ///
    /// Formula: `min(initialDelay * 2^(attempt-1), maxDelay)` +/- 20% jitter.
    /// The result is always at least `initialRetryDelay`.
    ///
    /// - Parameter attempt: 1-based retry attempt number.
    /// - Returns: Delay in seconds before the next retry.
    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let baseDelay = min(
            initialRetryDelay * pow(2.0, Double(attempt - 1)),
            maxRetryDelay
        )
        let jitterRange = baseDelay * jitterFactor
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(initialRetryDelay, baseDelay + jitter)
    }

    /// Record a stream restart timestamp for burst detection.
    private func recordRestart() {
        let now = Date()
        recentRestarts.append(now)
        let cutoff = now.addingTimeInterval(-Self.restartWindow)
        recentRestarts.removeAll { $0 < cutoff }
    }

    /// Check if we've had too many restarts recently.
    private func hasTooManyRestarts() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.restartWindow)
        let recentCount = recentRestarts.filter { $0 >= cutoff }.count
        return recentCount >= Self.maxRestartsInWindow
    }

    // MARK: - Private: Event Processing

    /// Process a batch of raw FSEvents. Called from the async processing loop,
    /// so cross-actor calls to InMemoryIndex are valid with `await`.
    private func processEventBatch(_ events: [(path: String, flags: FSEventStreamEventFlags)]) async {
        for event in events {
            let path = event.path
            let flags = event.flags

            // Check for dropped events
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 ||
               flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 {
                await handleDroppedEvents()
                continue
            }

            let fileEvents = FileEvent.from(flags: flags)

            if fileEvents.contains(.deleted) {
                await handleFileDeleted(at: path)
            } else if fileEvents.contains(.renamed) {
                await handleFileRenamed(at: path)
            } else if fileEvents.contains(.created) {
                await handleFileCreated(at: path)
            } else if fileEvents.contains(.modified) || fileEvents.contains(.metadataChanged) {
                await handleFileModified(at: path)
            }
        }
    }

    /// Handle a file creation event.
    private func handleFileCreated(at path: String) async {
        let url = URL(fileURLWithPath: path)

        guard let resourceValues = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]) else {
            logger.warning("handleFileCreated: failed to read resource values for \(path, privacy: .public) — file may have been deleted between event and processing")
            return
        }

        let isDirectory = resourceValues.isDirectory ?? false
        let isRegularFile = resourceValues.isRegularFile ?? false
        guard isRegularFile || isDirectory else { return }

        let fileName = url.lastPathComponent
        let nfcName = fileName.precomposedStringWithCanonicalMapping
        let parentPath = url.deletingLastPathComponent().path
        let fileSize = isRegularFile ? Int64(resourceValues.fileSize ?? 0) : Int64(0)
        let createdAt = resourceValues.creationDate ?? Date()
        let modifiedAt = resourceValues.contentModificationDate ?? Date()
        let fileExtension: String? = isRegularFile ? url.pathExtension : nil
        let cleanExt = (fileExtension != nil && fileExtension!.isEmpty) ? nil : fileExtension

        await index.insert(
            name: nfcName,
            path: path,
            parentPath: parentPath,
            isDirectory: isDirectory,
            size: fileSize,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: cleanExt
        )
    }

    /// Handle a file deletion event.
    private func handleFileDeleted(at path: String) async {
        await index.removeByPath(path)
    }

    /// Handle a rename event.
    private func handleFileRenamed(at path: String) async {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            await handleFileCreated(at: path)
        } else {
            await handleFileDeleted(at: path)
        }
    }

    /// Handle a file modification event.
    private func handleFileModified(at path: String) async {
        await handleFileDeleted(at: path)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            await handleFileCreated(at: path)
        }
    }

    /// Handle dropped events by restarting the stream.
    private func handleDroppedEvents() async {
        if hasTooManyRestarts() {
            degradeToPolling()
            return
        }
        eventStream.stop()
        await attemptStartOrRetry()
    }

    // MARK: - Private: Polling Fallback

    /// Degrade to periodic polling mode after repeated failures.
    private func degradeToPolling() {
        isPolling = true
        _indexState = .polling
        eventStream.stop()

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollingInterval))
                guard !Task.isCancelled else { return }
                await self.performPollingScan()
            }
        }
    }

    /// Perform a single polling scan cycle.
    ///
    /// Placeholder implementation. A full implementation would scan watched paths
    /// for mtime changes, diff against the in-memory index, and apply updates.
    /// This is only invoked when FSEvents has failed repeatedly.
    private func performPollingScan() async {
        // Placeholder: full implementation would scan watched paths for mtime changes.
    }
}
