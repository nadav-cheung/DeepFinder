// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation

/// Centralized default values for all subsystems.
///
/// Every numeric constant, timeout, limit, and default path that was previously
/// hardcoded inline is collected here as a named constant. This file is the
/// single source of truth for all default values.
public enum Constants {
    // MARK: - Daemon
    public enum Daemon {
        public static let startupTimeout: TimeInterval = 5.0
        public static let shutdownTimeout: TimeInterval = 5.0
        public static let shutdownPollInterval: TimeInterval = 0.1
        public static let indexBatchSize = 100
        public static let maxResults = 1000
    }

    // MARK: - IPC
    public enum IPC {
        public static let socketPollIntervalNs: UInt64 = 100_000_000 // 100ms
        public static let daemonReadyTimeout: TimeInterval = 10.0
        public static let daemonPollInterval: TimeInterval = 0.5
        public static let receiveTimeoutSeconds = 30
        public static let maxConnsPerSecond = 10
        public static let maxConcurrentClients = 50
        public static let maxTaskArraySize = 200
        public static let retryDelayNs: UInt64 = 1_000_000_000 // 1s
        public static let acceptPollIntervalNs: UInt64 = 1_000_000 // 1ms
        public static let acceptBackoffNs: UInt64 = 100_000_000 // 100ms

        /// Maximum framed message payload size (16 MB).
        /// Enforced by IPCFramingIO to prevent runaway memory allocation.
        public static let maxMessageSize = 16 * 1024 * 1024

        /// Socket listen backlog. Controls how many pending connections
        /// the kernel queues before refusing new ones.
        public static let listenBacklog: Int32 = 16

        /// Maximum allowed query string length in characters (10 KB).
        /// Queries exceeding this limit are rejected before parsing to prevent
        /// excessive memory allocation in the search pipeline.
        public static let maxQueryLength = 10_240

        /// Chunk size for reading IPC payload data (8 KB).
        /// Balances syscall overhead against memory usage per read iteration.
        public static let readChunkSize = 8192
    }

    // MARK: - Search
    public enum Search {
        public static let maxRegexLength = 256

        /// Maximum number of bookmarks a user can save.
        public static let maxBookmarks = 100
    }

    // MARK: - File System Scanning
    public enum Scan {
        public static let defaultMaxDepth = 8
        public static let fsEventLatency: TimeInterval = 0.5
        /// Directories always skipped during file scanning.
        public static let alwaysSkippedNames: Set<String> = [
            ".git", "node_modules", ".Trash", ".Spotlight-V100",
            ".claude", ".build", ".swiftpm", "DerivedData",
            ".cache", ".npm", ".cargo", "__pycache__", ".venv",
            "vendor", "bower_components",
        ]
        /// Directory path prefixes always excluded from scanning.
        public static let alwaysExcludedPrefixes: [String] = [
            "/System", "/Library",
            "/tmp", "/private/tmp",
        ]
        /// Full paths always excluded from scanning.
        /// User-home-relative paths are expanded at runtime via ``userExcludedPaths()``.
        public static let alwaysExcludedPaths: Set<String> = [
            "/Library/Caches", "/Library/Cookies", "/Library/Keychains",
        ]
        /// User-home-relative paths that cannot be expressed as static literals.
        /// Call this at runtime to get the full exclusion set.
        public static func userExcludedPaths() -> Set<String> {
            let home = NSHomeDirectory()
            return [
                home + "/Library/Developer",
            ]
        }

        /// Number of bytes checked for NUL bytes to detect binary files.
        /// 8 KB is a common tradeoff: large enough to avoid false positives
        /// on files with short binary headers, small enough to be fast.
        public static let binaryProbeSize = 8192
    }

    // MARK: - Content Scanner
    public enum ContentScanner {
        /// Default maximum line length before skipping (10 000 chars).
        /// Lines exceeding this are skipped to avoid pathological input
        /// such as minified JavaScript or base64-encoded blobs.
        public static let defaultMaxLineLength = 10_000

        /// Maximum total I/O in bytes across all scanned files (512 MB).
        /// Scanning stops once this budget is exhausted (REQ-1.4-04).
        public static let maxTotalIO: Int64 = 512 * 1_048_576

        /// Maximum number of candidate files to scan (REQ-1.4-04).
        public static let maxCandidates = 10_000

        /// Maximum number of files to scan concurrently (REQ-1.4-04).
        public static let maxConcurrentScans = 8

        /// Maximum individual file size (in bytes) to scan for content search.
        /// Files larger than 50 MB are skipped to avoid memory exhaustion.
        public static let maxFileSize: Int64 = 50_000_000
    }

    // MARK: - File Hashing
    public enum Hashing {
        /// Buffer size for streaming hash computation (64 KB).
        public static let bufferSize = 64 * 1024
    }

    // MARK: - AI
    public enum AI {
        public static let requestTimeout: TimeInterval = 30
        public static let crossLanguageCacheTTL: TimeInterval = 3600
        public static let summarizerCacheTTL: TimeInterval = 300
        public static let maxOutputTokens = 1024

        /// Maximum entries in the cross-language search term cache
        /// before triggering proactive eviction.
        public static let crossLanguageCacheMaxEntries = 100

        /// Maximum entries in the result summarizer cache
        /// before triggering proactive eviction.
        public static let summarizerCacheMaxEntries = 100

        /// Maximum retry attempts for transient AI API failures
        /// (HTTP 429 rate limiting, transport errors).
        public static let maxRetryAttempts = 3

        /// Anthropic Messages API protocol version.
        /// Changes on Anthropic's schedule; see:
        /// https://docs.anthropic.com/en/api/versioning
        public static let anthropicAPIVersion = "2023-06-01"
    }

    // MARK: - File System Watcher
    public enum Watcher {
        /// Maximum number of retry attempts before degrading to polling.
        public static let maxRetryAttempts = 5

        /// Initial retry delay in seconds (doubles with each attempt).
        public static let initialRetryDelay: TimeInterval = 2.0

        /// Maximum retry delay in seconds (caps exponential backoff).
        public static let maxRetryDelay: TimeInterval = 60.0

        /// Jitter factor applied to retry delays (+/-20%).
        public static let jitterFactor: Double = 0.2

        /// Polling interval in seconds when degraded from FSEvents to polling.
        public static let pollingInterval: TimeInterval = 30.0

        /// Maximum stream restarts within the restart window before degrading.
        public static let maxRestartsInWindow = 3

        /// Time window in seconds for counting restarts (10 minutes).
        public static let restartWindow: TimeInterval = 600.0
    }

    // MARK: - HTTP Service
    public enum HTTP {
        public static let maxHeaderSize = 1_048_576 // 1 MB
        public static let defaultSearchLimit = 100

        /// Maximum bytes to receive per NWConnection read callback (64 KB).
        public static let maxReceiveSize = 65536

        /// Maximum allowed value for the `limit` query parameter.
        public static let maxPageSize = 1000
    }

    // MARK: - GUI
    public enum GUI {
        /// Maximum results retained in the GUI results list.
        /// Intentionally higher than `Constants.Daemon.maxResults` (1000):
        /// the GUI paginated view can meaningfully display more results
        /// than the CLI's default single-page output.
        public static let maxResults = 10_000
    }

    // MARK: - REPL
    public enum REPL {
        public static let maxHistoryEntries = 1000

        /// Column width for padding command names in the :help output.
        public static let helpColumnWidth = 14
    }

    // MARK: - Terminal Formatting
    public enum Terminal {
        /// ANSI color code for highlighting search matches (yellow).
        public static let highlightColorCode = "33"
    }

    // MARK: - Memory
    public enum Memory {
        /// Bytes per megabyte, used for RSS reporting and similar conversions.
        public static let bytesPerMB = 1024 * 1024
    }

    // MARK: - Time
    public enum Time {
        /// Seconds per minute.
        public static let secondsPerMinute: TimeInterval = 60

        /// Seconds per hour.
        public static let secondsPerHour: TimeInterval = 3600
    }

}
