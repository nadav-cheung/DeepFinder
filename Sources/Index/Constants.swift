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
    }

    // MARK: - Search
    enum Search {
        static let providerTimeout: TimeInterval = 5.0
        static let maxRegexLength = 256
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
    }

    // MARK: - AI
    enum AI {
        static let requestTimeout: TimeInterval = 30
        static let crossLanguageCacheTTL: TimeInterval = 3600
        static let summarizerCacheTTL: TimeInterval = 300
        static let maxOutputTokens = 1024
    }

    // MARK: - HTTP Service
    enum HTTP {
        static let maxHeaderSize = 1_048_576 // 1 MB
        static let defaultSearchLimit = 100
    }

    // MARK: - REPL
    enum REPL {
        static let maxHistoryEntries = 1000
    }
}
