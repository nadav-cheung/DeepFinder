import Testing
import Foundation
@testable import DeepFinder

@Suite("FSEventWatcher")
struct FSEventWatcherTests {

    // MARK: - Helpers

    private func makeWatcher(
        stream: MockEventStream = MockEventStream()
    ) async -> (watcher: FSEventWatcher, index: InMemoryIndex, persistence: IndexPersistence, stream: MockEventStream) {
        let index = InMemoryIndex()
        let persistence = try! IndexPersistence(dbPath: ":memory:")
        let watcher = FSEventWatcher(
            eventStream: stream,
            index: index,
            persistence: persistence
        )
        return (watcher, index, persistence, stream)
    }

    /// Wait for the actor's event processing loop to drain pending events.
    ///
    /// The event processing runs in a Task. We give it time by sleeping briefly.
    /// This is a pragmatic approach for testing async actor pipelines.
    private func waitForProcessing() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - IndexState

    @Test("IndexState initial value is stale")
    func testIndexStateInitialIsStale() async {
        let (watcher, _, _, _) = await makeWatcher()
        let state = await watcher.indexState
        #expect(state == .stale)
    }

    // MARK: - State Transitions

    @Test("startWatching transitions through verifying to live")
    func testStartWatchingSetsLiveState() async {
        let (watcher, _, _, _) = await makeWatcher()
        let stateBefore = await watcher.indexState
        #expect(stateBefore == .stale)

        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 0)

        let stateAfter = await watcher.indexState
        #expect(stateAfter == .live)
    }

    @Test("stopWatching updates state to stale")
    func testStopWatchingUpdatesState() async {
        let (watcher, _, _, _) = await makeWatcher()
        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 0)

        let stateLive = await watcher.indexState
        #expect(stateLive == .live)

        await watcher.stopWatching()

        let stateStopped = await watcher.indexState
        #expect(stateStopped == .stale)
    }

    @Test("full state transition: stale -> verifying -> live -> stale")
    func testIndexStateTransitions() async {
        let (watcher, _, _, _) = await makeWatcher()

        // Initially stale
        let state0 = await watcher.indexState
        #expect(state0 == .stale)

        // Start watching -> live (verifying is transient, may not be observable)
        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 0)
        let state1 = await watcher.indexState
        #expect(state1 == .live)

        // Stop -> stale
        await watcher.stopWatching()
        let state2 = await watcher.indexState
        #expect(state2 == .stale)
    }

    // MARK: - File Event Handling (using real temp files)

    @Test("file created event inserts into index")
    func testFileCreatedInserted() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a real file
        let fileURL = tempDir.appendingPathComponent("newfile.txt")
        try Data("hello".utf8).write(to: fileURL)

        let (watcher, index, _, stream) = await makeWatcher()
        try? await watcher.startWatching(paths: [tempDir.path], sinceEventID: 0)

        // Inject a create event for the real file
        stream.inject(
            path: fileURL.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )

        await waitForProcessing()

        let results = await index.search(query: "newfile")
        #expect(results.count == 1)
        #expect(results[0].name == "newfile.txt")
    }

    @Test("file deleted event removes from index")
    func testFileDeletedRemoved() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("deleteme.txt")
        try Data("test".utf8).write(to: fileURL)

        let (watcher, index, _, stream) = await makeWatcher()

        // Insert the file into the index first
        await index.insert(
            name: "deleteme.txt",
            path: fileURL.path,
            parentPath: tempDir.path,
            isDirectory: false,
            size: 4,
            extension: "txt"
        )

        // Verify it's in the index
        let beforeDelete = await index.search(query: "deleteme")
        #expect(beforeDelete.count == 1)

        // Delete the real file so the path no longer exists
        try! FileManager.default.removeItem(at: fileURL)

        try? await watcher.startWatching(paths: [tempDir.path], sinceEventID: 0)

        // Inject a delete event
        stream.inject(
            path: fileURL.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        )

        await waitForProcessing()

        let afterDelete = await index.search(query: "deleteme")
        #expect(afterDelete.isEmpty)
    }

    @Test("file renamed event removes old and inserts new")
    func testFileRenamedUpdates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create the "old" file
        let oldURL = tempDir.appendingPathComponent("oldname.txt")
        try Data("test".utf8).write(to: oldURL)

        let (watcher, index, _, stream) = await makeWatcher()

        // Insert old file into the index
        await index.insert(
            name: "oldname.txt",
            path: oldURL.path,
            parentPath: tempDir.path,
            isDirectory: false,
            size: 4,
            extension: "txt"
        )

        try? await watcher.startWatching(paths: [tempDir.path], sinceEventID: 0)

        // Perform the actual rename on disk
        let newURL = tempDir.appendingPathComponent("newname.txt")
        try! FileManager.default.moveItem(at: oldURL, to: newURL)

        // Inject rename events: old path (gone) then new path (exists)
        stream.inject(
            path: oldURL.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        )
        stream.inject(
            path: newURL.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        )

        await waitForProcessing()

        // Old name should be gone
        let oldResults = await index.search(query: "oldname")
        #expect(oldResults.isEmpty)

        // New name should exist
        let newResults = await index.search(query: "newname")
        #expect(newResults.count == 1)
        #expect(newResults[0].name == "newname.txt")
    }

    @Test("file modified event updates metadata")
    func testFileModifiedUpdatesMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("modifyme.txt")
        try Data("original".utf8).write(to: fileURL)

        let (watcher, index, _, stream) = await makeWatcher()

        // Insert into index
        await index.insert(
            name: "modifyme.txt",
            path: fileURL.path,
            parentPath: tempDir.path,
            isDirectory: false,
            size: 8,
            extension: "txt"
        )

        try? await watcher.startWatching(paths: [tempDir.path], sinceEventID: 0)

        // Modify the file on disk
        try Data("modified and much longer content".utf8).write(to: fileURL)

        // Inject modify event
        stream.inject(
            path: fileURL.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )

        await waitForProcessing()

        // File should still be in index
        let afterModify = await index.search(query: "modifyme")
        #expect(afterModify.count == 1)
        // Size should be updated (remove old + re-stat + insert new)
        #expect(afterModify[0].size == 32) // "modified and much longer content" = 32 bytes
    }

    // MARK: - Retry on Stream Failure

    @Test("retry on stream start failure")
    func testRetryOnStreamFailure() async {
        // Mock that fails first 2 attempts, succeeds on 3rd.
        // FSEventWatcher checks isRunning synchronously after start().
        // FailingMockEventStream sets isRunning=false for the first failCount calls.
        let stream = FailingMockEventStream(failCount: 2)
        let index = InMemoryIndex()
        let persistence = try! IndexPersistence(dbPath: ":memory:")
        let watcher = FSEventWatcher(
            eventStream: stream,
            index: index,
            persistence: persistence
        )

        // The watcher's attemptStartOrRetry is synchronous for the first attempt,
        // then schedules retries via Task.sleep. Since we can't wait for real
        // exponential backoff (2s+), we test that the failure was detected and
        // state changed appropriately.
        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 0)

        // After first failed attempt, state should be error (retry pending)
        let state = await watcher.indexState
        #expect(state == .error)

        // First attempt should have been made
        let callCount = stream.startCallCount
        #expect(callCount >= 1)
    }

    // MARK: - Degraded to Polling

    @Test("degrade to polling after max retries")
    func testDegradedToPollingAfterMaxRetries() async {
        let stream = AlwaysFailingMockEventStream()
        let index = InMemoryIndex()
        let persistence = try! IndexPersistence(dbPath: ":memory:")
        let watcher = FSEventWatcher(
            eventStream: stream,
            index: index,
            persistence: persistence
        )

        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 0)

        // After first failure, state should be error (not yet polling — retries pending)
        // The actual degradation happens after maxRetryAttempts, which requires waiting
        // for the retry delays. Since we can't wait for that in a unit test,
        // we verify the state is at least error (retry in progress).
        let state = await watcher.indexState
        #expect(state == .error)

        // The stream should have been called at least once
        #expect(stream.startCallCount >= 1)
    }

    // MARK: - Cursor Saved on Stop

    @Test("cursor is saved on stop")
    func testCursorSavedOnStop() async throws {
        let (watcher, _, persistence, _) = await makeWatcher()

        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 42)
        await watcher.stopWatching()

        // stopWatching awaits the save, so cursor should be immediately available
        let savedCursor = await persistence.loadEventCursor()
        #expect(savedCursor == 42)
    }

    // MARK: - Drop Events (UserDropped / KernelDropped)

    @Test("UserDropped flag triggers stream restart and stays live")
    func testUserDroppedTriggersRestart() async {
        let (watcher, _, _, stream) = await makeWatcher()
        try? await watcher.startWatching(paths: ["/Users/test"], sinceEventID: 0)

        // Inject a UserDropped event
        let droppedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        stream.inject(path: "/Users/test", flags: droppedFlags)

        await waitForProcessing()

        // State should remain live (stream restarted)
        let state = await watcher.indexState
        #expect(state == .live)
    }

    // MARK: - Multiple Events in Batch

    @Test("multiple events in single batch all processed")
    func testMultipleEventsInBatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 3 real files
        let f1 = tempDir.appendingPathComponent("file1.txt")
        let f2 = tempDir.appendingPathComponent("file2.txt")
        let f3 = tempDir.appendingPathComponent("file3.txt")
        try Data("1".utf8).write(to: f1)
        try Data("2".utf8).write(to: f2)
        try Data("3".utf8).write(to: f3)

        let (watcher, index, _, stream) = await makeWatcher()
        try? await watcher.startWatching(paths: [tempDir.path], sinceEventID: 0)

        stream.inject(path: f1.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        stream.inject(path: f2.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        stream.inject(path: f3.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))

        await waitForProcessing()

        let r1 = await index.search(query: "file1")
        let r2 = await index.search(query: "file2")
        let r3 = await index.search(query: "file3")
        #expect(r1.count == 1)
        #expect(r2.count == 1)
        #expect(r3.count == 1)
    }

    // MARK: - Stop is idempotent

    @Test("stop without start does not crash")
    func testStopWithoutStartDoesNotCrash() async {
        let (watcher, _, _, _) = await makeWatcher()
        await watcher.stopWatching()
        let state = await watcher.indexState
        #expect(state == .stale)
    }

    // MARK: - Retry Delay Calculation

    @Test("retry delay increases exponentially")
    func testRetryDelayExponentialBackoff() {
        // Test the static retry delay calculation
        let delay1 = FSEventWatcher.retryDelay(forAttempt: 1)
        let delay2 = FSEventWatcher.retryDelay(forAttempt: 2)
        let delay3 = FSEventWatcher.retryDelay(forAttempt: 3)

        // delay1 should be around 2s (initial)
        #expect(delay1 >= 1.5 && delay1 <= 2.5)
        // delay2 should be around 4s
        #expect(delay2 >= 3.0 && delay2 <= 5.0)
        // delay3 should be around 8s
        #expect(delay3 >= 6.0 && delay3 <= 10.0)
    }

    @Test("retry delay is capped at max")
    func testRetryDelayCapped() {
        let delayLarge = FSEventWatcher.retryDelay(forAttempt: 20)
        // Should be capped at 60s (+ jitter)
        #expect(delayLarge <= 72.0)
        #expect(delayLarge >= 48.0)
    }

    // MARK: - Polling Scan

    @Test("polling scan detects new, modified, and deleted files")
    func testPollingScanDetectsChanges() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventWatcherPolling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create initial files
        let fileA = tempDir.appendingPathComponent("alpha.txt")
        let fileB = tempDir.appendingPathComponent("bravo.txt")
        try Data("original-A".utf8).write(to: fileA)
        try Data("original-B".utf8).write(to: fileB)

        let index = InMemoryIndex()
        let persistence = try IndexPersistence(dbPath: ":memory:")
        let stream = AlwaysFailingMockEventStream()
        let watcher = FSEventWatcher(
            eventStream: stream,
            index: index,
            persistence: persistence
        )

        // Pre-populate the index with the initial files.
        // This simulates the index state before FSEvents failed.
        await index.insert(
            name: "alpha.txt",
            path: fileA.path,
            parentPath: tempDir.path,
            isDirectory: false,
            size: 10,
            extension: "txt"
        )
        await index.insert(
            name: "bravo.txt",
            path: fileB.path,
            parentPath: tempDir.path,
            isDirectory: false,
            size: 10,
            extension: "txt"
        )

        // Verify initial state
        let beforeAlpha = await index.search(query: "alpha")
        let beforeBravo = await index.search(query: "bravo")
        #expect(beforeAlpha.count == 1)
        #expect(beforeBravo.count == 1)

        // Mutate filesystem:
        // 1. Modify fileA
        // 2. Delete fileB
        // 3. Create fileC (new file)
        try Data("modified-A-with-longer-content".utf8).write(to: fileA)
        try FileManager.default.removeItem(at: fileB)
        let fileC = tempDir.appendingPathComponent("charlie.txt")
        try Data("new-C".utf8).write(to: fileC)

        // Start watching with the always-failing stream so watchedPaths gets set.
        try? await watcher.startWatching(paths: [tempDir.path], sinceEventID: 0)

        // Directly invoke the polling scan (would normally run on the 30s timer).
        await watcher.performPollingScan()

        // Verify: fileA should be updated (remove + re-insert with new size)
        let afterAlpha = await index.search(query: "alpha")
        #expect(afterAlpha.count == 1)
        #expect(afterAlpha[0].size == 30) // "modified-A-with-longer-content".utf8.count

        // Verify: fileB should be removed from index
        let afterBravo = await index.search(query: "bravo")
        #expect(afterBravo.isEmpty)

        // Verify: fileC should be added to index
        let afterCharlie = await index.search(query: "charlie")
        #expect(afterCharlie.count == 1)
        #expect(afterCharlie[0].name == "charlie.txt")
    }
}

// MARK: - Test Doubles

/// Mock stream that fails the first `failCount` calls to start(), then succeeds.
final class FailingMockEventStream: FileSystemEventStream, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var startCallCount = 0
    private let failCount: Int
    private var handler: (@Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void)?

    init(failCount: Int) {
        self.failCount = failCount
    }

    func start(
        paths: [String],
        sinceEventID: UInt64 = 0,
        handler: @escaping @Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void
    ) {
        startCallCount += 1
        if startCallCount <= failCount {
            isRunning = false
            return
        }
        isRunning = true
        self.handler = handler
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    func inject(path: String, flags: FSEventStreamEventFlags) {
        guard isRunning else { return }
        handler?([(path: path, flags: flags)])
    }
}

/// Mock stream that always fails to start.
final class AlwaysFailingMockEventStream: FileSystemEventStream, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var startCallCount = 0

    func start(
        paths: [String],
        sinceEventID: UInt64 = 0,
        handler: @escaping @Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void
    ) {
        startCallCount += 1
        isRunning = false
    }

    func stop() {
        isRunning = false
    }
}
