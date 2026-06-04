import Foundation

/// Centralized default values for all subsystems.
///
/// Every numeric constant, timeout, limit, and default path that was previously
/// hardcoded inline is collected here as a named constant. This file is the
/// single source of truth for all default values.
enum Constants {
    // MARK: - Daemon
    enum Daemon {
        static let startupTimeout: TimeInterval = 5.0
        static let shutdownTimeout: TimeInterval = 5.0
        static let shutdownPollInterval: TimeInterval = 0.1
        static let indexBatchSize = 100
        static let maxResults = 1000
    }

    // MARK: - IPC
    enum IPC {
        static let socketPollIntervalNs: UInt64 = 100_000_000 // 100ms
        static let daemonReadyTimeout: TimeInterval = 10.0
        static let daemonPollInterval: TimeInterval = 0.5
        static let receiveTimeoutSeconds = 30
        static let maxConnsPerSecond = 10
        static let maxConcurrentClients = 50
        static let maxTaskArraySize = 200
        static let retryDelayNs: UInt64 = 1_000_000_000 // 1s
        static let acceptPollIntervalNs: UInt64 = 1_000_000 // 1ms
        static let acceptBackoffNs: UInt64 = 100_000_000 // 100ms

        /// Maximum framed message payload size (16 MB).
        /// Enforced by IPCFramingIO to prevent runaway memory allocation.
        static let maxMessageSize = 16 * 1024 * 1024

        /// Socket listen backlog. Controls how many pending connections
        /// the kernel queues before refusing new ones.
        static let listenBacklog: Int32 = 16

        /// Maximum allowed query string length in characters (10 KB).
        /// Queries exceeding this limit are rejected before parsing to prevent
        /// excessive memory allocation in the search pipeline.
        static let maxQueryLength = 10_240

        /// Chunk size for reading IPC payload data (8 KB).
        /// Balances syscall overhead against memory usage per read iteration.
        static let readChunkSize = 8192
    }

    // MARK: - Search
    enum Search {
        static let maxRegexLength = 256

        /// Maximum number of bookmarks a user can save.
        static let maxBookmarks = 100
    }

    // MARK: - File System Scanning
    enum Scan {
        static let defaultMaxDepth = 8
        static let fsEventLatency: TimeInterval = 0.5
        /// Directories always skipped during file scanning.
        static let alwaysSkippedNames: Set<String> = [
            ".git", "node_modules", ".Trash", ".Spotlight-V100",
        ]
        /// Directory path prefixes always excluded from scanning.
        static let alwaysExcludedPrefixes: [String] = [
            "/System", "/Library",
        ]
        /// Full paths always excluded from scanning.
        static let alwaysExcludedPaths: Set<String> = [
            "/Library/Caches", "/Library/Cookies", "/Library/Keychains",
        ]

        /// Number of bytes checked for NUL bytes to detect binary files.
        /// 8 KB is a common tradeoff: large enough to avoid false positives
        /// on files with short binary headers, small enough to be fast.
        static let binaryProbeSize = 8192
    }

    // MARK: - Content Scanner
    enum ContentScanner {
        /// Default maximum line length before skipping (10 000 chars).
        /// Lines exceeding this are skipped to avoid pathological input
        /// such as minified JavaScript or base64-encoded blobs.
        static let defaultMaxLineLength = 10_000

        /// Maximum total I/O in bytes across all scanned files (512 MB).
        /// Scanning stops once this budget is exhausted (REQ-1.4-04).
        static let maxTotalIO: Int64 = 512 * 1_048_576

        /// Maximum number of candidate files to scan (REQ-1.4-04).
        static let maxCandidates = 10_000

        /// Maximum number of files to scan concurrently (REQ-1.4-04).
        static let maxConcurrentScans = 8
    }

    // MARK: - File Hashing
    enum Hashing {
        /// Buffer size for streaming hash computation (64 KB).
        static let bufferSize = 64 * 1024
    }

    // MARK: - AI
    enum AI {
        static let requestTimeout: TimeInterval = 30
        static let crossLanguageCacheTTL: TimeInterval = 3600
        static let summarizerCacheTTL: TimeInterval = 300
        static let maxOutputTokens = 1024

        /// Maximum entries in the cross-language search term cache
        /// before triggering proactive eviction.
        static let crossLanguageCacheMaxEntries = 100

        /// Maximum entries in the result summarizer cache
        /// before triggering proactive eviction.
        static let summarizerCacheMaxEntries = 100

        /// Maximum retry attempts for transient AI API failures
        /// (HTTP 429 rate limiting, transport errors).
        static let maxRetryAttempts = 3

        /// Anthropic Messages API protocol version.
        /// Changes on Anthropic's schedule; see:
        /// https://docs.anthropic.com/en/api/versioning
        static let anthropicAPIVersion = "2023-06-01"
    }

    // MARK: - File System Watcher
    enum Watcher {
        /// Maximum number of retry attempts before degrading to polling.
        static let maxRetryAttempts = 5

        /// Initial retry delay in seconds (doubles with each attempt).
        static let initialRetryDelay: TimeInterval = 2.0

        /// Maximum retry delay in seconds (caps exponential backoff).
        static let maxRetryDelay: TimeInterval = 60.0

        /// Jitter factor applied to retry delays (+/-20%).
        static let jitterFactor: Double = 0.2

        /// Polling interval in seconds when degraded from FSEvents to polling.
        static let pollingInterval: TimeInterval = 30.0

        /// Maximum stream restarts within the restart window before degrading.
        static let maxRestartsInWindow = 3

        /// Time window in seconds for counting restarts (10 minutes).
        static let restartWindow: TimeInterval = 600.0
    }

    // MARK: - HTTP Service
    enum HTTP {
        static let maxHeaderSize = 1_048_576 // 1 MB
        static let defaultSearchLimit = 100

        /// Maximum bytes to receive per NWConnection read callback (64 KB).
        static let maxReceiveSize = 65536
    }

    // MARK: - GUI
    enum GUI {
        /// Maximum results retained in the GUI results list.
        /// Intentionally higher than `Constants.Daemon.maxResults` (1000):
        /// the GUI paginated view can meaningfully display more results
        /// than the CLI's default single-page output.
        static let maxResults = 10_000
    }

    // MARK: - REPL
    enum REPL {
        static let maxHistoryEntries = 1000

        /// Column width for padding command names in the :help output.
        static let helpColumnWidth = 14
    }

    // MARK: - Terminal Formatting
    enum Terminal {
        /// ANSI color code for highlighting search matches (yellow).
        static let highlightColorCode = "33"
    }

    // MARK: - Memory
    enum Memory {
        /// Bytes per megabyte, used for RSS reporting and similar conversions.
        static let bytesPerMB = 1024 * 1024
    }

    // MARK: - Time
    enum Time {
        /// Seconds per minute.
        static let secondsPerMinute: TimeInterval = 60

        /// Seconds per hour.
        static let secondsPerHour: TimeInterval = 3600
    }

}
