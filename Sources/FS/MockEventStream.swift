import Foundation

/// Test double for FileSystemEventStream. Allows programmatic injection of
/// events and tracks lifecycle state for assertions.
///
/// `@unchecked Sendable` because all mutable state is accessed only from the
/// test thread (synchronous test harness, no real concurrency).
final class MockEventStream: FileSystemEventStream, @unchecked Sendable {

    private(set) var isRunning: Bool = false
    private var handler: (@Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void)?

    func start(
        paths: [String],
        sinceEventID: UInt64 = 0,
        handler: @escaping @Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void
    ) {
        isRunning = true
        self.handler = handler
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    /// Deliver a single synthetic event to the handler installed by `start`.
    /// No-op if the stream is not running (no handler installed).
    func inject(path: String, flags: FSEventStreamEventFlags) {
        guard isRunning else { return }
        handler?([(path: path, flags: flags)])
    }
}
