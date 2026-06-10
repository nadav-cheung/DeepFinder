import Foundation
import DeepFinderIndex
import DeepFinderPersist

/// Test double for FileSystemEventStream. Allows programmatic injection of
/// events and tracks lifecycle state for assertions.
///
/// `@unchecked Sendable` because all mutable state is accessed only from the
/// test thread (synchronous test harness, no real concurrency).
public final class MockEventStream: FileSystemEventStream, @unchecked Sendable {

    public init() {}

    public private(set) var isRunning: Bool = false
    private var handler: (@Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void)?

    public func start(
        paths: [String],
        sinceEventID: UInt64 = 0,
        handler: @escaping @Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void
    ) {
        isRunning = true
        self.handler = handler
    }

    public func stop() {
        isRunning = false
        handler = nil
    }

    /// Deliver a single synthetic event to the handler installed by `start`.
    /// No-op if the stream is not running (no handler installed).
    public func inject(path: String, flags: FSEventStreamEventFlags) {
        guard isRunning else { return }
        handler?([(path: path, flags: flags)])
    }
}
