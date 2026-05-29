import Foundation

/// Semantic file system event types, abstracting away raw FSEventStreamEventFlags.
enum FileEvent: Sendable, Hashable {
    case created
    case deleted
    case renamed
    case modified
    case metadataChanged

    /// Parse raw FSEventStreamEventFlags into a set of semantic FileEvents.
    ///
    /// Multiple flags can be set simultaneously (e.g. a file can be created and
    /// modified in the same event coalescing window).
    static func from(flags: FSEventStreamEventFlags) -> Set<FileEvent> {
        var events: Set<FileEvent> = []
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
            events.insert(.created)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            events.insert(.deleted)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
            events.insert(.renamed)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
            events.insert(.modified)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner) != 0 {
            events.insert(.metadataChanged)
        }
        return events
    }
}

/// Abstraction over macOS FSEvents. Production implementations wrap
/// FSEventStreamCreate; test implementations inject events programmatically.
///
/// The handler receives an array of (path, flags) tuples matching the raw
/// FSEvents callback shape, keeping the protocol close to the system API.
protocol FileSystemEventStream: Sendable {
    /// Begin monitoring the given directory paths. The handler is called
    /// asynchronously when file system events are detected.
    ///
    /// - Parameter sinceEventID: The last FSEvent ID to resume from.
    ///   Pass `kFSEventStreamEventIdSinceNow` to only receive new events.
    func start(
        paths: [String],
        sinceEventID: UInt64,
        handler: @escaping @Sendable ([(path: String, flags: FSEventStreamEventFlags)]) -> Void
    )

    /// Stop monitoring. Safe to call even if never started.
    func stop()

    /// Whether the stream is currently active and delivering events.
    var isRunning: Bool { get }
}
