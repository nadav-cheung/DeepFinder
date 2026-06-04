import Foundation

/// Semantic file system event types, abstracting away raw FSEventStreamEventFlags.
///
/// These map to the corresponding `kFSEventStreamEventFlagItem*` flags from the
/// macOS FSEvents API, but with clearer naming. Multiple events can occur in a
/// single coalesced notification (e.g. a file can be both created and modified).
enum FileEvent: Sendable, Hashable {
    /// A new file or directory was created.
    case created
    /// A file or directory was deleted.
    case deleted
    /// A file or directory was renamed (moved).
    case renamed
    /// A file's data content was modified.
    case modified
    /// A file's metadata changed (permissions, ownership, extended attributes).
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
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod) != 0 {
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
