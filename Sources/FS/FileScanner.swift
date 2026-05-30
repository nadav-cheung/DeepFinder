/// # Filesystem Module
///
/// Handles filesystem scanning, real-time event monitoring, and volume management.
///
/// ## Components
/// - ``FileScanner`` -- recursive directory scanner emitting ``ScanEvent`` via AsyncStream
/// - ``FSEventWatcher`` -- real-time FSEvents consumer that updates the in-memory index
/// - ``FileSystemEventStream`` -- protocol abstracting FSEventStream (production vs mock)
/// - ``FSEventStreamImpl`` -- production FSEventStreamCreate wrapper
/// - ``MockEventStream`` -- test-only event stream for deterministic testing
/// - ``VolumeManager`` -- external/network volume enumeration and mount monitoring
/// - ``FileEvent`` -- semantic file event types (created, deleted, renamed, modified)
/// - ``ScanConfiguration`` -- scan parameters (skip paths, depth limits, symlink policy)
///
/// ## Event Pipeline
/// ```
/// FSEventStream -> FileSystemEventStream -> FSEventWatcher -> InMemoryIndex + IndexPersistence
/// ```
///
/// ## Failure Handling
/// - Stream start failure: exponential backoff retry (2s-60s, +/-20% jitter, max 5 attempts)
/// - After max retries: degrade to polling mode (30s interval)
/// - Dropped events (user/kernel): restart stream; burst protection degrades to polling
import Foundation

// MARK: - Configuration

/// Configuration for a filesystem scan.
struct ScanConfiguration: Sendable {
    /// Path suffixes to skip entirely (e.g. "/.git", "/node_modules").
    /// Matched against path components during enumeration.
    var skipPaths: Set<String>

    /// Privacy-sensitive path suffixes to skip (e.g. "/Library/Caches").
    var privacySkipPaths: Set<String>

    /// Optional maximum directory depth limit. `nil` means no limit.
    var maxDepth: Int?

    /// Whether to follow symbolic links. Default is `false`.
    var followSymlinks: Bool

    init(
        skipPaths: Set<String> = [
            "/.git",
            "/node_modules",
            "/.Trash",
            "/.Spotlight-V100",
            "/System",
            "/Library",
        ],
        privacySkipPaths: Set<String> = [
            "/Library/Caches",
            "/Library/Cookies",
            "/Library/Keychains",
        ],
        maxDepth: Int? = nil,
        followSymlinks: Bool = false
    ) {
        self.skipPaths = skipPaths
        self.privacySkipPaths = privacySkipPaths
        self.maxDepth = maxDepth
        self.followSymlinks = followSymlinks
    }
}

// MARK: - Scan Event

/// Events emitted during a filesystem scan.
enum ScanEvent: Sendable {
    case fileFound(FileRecord)
    case directoryFound(FileRecord)
    case scanComplete(ScanStats)
    case scanError(ScanError)
    case progress(filesScanned: Int)
}

// MARK: - Scan Stats

/// Statistics collected during a scan.
struct ScanStats: Sendable {
    let filesScanned: Int
    let directoriesScanned: Int
    let skippedCount: Int
    let errorCount: Int
    let duration: TimeInterval
}

// MARK: - Scan Error

/// An error encountered during scanning.
struct ScanError: Sendable {
    let path: String
    let reason: String
}

// MARK: - FileScanner

/// Full filesystem scanner. Walks directory trees using `FileManager`
/// and emits `ScanEvent`s through an `AsyncStream`.
///
/// **Platform note**: Requires Full Disk Access on macOS to scan protected
/// directories (~/Documents, ~/Desktop, ~/Downloads). Without FDA, FileManager
/// silently skips these directories without error.
///
/// Usage:
/// ```
/// let scanner = FileScanner()
/// for await event in scanner.scan(rootPaths: ["/Users"], config: config) {
///     switch event { ... }
/// }
/// ```
actor FileScanner {

    // MARK: - ID Assignment

    /// Sequential ID counter for auto-assigning FileRecord IDs.
    private var nextID: UInt32 = 1

    private func takeNextID() -> UInt32 {
        let id = nextID
        nextID += 1
        return id
    }

    // MARK: - Public API

    /// Scan the given root paths and yield scan events asynchronously.
    ///
    /// - Parameters:
    ///   - rootPaths: Top-level directory paths to scan.
    ///   - config: Scan configuration controlling skip behavior, depth, symlinks.
    /// - Returns: An `AsyncStream<ScanEvent>` that produces events until the scan completes.
    func scan(rootPaths: [String], config: ScanConfiguration) -> AsyncStream<ScanEvent> {
        // Grab starting ID on the actor, then do enumeration off-actor.
        let startID = takeNextID() - 1  // will be incremented before first use

        return AsyncStream { continuation in
            Task.detached {
                // Mutable ID counter local to this scan — no actor isolation needed.
                var localNextID: UInt32 = startID
                func assignID() -> UInt32 {
                    let id = localNextID + 1
                    localNextID = id
                    return id
                }

                var filesScanned = 0
                var directoriesScanned = 0
                var skippedCount = 0
                var errorCount = 0
                let startTime = Date()
                let progressInterval = 100

                let fm = FileManager.default
                let allSkipSuffixes = config.skipPaths.union(config.privacySkipPaths)

                for rootPath in rootPaths {
                    guard let enumerator = fm.enumerator(
                        at: URL(fileURLWithPath: rootPath),
                        includingPropertiesForKeys: [
                            .isRegularFileKey,
                            .isDirectoryKey,
                            .isSymbolicLinkKey,
                            .fileSizeKey,
                            .creationDateKey,
                            .contentModificationDateKey,
                        ],
                        options: [.skipsPackageDescendants],
                        errorHandler: { url, error in
                            // Emit scan error for permission issues and other failures.
                            // Return true to continue scanning other items.
                            errorCount += 1
                            continuation.yield(.scanError(ScanError(
                                path: url.path,
                                reason: error.localizedDescription
                            )))
                            return true
                        }
                    ) else {
                        continuation.yield(.scanError(ScanError(
                            path: rootPath,
                            reason: "Failed to create directory enumerator"
                        )))
                        errorCount += 1
                        continue
                    }

                    while let item = enumerator.nextObject() {
                        if Task.isCancelled { break }

                        guard let url = item as? URL else { continue }

                        // Skip symlinks when configured
                        if !config.followSymlinks {
                            if let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                               rv.isSymbolicLink == true {
                                enumerator.skipDescendants()
                                continue
                            }
                        }

                        let pathString = url.path

                        // Check skip paths
                        if Self.pathMatchesSkip(path: pathString, suffixes: allSkipSuffixes) {
                            enumerator.skipDescendants()
                            skippedCount += 1
                            continue
                        }

                        // Check depth limit
                        if let maxDepth = config.maxDepth {
                            let depth = Self.depthOf(path: pathString, relativeTo: rootPath)
                            if depth > maxDepth {
                                enumerator.skipDescendants()
                                continue
                            }
                        }

                        // Extract resource values
                        guard let resourceValues = try? url.resourceValues(forKeys: [
                            .isRegularFileKey,
                            .isDirectoryKey,
                            .fileSizeKey,
                            .creationDateKey,
                            .contentModificationDateKey,
                        ]) else {
                            continue
                        }

                        let isDirectory = resourceValues.isDirectory ?? false
                        let isRegularFile = resourceValues.isRegularFile ?? false

                        guard isRegularFile || isDirectory else { continue }

                        let fileName = url.lastPathComponent
                        let nfcName = fileName.precomposedStringWithCanonicalMapping
                        let parentPath = url.deletingLastPathComponent().path
                        let fileSize = isRegularFile ? Int64(resourceValues.fileSize ?? 0) : Int64(0)
                        let createdAt = resourceValues.creationDate ?? Date()
                        let modifiedAt = resourceValues.contentModificationDate ?? Date()
                        let fileExtension: String? = isRegularFile ? url.pathExtension : nil

                        let record = FileRecord(
                            id: assignID(),
                            name: nfcName,
                            originalName: fileName,
                            path: pathString,
                            parentPath: parentPath,
                            isDirectory: isDirectory,
                            size: fileSize,
                            createdAt: createdAt,
                            modifiedAt: modifiedAt,
                            extension: fileExtension
                        )

                        if isDirectory {
                            directoriesScanned += 1
                            continuation.yield(.directoryFound(record))
                        } else {
                            filesScanned += 1
                            continuation.yield(.fileFound(record))

                            if filesScanned % progressInterval == 0 {
                                continuation.yield(.progress(filesScanned: filesScanned))
                            }
                        }
                    }
                }

                // Final progress event with total count
                continuation.yield(.progress(filesScanned: filesScanned))

                let duration = Date().timeIntervalSince(startTime)
                continuation.yield(.scanComplete(ScanStats(
                    filesScanned: filesScanned,
                    directoriesScanned: directoriesScanned,
                    skippedCount: skippedCount,
                    errorCount: errorCount,
                    duration: duration
                )))
                continuation.finish()
            }
        }
    }

    // MARK: - Path Matching Helpers (static — no actor isolation needed)

    /// Check if a path matches any skip suffix.
    ///
    /// A suffix like "/.git" matches:
    /// - Paths ending in "/.git" at a component boundary
    /// - Paths containing "/.git/" (mid-path component)
    static func pathMatchesSkip(path: String, suffixes: Set<String>) -> Bool {
        for suffix in suffixes {
            if path.hasSuffix(suffix) {
                let suffixStart = path.index(path.endIndex, offsetBy: -suffix.count)
                if suffixStart == path.startIndex || path[path.index(before: suffixStart)] == "/" {
                    return true
                }
            }
            if path.contains(suffix + "/") {
                return true
            }
        }
        return false
    }

    /// Calculate directory depth of a path relative to a root path.
    static func depthOf(path: String, relativeTo root: String) -> Int {
        let rootStd = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(rootStd) else { return 0 }
        let relative = String(path.dropFirst(rootStd.count))
        guard !relative.isEmpty else { return 0 }
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return trimmed.components(separatedBy: "/").filter { !$0.isEmpty }.count
    }
}
