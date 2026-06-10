import Foundation
import CoreServices
import DeepFinderIndex
import DeepFinderPersist

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
public final class FSEventStreamImpl: FileSystemEventStream, @unchecked Sendable {

    public init() {}

    // MARK: - Configuration

    /// Event coalescing latency in seconds. FSEvents will wait this long
    /// before delivering events, merging duplicates within the window.
    private static let latency: TimeInterval = Constants.Scan.fsEventLatency

    /// Flags for FSEventStreamCreate.
    ///
    /// `kFSEventStreamCreateFlagUseCFTypes` is required: without it the callback
    /// receives a raw C array of `char *` strings, but our callback treats
    /// `eventPaths` as a `CFArray` of `CFStringRef` via `unsafeBitCast`.
    /// Missing this flag causes a SIGSEGV when the code sends `objc_retain`
    /// to what is actually C-string bytes.
    private static let streamFlags: FSEventStreamCreateFlags =
        FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

    // MARK: - Mutable State (protected by queue)

    /// Serial queue for all FSEventStream operations and callbacks.
    private let queue = DispatchQueue(label: "\(Product.identifier).fsevents", qos: .utility)

    /// The underlying FSEventStream, nil when not running.
    private var stream: FSEventStreamRef?

    /// Handler closure, retained for the stream's lifetime.
    private var eventHandler: (@Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void)?

    /// Whether the stream is currently active.
    private var _isRunning = false

    // MARK: - FileSystemEventStream Conformance

    public var isRunning: Bool {
        queue.sync { _isRunning }
    }

    public func start(
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

    public func stop() {
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
        // Use queue.async to avoid potential deadlock: if the last strong reference
        // is held by a closure on the serial queue itself, queue.sync would deadlock.
        // queue.async is safe here because deinit runs after all strong references are
        // gone, so no further method calls can arrive. The async block will drain on
        // the queue after any in-flight callback completes.
        nonisolated(unsafe) let stream: OpaquePointer? = self.stream
        let running = self._isRunning
        queue.async {
            guard running, let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
