import Foundation
import CoreServices

/// Production implementation of `FileSystemEventStream` using macOS FSEvents.
///
/// Wraps `FSEventStreamCreate` with dispatch queue scheduling (NOT the deprecated
/// RunLoop API). Uses `kFSEventStreamCreateFlagFileEvents` for file-level granularity
/// and `kFSEventStreamCreateFlagNoDefer` for immediate event delivery.
///
/// **Latency**: 0.5s coalescing window (target: <2s end-to-end response).
///
/// **Thread safety**: `@unchecked Sendable` because all mutable state is protected
/// by the serial dispatch queue. The FSEventStream callbacks arrive on this queue,
/// and public methods are called from the FSEventWatcher actor.
///
/// **Platform**: macOS only. FSEvents is not available on iOS, Linux, or Windows.
/// Requires Full Disk Access to monitor protected directories (~/Documents, ~/Desktop, etc.).
/// Without FDA, those directories are silently skipped by the system.
final class FSEventStreamImpl: FileSystemEventStream, @unchecked Sendable {

    // MARK: - Configuration

    /// Event coalescing latency in seconds. FSEvents will wait this long
    /// before delivering events, merging duplicates within the window.
    private static let latency: TimeInterval = 0.5

    /// Flags for FSEventStreamCreate.
    private static let streamFlags: FSEventStreamCreateFlags =
        FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

    // MARK: - Mutable State (protected by queue)

    /// Serial queue for all FSEventStream operations and callbacks.
    private let queue = DispatchQueue(label: "com.nadav.deepfinder.fsevents", qos: .utility)

    /// The underlying FSEventStream, nil when not running.
    private var stream: FSEventStreamRef?

    /// Handler closure, retained for the stream's lifetime.
    private var eventHandler: (@Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void)?

    /// Whether the stream is currently active.
    private var _isRunning = false

    // MARK: - FileSystemEventStream Conformance

    var isRunning: Bool {
        queue.sync { _isRunning }
    }

    func start(
        paths: [String],
        sinceEventID: UInt64 = UInt64(kFSEventStreamEventIdSinceNow),
        handler: @escaping @Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void
    ) {
        queue.sync {
            guard !_isRunning else { return }

            self.eventHandler = handler

            let pathsToWatch = paths as CFArray
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let createdStream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                    guard let info = clientCallBackInfo else { return }
                    let impl = Unmanaged<FSEventStreamImpl>.fromOpaque(info).takeUnretainedValue()

                    let pathArray = unsafeBitCast(eventPaths, to: CFArray.self)
                    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
                    events.reserveCapacity(Int(numEvents))

                    for i in 0..<Int(numEvents) {
                        let pathValue = CFArrayGetValueAtIndex(pathArray, i)
                        let path = unsafeBitCast(pathValue, to: CFString.self) as String
                        let flags = eventFlags[i]
                        events.append((path: path, flags: flags))
                    }

                    impl.eventHandler?(events)
                },
                &context,
                pathsToWatch,
                FSEventStreamEventId(sinceEventID),
                Self.latency,
                Self.streamFlags
            ) else {
                // Failed to create stream — leave isRunning false
                self._isRunning = false
                return
            }

            self.stream = createdStream

            FSEventStreamSetDispatchQueue(createdStream, queue)

            if FSEventStreamStart(createdStream) {
                self._isRunning = true
            } else {
                FSEventStreamInvalidate(createdStream)
                FSEventStreamRelease(createdStream)
                self.stream = nil
                self._isRunning = false
                self.eventHandler = nil
            }
        }
    }

    func stop() {
        queue.sync {
            guard _isRunning, let stream else { return }

            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)

            self.stream = nil
            self._isRunning = false
            self.eventHandler = nil
        }
    }

    // MARK: - Cleanup

    deinit {
        // Safe to use queue.sync here: deinit cannot be called from within the
        // serial queue (no retain cycle — the stream does not retain self).
        // This guarantees no callbacks fire during or after cleanup.
        queue.sync {
            guard _isRunning, let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            _isRunning = false
            self.stream = nil
            self.eventHandler = nil
        }
    }
}
